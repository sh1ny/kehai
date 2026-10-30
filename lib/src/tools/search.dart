/// The search tools: `grep`, `find` and `ls` (design D6).
///
/// `grep` and `find` run `rg` as a shell-less job of the supervisor when the
/// context has one (else as a direct child, through [startArgv]). Their output
/// streams through a [SearchLineRewriter] chunk by chunk and is never cut
/// here; only the composer cuts.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../jobs/supervisor.dart';
import '../permissions/workspace_paths.dart';
import '../results/composer.dart';
import '../results/result_store.dart';
import '../shell/launch.dart';
import '../shell/direct_exec.dart' show resolveProgram;
import 'child_env.dart';
import 'file_access.dart';
import 'glob_match.dart';
import 'tool.dart';

/// The outcome of looking for `rg`.
sealed class RgResolution {
  const RgResolution();
}

/// A working `rg`.
final class RgFound extends RgResolution {
  /// Creates the resolution.
  const RgFound(this.path, this.version);

  /// The executable.
  final String path;

  /// The version `rg --version` reported.
  final String version;
}

/// No working `rg`.
final class RgMissing extends RgResolution {
  /// Creates the resolution.
  const RgMissing(this.configPath);

  /// The user configuration file the error names.
  final String configPath;

  /// The error text of a call that needs `rg`.
  String get message =>
      'rg not found; install ripgrep or set rgPath in $configPath';
}

/// Finds `rg` once: [rgPath], else `PATH`; `rg --version` must succeed.
///
/// [environment] is only searched for `PATH`; it defaults to the process
/// environment. Discovery on `PATH` goes through the resolver direct bash
/// execution uses: only absolute entries count, and nothing whose real path
/// is inside [workspaceRoot], so a repository cannot supply the `rg` that
/// runs here. An [rgPath] is the user's own choice and is used as given. A
/// missing or unrunnable `rg` gives [RgMissing] naming
/// [configPath].
Future<RgResolution> resolveRg({
  String? rgPath,
  required String configPath,
  required String workspaceRoot,
  Map<String, String>? environment,
}) async {
  final exe =
      rgPath ??
      resolveProgram(
        'rg',
        workspaceRoot: workspaceRoot,
        environment: environment ?? Platform.environment,
      );
  if (exe == null) return RgMissing(configPath);
  try {
    final result = await Process.run(
      exe,
      const ['--version'],
      environment: childEnvironment(Platform.environment),
      includeParentEnvironment: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    final first = (result.stdout as String).split('\n').first.trim();
    final match = RegExp(r'^ripgrep (\S+)').firstMatch(first);
    if (result.exitCode != 0 || match == null) return RgMissing(configPath);
    return RgFound(exe, match.group(1)!);
  } on ProcessException {
    return RgMissing(configPath);
  }
}

/// A started child, without a shell.
final class ArgvRun {
  /// Creates a run over the pieces of a started process.
  ArgvRun({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.kill,
  });

  /// The child's standard output.
  final Stream<List<int>> stdout;

  /// The first bytes of the child's standard error, read to the end.
  final Future<List<int>> stderr;

  /// The exit code.
  final Future<int> exitCode;

  /// Kills the child.
  final void Function() kill;
}

/// How much standard error is kept.
const int _stderrBytes = 16 * 1024;

/// Starts [executable] with [arguments] directly (no shell) in
/// [workingDirectory], with exactly [environment], and closes its stdin.
///
/// Throws a [ProcessException] when it cannot start.
Future<ArgvRun> startArgv(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: false,
  );
  unawaited(process.stdin.close().then<void>((_) {}, onError: (Object _) {}));
  final errors = BytesBuilder(copy: false);
  final stderr = process.stderr
      .forEach((chunk) {
        final room = _stderrBytes - errors.length;
        if (room > 0) {
          errors.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
        }
      })
      .then((_) => errors.takeBytes());
  return ArgvRun(
    stdout: process.stdout,
    stderr: stderr,
    exitCode: process.exitCode,
    kill: () => process.kill(),
  );
}

/// Where a [SearchLineRewriter] is within a line.
enum _Phase {
  /// Reading the path, up to its NUL (or the newline of a bare path).
  head,

  /// Reading the digits after the NUL, which are a line number only when a
  /// colon follows.
  number,

  /// Streaming the text of an accepted line.
  text,

  /// Discarding the rest of a line the filter dropped.
  skip,
}

/// The most digits a line number has (a 64-bit count).
const int _maxLineNumber = 20;

/// Rewrites rg's `path\0line:text` lines into `path:line: text`, or bare
/// paths into workspace-relative ones, one chunk at a time.
final class SearchLineRewriter {
  /// Creates the rewriter.
  ///
  /// [prefix] is the directory rg ran in, relative to the workspace root, with
  /// `/` separators and no trailing one; it is put before every path.
  ///
  /// With a [filter], a path (relative to the directory rg ran in) it does not
  /// match drops its line, and the counters leave that line out.
  SearchLineRewriter({required this.grep, this.prefix = '', this.filter})
    : _prefixBytes = prefix.isEmpty
          ? const []
          : utf8.encode(prefix.endsWith('/') ? prefix : '$prefix/');

  /// Whether lines are matches (true) or bare paths (false).
  final bool grep;

  /// The directory the paths are relative to.
  final String prefix;

  /// The glob a path must match to be emitted, or null for all.
  final GlobMatcher? filter;

  final List<int> _prefixBytes;
  final BytesBuilder _head = BytesBuilder();
  final List<int> _digits = [];
  _Phase _phase = _Phase.head;
  List<int>? _lastPath;
  int _lines = 0;
  int _files = 0;

  /// Lines emitted.
  int get lines => _lines;

  /// Files emitted: distinct consecutive paths.
  int get files => _files;

  /// The bytes held back between chunks: the path of an unfinished line, or
  /// the digits that may be its line number. The text of a line is streamed
  /// through, so this never grows with the length of a line's text.
  int get retainedBytes => _head.length + _digits.length;

  /// Takes [chunk]; returns the rewritten bytes of every line it completes or
  /// continues.
  List<int> add(List<int> chunk) {
    final out = BytesBuilder(copy: false);
    final n = chunk.length;
    var i = 0;
    while (i < n) {
      switch (_phase) {
        case _Phase.head:
          final from = i;
          while (i < n && chunk[i] != 0x0a && !(grep && chunk[i] == 0)) {
            i++;
          }
          if (i > from) _head.add(chunk.sublist(from, i));
          if (i == n) break;
          if (chunk[i++] == 0x0a) {
            _wholeLine(out);
          } else {
            _phase = _accept(_takeHead(), out) ? _Phase.number : _Phase.skip;
          }
        case _Phase.number:
          final b = chunk[i];
          if (b >= 0x30 && b <= 0x39 && _digits.length < _maxLineNumber) {
            _digits.add(b);
            i++;
          } else if (b == 0x3a && _digits.isNotEmpty) {
            out
              ..addByte(0x3a)
              ..add(_digits)
              ..add(const [0x3a, 0x20]);
            _digits.clear();
            _phase = _Phase.text;
            i++;
          } else {
            _digitsAsText(out);
          }
        case _Phase.text || _Phase.skip:
          final nl = chunk.indexOf(0x0a, i);
          final end = nl < 0 ? n : nl;
          if (_phase == _Phase.text && end > i) {
            out.add(chunk.sublist(i, end));
          }
          if (nl < 0) return out.takeBytes();
          if (_phase == _Phase.text) out.addByte(0x0a);
          _phase = _Phase.head;
          i = nl + 1;
      }
    }
    return out.takeBytes();
  }

  /// Returns the rewritten rest at the end of the stream.
  List<int> finish() {
    final out = BytesBuilder(copy: false);
    switch (_phase) {
      case _Phase.head:
        if (_head.length > 0) _wholeLine(out);
      case _Phase.number:
        _digitsAsText(out);
        out.addByte(0x0a);
      case _Phase.text:
        out.addByte(0x0a);
      case _Phase.skip:
        break;
    }
    _head.clear();
    _digits.clear();
    _phase = _Phase.head;
    return out.takeBytes();
  }

  /// The header ended at a newline with no NUL: the line is a bare path.
  void _wholeLine(BytesBuilder out) {
    final path = _takeHead();
    if (path.isEmpty) return;
    if (_accept(path, out)) out.addByte(0x0a);
  }

  /// A line number that is not followed by a colon is the start of the text.
  void _digitsAsText(BytesBuilder out) {
    out
      ..addByte(0x3a)
      ..addByte(0x20)
      ..add(_digits);
    _digits.clear();
    _phase = _Phase.text;
  }

  List<int> _takeHead() => _head.takeBytes();

  /// Counts the line of [raw] and writes its path; false when the filter
  /// drops the line.
  bool _accept(List<int> raw, BytesBuilder out) {
    final path = _path(raw);
    final accept = filter;
    if (accept != null &&
        !accept.matches(utf8.decode(path, allowMalformed: true))) {
      return false;
    }
    _lines++;
    final last = _lastPath;
    if (last == null || !_same(last, path)) {
      _files++;
      _lastPath = path;
    }
    out
      ..add(_prefixBytes)
      ..add(path);
    return true;
  }

  /// The path bytes in `/` form without a leading `./`.
  List<int> _path(List<int> raw) {
    var path = raw;
    if (Platform.isWindows) {
      path = [for (final b in path) b == 0x5c ? 0x2f : b];
    }
    return path.length >= 2 && path[0] == 0x2e && path[1] == 0x2f
        ? path.sublist(2)
        : path;
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Where a search runs.
final class _Target {
  const _Target(this.cwd, this.file, this.prefix, this.exclusion);

  /// The directory rg runs in.
  final String cwd;

  /// The file name when the search path is a single file, else null.
  final String? file;

  /// The directory of [cwd] relative to the workspace, with `/` separators.
  final String prefix;

  /// The glob that hides the credential files, when the search covers the
  /// Kehai home.
  final String? exclusion;

  /// The rg flag that carries [exclusion]: case-insensitive on Windows, where
  /// the credential check and the file system ignore case.
  String get exclusionFlag => Platform.isWindows ? '--iglob' : '--glob';

  /// The note added to the summary when credential files were excluded.
  String get note => exclusion == null ? '' : '; credential files excluded';
}

/// [component] with every rg glob metacharacter escaped by a backslash, so
/// the glob matches that literal path component only.
String _escapeGlob(String component) =>
    component.replaceAllMapped(RegExp(r'[\\\[\]{}*?!]'), (m) => '\\${m[0]}');

/// The search target of the call, or the outcome that ends it.
(_Target?, ToolOutcome?) _resolveTarget(
  ToolContext context,
  Map<String, Object?> input, {
  required bool directoryOnly,
}) {
  final raw = (input['path'] as String?) ?? '.';
  final absolute = absolutePath(context.workspace, raw);
  final denied = credentialDenial(context, absolute);
  if (denied != null) return (null, denied);
  final isFile = switch (FileSystemEntity.typeSync(absolute)) {
    FileSystemEntityType.notFound => null,
    FileSystemEntityType.directory => false,
    _ => true,
  };
  if (isFile == null) return (null, failure('no such directory $raw'));
  if (isFile && directoryOnly) {
    return (null, failure('$raw is not a directory'));
  }
  final cwd = isFile ? p.dirname(absolute) : absolute;
  // [absolute] is a real path, so the workspace is compared as one.
  final workspace =
      realPath(context.workspace.path) ??
      p.normalize(context.workspace.absolute.path);
  final relative = p.equals(workspace, cwd)
      ? ''
      : p.isWithin(workspace, cwd)
      ? p.posix.joinAll(p.split(p.relative(cwd, from: workspace)))
      : p.posix.joinAll(p.split(cwd)).replaceFirst(RegExp(r'^//'), '/');
  String? exclusion;
  final home = context.kehaiHome;
  if (home != null && !isFile) {
    final homeReal = realPath(home.path) ?? home.absolute.path;
    final root = realPath(cwd) ?? cwd;
    if (isInside(root, homeReal)) {
      final inside = p.relative(homeReal, from: root);
      exclusion = inside == '.'
          ? '!auth.*'
          : '!${p.split(inside).map(_escapeGlob).join('/')}/auth.*';
    }
  }
  return (
    _Target(cwd, isFile ? p.basename(absolute) : null, relative, exclusion),
    null,
  );
}

const ToolOutcome _cancelled = ToolOutcome(
  status: ResultStatus.error,
  summary: 'cancelled',
  complete: false,
);

String _plural(int n, String one, String many) =>
    n == 1 ? '1 $one' : '$n $many';

/// Runs `rg` with [arguments] in [target] and streams the rewritten output.
///
/// With a job supervisor in the context, `rg` runs as a shell-less job and its
/// stored output is rewritten as it is read back; a context without one
/// starts the child directly.
///
/// Exit 0 settles `ok` with [found]; exit 1 is `ok` with [none]; anything else
/// is an error carrying rg's standard error.
Future<ToolOutcome> _runRg(
  ToolContext context,
  RgFound rg,
  _Target target,
  List<String> arguments,
  SearchLineRewriter rewriter,
  String Function() found,
  String none,
) async {
  if (context.cancel.isCancelled) return _cancelled;
  final jobs = context.jobs;
  if (jobs == null) {
    return _runRgDirect(context, rg, target, arguments, rewriter, found, none);
  }
  final setsid = Platform.isWindows ? null : context.shell?.shell?.setsid;
  final JobHandle handle;
  try {
    handle = jobs.start(
      JobRequest(
        kind: JobKind.shell,
        cmd: ['rg', ...arguments].join(' '),
        cwd: target.cwd,
        call: context.callKey,
        deadline: _rgDeadline,
        launch: () async => ShellProcess(
          await startProcess(
            rg.path,
            arguments,
            workingDirectory: target.cwd,
            environment: childEnvironment(Platform.environment),
            setsid: setsid,
          ),
          groupKnown: setsid != null,
        ),
      ),
    );
  } on TooManyLiveJobs catch (e) {
    return failure(e.message);
  }
  final detach = context.cancel.listen(
    () => unawaited(jobs.cancelJob(handle.id)),
  );
  try {
    final JobResult result;
    try {
      result = await handle.result;
    } on Object catch (e) {
      return failure('cannot run rg: $e');
    }
    if (context.cancel.isCancelled) return _cancelled;
    final lost = result.storage;
    if (lost != null) {
      return ToolOutcome(
        status: ResultStatus.error,
        summary: 'storage failure',
        complete: false,
        failed: true,
        reason: result.reason,
        storage: lost,
      );
    }
    if (result.state == 'failed') {
      return failure('cannot run rg: ${result.reason ?? 'launch failed'}');
    }
    if (result.state != 'settled') {
      return ToolOutcome(
        status: ResultStatus.error,
        summary: 'rg ${result.reason == 'deadline' ? 'timed out' : 'stopped'}',
        complete: false,
      );
    }
    final directory = p.join(jobs.store.sessionDir.path, resultsDirName);
    final stdout = result.streams['stdout'];
    if (stdout != null) {
      final file = File(p.join(directory, stdout.descriptor.sha256));
      await for (final chunk in file.openRead()) {
        final out = rewriter.add(chunk);
        if (out.isNotEmpty) await context.output.write(out);
        if (context.output.isClosed) {
          return const ToolOutcome(
            status: ResultStatus.error,
            summary: 'search stopped: output closed',
            complete: false,
          );
        }
      }
      final rest = rewriter.finish();
      if (rest.isNotEmpty) await context.output.write(rest);
    }
    final stderr = result.streams['stderr'];
    var errorText = '';
    if (stderr != null && stderr.descriptor.bytes > 0) {
      final file = File(p.join(directory, stderr.descriptor.sha256));
      final head = BytesBuilder(copy: false);
      await for (final chunk in file.openRead(0, _stderrBytes)) {
        head.add(chunk);
      }
      errorText = utf8.decode(head.takeBytes(), allowMalformed: true);
    }
    return _rgOutcome(
      result.exit ?? -1,
      errorText,
      rewriter,
      found,
      none,
      target,
    );
  } finally {
    detach();
  }
}

/// How long an `rg` job may run.
const Duration _rgDeadline = Duration(seconds: 600);

ToolOutcome _rgOutcome(
  int code,
  String errorText,
  SearchLineRewriter rewriter,
  String Function() found,
  String none,
  _Target target,
) {
  switch (code) {
    case 0 || 1:
      // The counts are of accepted lines only; rg may have found more.
      return ToolOutcome(
        summary: '${rewriter.lines == 0 ? none : found()}${target.note}',
      );
    default:
      final text = errorText
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .join(' ');
      return ToolOutcome(
        status: ResultStatus.error,
        summary: text.isEmpty ? 'rg exited with code $code' : text,
        complete: rewriter.lines == 0,
      );
  }
}

/// Runs `rg` as a direct child, for a context without a job supervisor.
Future<ToolOutcome> _runRgDirect(
  ToolContext context,
  RgFound rg,
  _Target target,
  List<String> arguments,
  SearchLineRewriter rewriter,
  String Function() found,
  String none,
) async {
  if (context.cancel.isCancelled) return _cancelled;
  final ArgvRun run;
  try {
    run = await startArgv(
      rg.path,
      arguments,
      workingDirectory: target.cwd,
      environment: childEnvironment(Platform.environment),
    );
  } on ProcessException catch (e) {
    return failure('cannot run rg: ${e.message}');
  }
  final detach = context.cancel.listen(run.kill);
  var closed = false;
  try {
    await for (final chunk in run.stdout) {
      final out = rewriter.add(chunk);
      if (out.isNotEmpty) await context.output.write(out);
      if (context.output.isClosed) {
        closed = true;
        run.kill();
        break;
      }
    }
    if (!closed) {
      final rest = rewriter.finish();
      if (rest.isNotEmpty) await context.output.write(rest);
    }
    final code = await run.exitCode;
    final errorText = utf8.decode(await run.stderr, allowMalformed: true);
    if (context.cancel.isCancelled) return _cancelled;
    if (closed) {
      return const ToolOutcome(
        status: ResultStatus.error,
        summary: 'search stopped: output closed',
        complete: false,
      );
    }
    switch (code) {
      case 0 || 1:
        // The counts are of accepted lines only; rg may have found more.
        return ToolOutcome(
          summary: '${rewriter.lines == 0 ? none : found()}${target.note}',
        );
      default:
        final text = errorText
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .join(' ');
        return ToolOutcome(
          status: ResultStatus.error,
          summary: text.isEmpty ? 'rg exited with code $code' : text,
          complete: rewriter.lines == 0,
        );
    }
  } finally {
    detach();
  }
}

Future<(RgFound?, ToolOutcome?)> _rgOf(Future<RgResolution> rg) async =>
    switch (await rg) {
      final RgFound found => (found, null),
      final RgMissing missing => (null, failure(missing.message)),
    };

/// `grep`: a regular expression over file contents, through `rg`.
final class GrepTool implements Tool {
  /// Creates the tool over the [rg] resolution made at attach.
  const GrepTool(this.rg);

  /// The `rg` resolution.
  final Future<RgResolution> rg;

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    final (found, missing) = await _rgOf(rg);
    if (missing != null) return missing;
    final (target, failed) = _resolveTarget(
      context,
      input,
      directoryOnly: false,
    );
    if (failed != null) return failed;
    final glob = input['glob'] as String?;
    final rewriter = SearchLineRewriter(
      grep: true,
      prefix: target!.prefix,
      filter: glob == null ? null : GlobMatcher(glob),
    );
    return _runRg(
      context,
      found!,
      target,
      [
        '--no-config',
        '--line-number',
        '--no-heading',
        '--color',
        'never',
        '--with-filename',
        '--null',
        if (input['ignore_case'] == true) '--ignore-case',
        if (input['literal'] == true) '--fixed-strings',
        // The call's glob is applied to the output, never given to rg, which
        // would let it override ignore files and hidden rules.
        if (target.exclusion != null) ...[
          target.exclusionFlag,
          target.exclusion!,
        ],
        '-e',
        input['pattern']! as String,
        '--',
        target.file ?? '.',
      ],
      rewriter,
      () =>
          '${_plural(rewriter.lines, 'match', 'matches')} in '
          '${_plural(rewriter.files, 'file', 'files')} (rg ${found.version})',
      'no matches',
    );
  }
}

/// `find`: file paths matching a glob, through `rg --files`.
final class FindTool implements Tool {
  /// Creates the tool over the [rg] resolution made at attach.
  const FindTool(this.rg);

  /// The `rg` resolution.
  final Future<RgResolution> rg;

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    final (found, missing) = await _rgOf(rg);
    if (missing != null) return missing;
    final (target, failed) = _resolveTarget(
      context,
      input,
      directoryOnly: true,
    );
    if (failed != null) return failed;
    final rewriter = SearchLineRewriter(
      grep: false,
      prefix: target!.prefix,
      filter: GlobMatcher(input['glob']! as String),
    );
    return _runRg(
      context,
      found!,
      target,
      [
        '--no-config',
        '--files',
        '--color',
        'never',
        if (input['hidden'] == true) '--hidden',
        if (input['no_ignore'] == true) '--no-ignore',
        if (target.exclusion != null) ...[
          target.exclusionFlag,
          target.exclusion!,
        ],
        '--',
        '.',
      ],
      rewriter,
      () => _plural(rewriter.lines, 'file', 'files'),
      '0 files',
    );
  }
}

/// `ls`: one directory, in process.
final class LsTool implements Tool {
  /// Creates the tool.
  const LsTool();

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    final raw = (input['path'] as String?) ?? '.';
    final absolute = absolutePath(context.workspace, raw);
    switch (FileSystemEntity.typeSync(absolute)) {
      case FileSystemEntityType.notFound:
        return failure('no such directory $raw');
      case FileSystemEntityType.directory:
        break;
      default:
        return failure('$raw is not a directory');
    }
    final entries = <(String, String)>[];
    await for (final entry in Directory(absolute).list(followLinks: false)) {
      if (context.cancel.isCancelled) return _cancelled;
      entries.add((
        p.basename(entry.path),
        entry is Link
            ? '@'
            : entry is Directory
            ? '/'
            : '',
      ));
    }
    entries.sort((a, b) => a.$1.compareTo(b.$1));
    if (entries.isNotEmpty) {
      await context.output.writeText(
        '${entries.map((e) => '${e.$1}${e.$2}').join('\n')}\n',
      );
    }
    return ToolOutcome(
      summary: '$raw: ${_plural(entries.length, 'entry', 'entries')}',
    );
  }
}
