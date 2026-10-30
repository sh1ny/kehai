/// Real shell detection (design D7).
///
/// Detection runs once, when the tool runtime attaches. It reads the
/// filesystem and `PATH` through seams so every platform's order is testable
/// on any host.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../permissions/workspace_paths.dart';

/// Which shell runs `bash` commands.
enum ShellKind {
  /// `bash` on Linux and macOS.
  bash('bash'),

  /// Git for Windows' `bash.exe`.
  gitBash('git-bash'),

  /// PowerShell 7.
  pwsh('pwsh'),

  /// Windows PowerShell.
  powershell('powershell');

  const ShellKind(this.label);

  /// The name the tool description and result summaries use.
  final String label;

  /// Whether the shell is a POSIX shell, so commands can be proven read-only.
  bool get isPosix => this == bash || this == gitBash;
}

/// A detected shell.
final class ShellInfo {
  /// Creates the shell description.
  const ShellInfo({required this.kind, required this.executable, this.setsid});

  /// Which shell it is.
  final ShellKind kind;

  /// The absolute path of the shell program.
  final String executable;

  /// The absolute path of `setsid`, when a POSIX host has it.
  ///
  /// Without it a command is launched directly and terminating its process
  /// group is reported `uncertain`.
  final String? setsid;

  /// The name the tool description and result summaries use.
  String get name => kind.label;

  /// Whether commands are proven read-only under this shell.
  bool get isPosix => kind.isPosix;

  @override
  String toString() => '$name ($executable)';
}

/// The outcome of detection: a shell, or what was tried.
final class ShellDetection {
  /// A successful detection.
  const ShellDetection.found(ShellInfo this.shell) : tried = const [];

  /// A failed detection that looked for [tried].
  const ShellDetection.missing(this.tried) : shell = null;

  /// The shell, or null when none was found.
  final ShellInfo? shell;

  /// What was looked for, when [shell] is null.
  final List<String> tried;

  /// The message every `bash` call settles with when no shell was found.
  String? get failure =>
      shell == null ? 'no shell found; tried ${tried.join(', ')}' : null;

  /// What the user can do about a missing shell.
  String? get hint => shell == null
      ? (tried.contains('bash')
            ? 'install bash and put it on PATH'
            : 'install Git for Windows (git-bash) or PowerShell 7 (pwsh)')
      : null;
}

/// Whether [path] names an existing file.
typedef FileProbe = bool Function(String path);

bool _isFile(String path) =>
    FileSystemEntity.typeSync(path) == FileSystemEntityType.file;

/// The value of [name] in [environment], ignoring case.
String? environmentValue(Map<String, String> environment, String name) {
  for (final entry in environment.entries) {
    if (entry.key.toUpperCase() == name.toUpperCase()) return entry.value;
  }
  return null;
}

/// The `PATH` entries of [environment] that are absolute paths.
///
/// Relative entries (`.`, `bin`) and empty ones name the working directory,
/// which can be the workspace, so they never count.
List<String> absolutePathEntries(
  Map<String, String> environment, {
  required bool windows,
}) {
  final context = windows ? p.windows : p.posix;
  final value = environmentValue(environment, 'PATH');
  if (value == null) return const [];
  return [
    for (final entry in value.split(windows ? ';' : ':'))
      if (entry.isNotEmpty && context.isAbsolute(entry)) entry,
  ];
}

/// The first file named [names] in the absolute `PATH` entries, or null.
///
/// Entries are tried in order and, within an entry, [names] in order.
String? findOnPath(
  List<String> names,
  Map<String, String> environment, {
  required bool windows,
  FileProbe? isFile,
}) =>
    allOnPath(names, environment, windows: windows, isFile: isFile).firstOrNull;

/// Every file named [names] in the absolute `PATH` entries, in search order.
Iterable<String> allOnPath(
  List<String> names,
  Map<String, String> environment, {
  required bool windows,
  FileProbe? isFile,
}) sync* {
  final context = windows ? p.windows : p.posix;
  final probe = isFile ?? _isFile;
  for (final dir in absolutePathEntries(environment, windows: windows)) {
    for (final name in names) {
      final candidate = context.join(dir, name);
      if (probe(candidate)) yield candidate;
    }
  }
}

/// [probe] narrowed to files whose real path is outside [workspaceRoot].
///
/// A program the repository supplies (a `PATH` entry inside the workspace, or
/// a link into it) is repository code, so it is never picked automatically,
/// as for `resolveProgram`. With no [workspaceRoot], [probe] is unchanged.
FileProbe _outsideWorkspace(FileProbe probe, String? workspaceRoot) {
  if (workspaceRoot == null) return probe;
  final root = realPath(workspaceRoot);
  return (path) {
    if (!probe(path)) return false;
    final real = realPath(path);
    return root != null && real != null && !isInside(root, real);
  };
}

/// Finds the shell for the host.
///
/// With a [workspaceRoot] nothing inside it is chosen: not the shell, nor
/// `setsid`, nor `git`. [environment] defaults to the process environment, [windows] to the host
/// platform and [isFile] to a real filesystem check.
///
/// On Linux and macOS it is `bash` on `PATH`. On Windows it is Git Bash's
/// `bash.exe` beside `git.exe` from `PATH` (in the same directory or in a
/// sibling `bin`), then `%ProgramFiles%\Git\bin\bash.exe`, then `pwsh`, then
/// `powershell`. `System32\bash.exe` is the WSL launcher and is never used.
ShellDetection detectShell({
  Map<String, String>? environment,
  bool? windows,
  FileProbe? isFile,
  String? workspaceRoot,
}) {
  final env = environment ?? Platform.environment;
  final onWindows = windows ?? Platform.isWindows;
  final probe = _outsideWorkspace(isFile ?? _isFile, workspaceRoot);
  if (!onWindows) {
    final bash = findOnPath(const ['bash'], env, windows: false, isFile: probe);
    if (bash == null) return const ShellDetection.missing(['bash']);
    return ShellDetection.found(
      ShellInfo(
        kind: ShellKind.bash,
        executable: bash,
        setsid: findOnPath(
          const ['setsid'],
          env,
          windows: false,
          isFile: probe,
        ),
      ),
    );
  }

  final gitBash = _gitBash(env, probe);
  if (gitBash != null) {
    return ShellDetection.found(
      ShellInfo(kind: ShellKind.gitBash, executable: gitBash),
    );
  }
  for (final (kind, file) in [
    (ShellKind.pwsh, 'pwsh.exe'),
    (ShellKind.powershell, 'powershell.exe'),
  ]) {
    final found = findOnPath([file], env, windows: true, isFile: probe);
    if (found != null) {
      return ShellDetection.found(ShellInfo(kind: kind, executable: found));
    }
  }
  return const ShellDetection.missing([
    r'git-bash (bash.exe beside git.exe, then %ProgramFiles%\Git\bin)',
    'pwsh',
    'powershell',
  ]);
}

String? _gitBash(Map<String, String> env, FileProbe probe) {
  final w = p.windows;
  final candidates = <String>[];
  // Every git.exe on PATH counts, not only the first: a shim directory
  // (Scoop) can come before the real installation.
  for (final git in allOnPath(
    const ['git.exe'],
    env,
    windows: true,
    isFile: probe,
  )) {
    final dir = w.dirname(git);
    candidates
      ..add(w.normalize(w.join(dir, '..', 'bin', 'bash.exe')))
      ..add(w.join(dir, 'bash.exe'));
  }
  final programFiles = environmentValue(env, 'ProgramFiles');
  if (programFiles != null) {
    candidates.add(w.join(programFiles, 'Git', 'bin', 'bash.exe'));
  }
  final systemRoot = environmentValue(env, 'SystemRoot');
  for (final candidate in candidates) {
    if (!probe(candidate)) continue;
    // `System32\bash.exe` is the WSL launcher, not a shell for commands.
    final inSystem =
        w.split(candidate.toLowerCase()).contains('system32') ||
        (systemRoot != null &&
            w.isWithin(systemRoot.toLowerCase(), candidate.toLowerCase()));
    if (!inSystem) return candidate;
  }
  return null;
}
