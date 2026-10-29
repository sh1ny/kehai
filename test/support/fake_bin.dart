import 'dart:io';

import 'package:path/path.dart' as p;

/// Creates [dir] holding an empty executable file for each of [names].
///
/// On Windows the files get an `.exe` extension. They are only found, never
/// run.
Directory fakeBin(Directory dir, Iterable<String> names) {
  dir.createSync(recursive: true);
  for (final name in names) {
    final file = File(p.join(dir.path, Platform.isWindows ? '$name.exe' : name))
      ..writeAsStringSync('');
    if (!Platform.isWindows) Process.runSync('chmod', ['755', file.path]);
  }
  return dir;
}
