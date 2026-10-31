/// The permission gate (design D13).
///
/// Order, after argument validation and the hooks: credential refusal,
/// built-in read-only allowlist, user rules, `--yolo`, then the prompt. The
/// refusal comes first among the allowing steps, so neither a rule nor yolo
/// exposes a credential file. Every decision is returned as the `permission`
/// record the runtime merges into the call node before the call runs.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/user_config.dart';
import '../provider/provider.dart';
import '../shell/direct_exec.dart';
import '../shell/proof.dart';
import '../tools/ask.dart';
import '../tools/tool.dart';
import 'credentials.dart';
import 'workspace_paths.dart';

/// The reason a call is refused when it names a credential file.
const String credentialRefusal = 'credential files are not readable by tools';

/// The reason a call is refused when the path or directory it was approved
/// for now resolves somewhere else.
const String targetMovedRefusal =
    'the target moved after it was approved; ask again';

/// The reason a call is refused when the path or directory it names cannot
/// be resolved, so the prompt could not show where it acts.
const String unresolvedRefusal =
    'the path cannot be resolved (a dangling link, or .. after a missing '
    'directory); name it without either';

/// The tools whose `path` argument credential files are refused for.
const Set<String> _fileTools = {'read', 'edit', 'write', 'grep', 'find', 'ls'};

/// The tools that read inside the workspace without a prompt.
const Set<String> _readTools = {'read', 'grep', 'find', 'ls'};

/// Decides whether each call may run.
///
/// The gate holds no state besides its inputs; a user rule applies only
/// because it is in [config], which the engine reads from the Kehai home.
final class PermissionGate implements CallStage {
  /// Creates the gate.
  PermissionGate({
    required this.workspace,
    required this.kehaiHome,
    required this.prompts,
    this.config = const UserConfig(),
    this.yolo = false,
    this.posixShell = false,
    this.environment,
  });

  /// The workspace root.
  final Directory workspace;

  /// The Kehai home, where the credential files live.
  final Directory kehaiHome;

  /// The answerer channel permission prompts go through.
  final PromptChannel prompts;

  /// The user configuration: the only source of allow rules.
  final UserConfig config;

  /// Whether calls that are not autoapproved run without a prompt.
  final bool yolo;

  /// Whether `bash` runs under a POSIX shell. A command is proven read-only,
  /// and an argv rule matches, only then; PowerShell is never proven.
  final bool posixShell;

  /// The environment whose `PATH` resolves the program of an autoapproved
  /// command; defaults to the process environment.
  final Map<String, String>? environment;

  @override
  Future<StageOutcome> check(StageCall call, CancelToken cancel) async {
    final root = realPath(workspace.path);
    if (_touchesCredential(call)) {
      return const StageOutcome.deny(
        credentialRefusal,
        record: {'decision': 'deny', 'by': 'builtin', 'rule': 'credential'},
      );
    }
    final builtin = root == null ? null : _builtin(call, root);
    if (builtin != null) return StageOutcome.proceed(record: builtin);
    final rule = _userRule(call);
    if (rule != null) {
      return StageOutcome.proceed(
        record: {'decision': 'allow', 'by': 'user', 'rule': rule},
      );
    }
    if (yolo) {
      return const StageOutcome.proceed(
        record: {'decision': 'allow', 'by': 'yolo'},
      );
    }
    return _ask(call, cancel);
  }

  /// The paths the call names, for the file tools; `null` for other tools.
  List<String>? _pathsOf(StageCall call) {
    if (!_fileTools.contains(call.tool)) return null;
    return [
      switch (call.input['path']) {
        final String s => s,
        _ => '.',
      },
    ];
  }

  String _resolve(String path) => p.join(workspace.absolute.path, path);

  bool _touchesCredential(StageCall call) {
    final paths = _pathsOf(call);
    if (paths == null) return false;
    return paths.any((path) => isCredentialTarget(_resolve(path), kehaiHome));
  }

  Map<String, Object?>? _builtin(StageCall call, String root) {
    const allow = {'decision': 'allow', 'by': 'builtin'};
    switch (call.tool) {
      case final tool when _readTools.contains(tool):
        for (final path in _pathsOf(call)!) {
          final real = realPath(_resolve(path));
          if (real == null || !isInside(root, real)) return null;
        }
        return allow;
      case 'read_more' || 'search_result' || 'ask':
        return allow;
      case 'job':
        final action = call.input['action'];
        return action == 'status' || action == 'output' ? allow : null;
      case 'bash':
        final proven = _proven(call, root);
        return proven == null ? null : {...allow, 'rule': proven.program};
      default:
        return null;
    }
  }

  ProvenCommand? _proven(StageCall call, String root) {
    final command = call.input['command'];
    if (!posixShell || command is! String) return null;
    final cwd = call.input['cwd'];
    final proven = proveReadOnly(
      command,
      workspaceRoot: root,
      cwd: cwd is String ? cwd : null,
    );
    // An autoapproved command runs directly; one whose program does not
    // resolve outside the workspace goes to the prompt instead.
    return proven != null && _resolves(proven.program, root) ? proven : null;
  }

  bool _resolves(String program, String? root) =>
      root != null &&
      resolveProgram(
            program,
            workspaceRoot: root,
            environment: environment ?? Platform.environment,
          ) !=
          null;

  /// The label of the first user rule that allows [call], or null.
  String? _userRule(StageCall call) {
    for (final rule in config.allow) {
      if (rule.tool != call.tool) continue;
      if (rule.tool != 'bash') {
        if (rule.argv == null) return rule.label;
        continue;
      }
      // A bash rule, with or without an argv prefix, matches only a simple
      // command whose program resolves outside the workspace.
      final prefix = rule.argv ?? const <String>[];
      if (!posixShell) continue;
      final command = call.input['command'];
      final argv = command is String ? tokenizeSimple(command) : null;
      if (argv == null || argv.length < prefix.length) continue;
      var matches = true;
      for (var i = 0; i < prefix.length; i++) {
        matches &= argv[i] == prefix[i];
      }
      if (matches && _resolves(argv.first, realPath(workspace.path))) {
        return rule.label;
      }
    }
    return null;
  }

  /// What [call] names as the place it acts: a file tool's `path`, or the
  /// directory a `bash` command runs in; null for other tools.
  String? _named(StageCall call) => switch (call.tool) {
    'bash' => switch (call.input['cwd']) {
      final String cwd => cwd,
      _ => '.',
    },
    final tool when _fileTools.contains(tool) => switch (call.input['path']) {
      final String path => path,
      _ => null,
    },
    _ => null,
  };

  /// Where [call] acts: the real path [_named] resolves to; null for other
  /// tools, or when it cannot be resolved.
  String? _target(StageCall call) {
    final named = _named(call);
    return named == null ? null : realPath(_resolve(named));
  }

  static bool _sameTarget(String? a, String? b) =>
      a == null ? b == null : b != null && p.equals(a, b);

  /// The input the prompt shows for [call]: its own input, plus, when
  /// [target] is somewhere other than the call names (through a link, or out
  /// of the workspace), that `target` and whether it is `outside` the
  /// workspace. The tool opens, or the command runs in, that target, so the
  /// user judges it rather than the name.
  Map<String, Object?> _promptInput(StageCall call, String? target) {
    final named = _named(call);
    final root = realPath(workspace.path);
    if (named == null || root == null || target == null) return call.input;
    final inside = isInside(root, target);
    if (inside &&
        p.equals(p.relative(target, from: root), p.normalize(named))) {
      return call.input;
    }
    return {
      ...call.input,
      'target': inside ? p.relative(target, from: root) : target,
      'outside': !inside,
    };
  }

  Future<StageOutcome> _ask(StageCall call, CancelToken cancel) async {
    if (!prompts.hasAnswerer) {
      return const StageOutcome.deny(
        'no user attached',
        record: {'decision': 'deny', 'by': 'headless'},
      );
    }
    final target = _target(call);
    // A path that cannot be resolved yet (a dangling link, or `..` after a
    // missing part) can land anywhere once the tool creates what is missing,
    // so the prompt could not show where it acts.
    if (target == null && _named(call) != null) {
      return const StageOutcome.deny(
        unresolvedRefusal,
        record: {'decision': 'deny', 'by': 'builtin', 'rule': 'unresolved'},
      );
    }
    final answer = await prompts.open(
      PromptItem(
        key: call.callKey,
        kind: PromptKind.permission,
        tool: call.tool,
        input: _promptInput(call, target),
      ),
      cancel,
      choices: const ['allow', 'deny'],
    );
    // Earlier calls may have run while the prompt was open; the user approved
    // the target shown, so a call that now lands elsewhere is refused. The
    // record carries the target, and the tool refuses one that moves later.
    final now = _target(call);
    if (answer == 'allow' && !_sameTarget(target, now)) {
      return const StageOutcome.deny(
        targetMovedRefusal,
        record: {'decision': 'deny', 'by': 'builtin', 'rule': 'target moved'},
      );
    }
    return switch (answer) {
      'allow' => StageOutcome.proceed(
        record: {'decision': 'allow', 'by': 'answer', 'target': ?target},
      ),
      'deny' => const StageOutcome.deny(
        'denied by the user',
        record: {'decision': 'deny', 'by': 'answer'},
      ),
      _ => const StageOutcome.deny('cancelled'),
    };
  }
}
