import 'dart:io';

/// Makes [link] a directory link to [target]: a junction made with
/// `cmd /c mklink /J` on Windows, a symbolic link elsewhere.
void linkDirectory(String link, String target) {
  if (Platform.isWindows) {
    final r = Process.runSync('cmd', ['/c', 'mklink', '/J', link, target]);
    if (r.exitCode != 0) {
      throw StateError('mklink /J failed: ${r.stdout}${r.stderr}');
    }
  } else {
    Link(link).createSync(target);
  }
}
