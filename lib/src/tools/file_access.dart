/// What `read`, `edit` and `write` share: path resolution, the credential
/// refusal, the per-file lock and message formats (design D4, D5, D6).
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../permissions/credentials.dart';
import '../permissions/gate.dart' show credentialRefusal;
import '../permissions/workspace_paths.dart';
import '../results/composer.dart';
import 'tool.dart';

/// The real path the model's [raw] path names, relative to [workspace].
///
/// This resolves the path with [realPath], the function the permission gate
/// uses, so the path a tool opens is the one the gate approved. A `..` after a
/// link is applied to the link's target, as POSIX does; a lexical collapse
/// would name a different file than the one approved. A part that does not
/// exist yet is appended to its nearest existing ancestor. When a link cannot
/// be resolved, the gate has not approved the path, and the unresolved join is
/// returned, normalized only where the platform resolves `..` lexically.
String absolutePath(Directory workspace, String raw) {
  final joined = p.join(workspace.absolute.path, raw);
  return realPath(joined) ??
      (p.style == p.Style.windows ? p.normalize(joined) : joined);
}

/// The outcome that refuses a credential file, or null when [absolute] is not
/// one.
///
/// The permission gate refuses the same paths before a tool runs. This is the
/// tools' own check, so a file tool never reads or writes an `auth.*` file of
/// the Kehai home even when a call reaches it without that gate. It compares
/// the resolved path, so a link to a credential file is refused too.
ToolOutcome? credentialDenial(ToolContext context, String absolute) {
  final home = context.kehaiHome;
  if (home == null || !isCredentialTarget(absolute, home)) return null;
  return const ToolOutcome(
    status: ResultStatus.denied,
    summary: credentialRefusal,
  );
}

/// An `error` outcome with [summary].
ToolOutcome failure(String summary) =>
    ToolOutcome(status: ResultStatus.error, summary: summary);

/// The outcome of a mutation whose call was cancelled before it changed
/// anything.
const ToolOutcome cancelledMutation = ToolOutcome(
  status: ResultStatus.error,
  summary: 'cancelled',
  complete: false,
);

/// [bytes] as `<n.n> MiB`.
String mebibytes(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';

/// Runs file mutations one at a time per resolved path.
///
/// Two edits of one file in this process never interleave their validation
/// and rename (design, flow gaps). Paths compare ignoring case on Windows.
final class PathLocks {
  PathLocks._();

  static final Map<String, Future<void>> _tails = {};

  /// Runs [action] once every earlier action on [path] has finished.
  static Future<T> run<T>(String path, Future<T> Function() action) async {
    final key = p.style == p.Style.windows ? path.toLowerCase() : path;
    final previous = _tails[key] ?? Future<void>.value();
    final done = Completer<void>();
    final tail = previous.then((_) => done.future);
    _tails[key] = tail;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
      if (identical(_tails[key], tail)) _tails.remove(key);
    }
  }
}
