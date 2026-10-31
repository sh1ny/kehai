/// The command line the client starts `kehai rpc` with (design D1).
library;

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

/// [path] as this platform's file path.
String _native(String path) => Uri.file(path, windows: false).toFilePath();

void main() {
  group('Engine command', () {
    test('a source script under dart run keeps VM flags and the script', () {
      final command = engineCommand(
        const ['--model', 'm'],
        executable: '/sdk/bin/dart',
        executableArguments: const ['--enable-asserts'],
        script: Uri.file('/src/kehai/bin/kehai.dart', windows: false),
      );

      expect(command.executable, '/sdk/bin/dart');
      expect(command.arguments, [
        '--enable-asserts',
        _native('/src/kehai/bin/kehai.dart'),
        'rpc',
        '--model',
        'm',
      ]);
    });

    test('a snapshot run by the VM keeps the snapshot path', () {
      final command = engineCommand(
        const ['--model', 'm'],
        executable: '/sdk/bin/dart',
        executableArguments: const [],
        script: Uri.file(
          '/cache/global_packages/kehai/bin/kehai.dart-3.9.snapshot',
        ),
      );

      expect(command.executable, '/sdk/bin/dart');
      expect(command.arguments, [
        _native('/cache/global_packages/kehai/bin/kehai.dart-3.9.snapshot'),
        'rpc',
        '--model',
        'm',
      ]);
    });

    test('a compiled executable runs by itself', () {
      final command = engineCommand(
        const ['--model', 'm'],
        executable: _native('/usr/local/bin/kehai'),
        executableArguments: const [],
        script: Uri.file(_native('/usr/local/bin/kehai')),
      );

      expect(command.executable, _native('/usr/local/bin/kehai'));
      expect(command.arguments, ['rpc', '--model', 'm']);
    });
  });
}
