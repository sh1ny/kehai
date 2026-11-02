/// The command line the client starts `kehai rpc` with (design D1).
library;

import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

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

    test(
      'a compiled executable recognizes its Windows short-path spelling',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'kehai-engine-command-long-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final executable = File(p.join(dir.path, 'compiled-kehai.exe'))
          ..writeAsStringSync('fixture');
        final batch = File(p.join(dir.path, 'short.bat'))
          ..writeAsStringSync(
            '@for %%I in ("%~dp0compiled-kehai.exe") do @echo %%~sI\r\n',
          );
        final result = await Process.run('cmd.exe', ['/d', '/c', batch.path]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final shortPath = (result.stdout as String).trim();
        if (p.equals(shortPath, executable.path)) {
          markTestSkipped('8.3 short names are disabled on this volume');
          return;
        }
        expect(
          File(shortPath).resolveSymbolicLinksSync(),
          executable.resolveSymbolicLinksSync(),
        );

        for (final paths in [
          (shortPath, executable.path),
          (executable.path, shortPath),
        ]) {
          final command = engineCommand(
            const ['--model', 'm'],
            executable: paths.$1,
            executableArguments: const ['--not-a-vm-flag'],
            script: Uri.file(paths.$2),
          );
          expect(command.executable, paths.$1);
          expect(command.arguments, ['rpc', '--model', 'm']);
        }
      },
      skip: !Platform.isWindows,
    );
  });
}
