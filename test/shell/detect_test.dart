import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String _git = r'C:\Program Files\Git';
const String _system32 = r'C:\Windows\System32';

ShellDetection _windows(Iterable<String> files, String path, {String? pf}) =>
    detectShell(
      windows: true,
      environment: {
        'Path': path,
        'ProgramFiles': ?pf,
        'SystemRoot': r'C:\Windows',
      },
      isFile: files.toSet().contains,
    );

ShellDetection _posix(Iterable<String> files, String path) => detectShell(
  windows: false,
  environment: {'PATH': path},
  isFile: files.toSet().contains,
);

void main() {
  group('detection order on Windows', () {
    test('Git Bash beside git.exe wins and System32 bash is never chosen', () {
      final files = [
        '$_system32\\bash.exe',
        '$_git\\cmd\\git.exe',
        '$_git\\bin\\bash.exe',
        r'C:\Program Files\PowerShell\7\pwsh.exe',
        '$_system32\\WindowsPowerShell\\v1.0\\powershell.exe',
      ];
      final path =
          '$_system32;$_git\\cmd;C:\\Program Files\\PowerShell\\7;'
          '$_system32\\WindowsPowerShell\\v1.0';

      final found = _windows(files, path).shell!;
      expect(found.kind, ShellKind.gitBash);
      expect(found.name, 'git-bash');
      expect(found.executable, '$_git\\bin\\bash.exe');
      expect(found.isPosix, isTrue);

      // The WSL launcher is skipped even when it is the only bash around,
      // and even when git.exe itself lives in System32.
      final wsl = _windows([
        '$_system32\\bash.exe',
        '$_system32\\git.exe',
        r'C:\Program Files\PowerShell\7\pwsh.exe',
      ], path);
      expect(wsl.shell!.kind, ShellKind.pwsh);
      expect(wsl.shell!.executable, isNot(contains('bash')));
    });

    test('bash.exe in the same directory as git.exe is found', () {
      final found = _windows([
        r'C:\Git\bin\git.exe',
        r'C:\Git\bin\bash.exe',
      ], r'C:\Git\bin').shell!;
      expect(found.executable, r'C:\Git\bin\bash.exe');
    });

    test('a git shim ahead of the real git does not hide Git Bash', () {
      final found = _windows([
        r'F:\scoop\shims\git.exe',
        r'F:\scoop\git\cmd\git.exe',
        r'F:\scoop\git\bin\bash.exe',
      ], r'F:\scoop\shims;F:\scoop\git\cmd').shell!;
      expect(found.kind, ShellKind.gitBash);
      expect(found.executable, r'F:\scoop\git\bin\bash.exe');
    });

    test('%ProgramFiles% is tried when git is not on PATH', () {
      final found = _windows(
        ['$_git\\bin\\bash.exe'],
        _system32,
        pf: r'C:\Program Files',
      ).shell!;
      expect(found.kind, ShellKind.gitBash);
      expect(found.executable, '$_git\\bin\\bash.exe');
    });

    test('pwsh comes before Windows PowerShell', () {
      const pwsh = r'C:\Program Files\PowerShell\7\pwsh.exe';
      const legacy = '$_system32\\WindowsPowerShell\\v1.0\\powershell.exe';
      const path =
          r'C:\Windows\System32\WindowsPowerShell\v1.0;'
          r'C:\Program Files\PowerShell\7';

      final both = _windows([pwsh, legacy], path).shell!;
      expect(both.kind, ShellKind.pwsh);
      expect(both.isPosix, isFalse);

      final only = _windows([legacy], path).shell!;
      expect(only.kind, ShellKind.powershell);
      expect(only.name, 'powershell');
    });

    test('relative PATH entries are never searched', () {
      final found = _windows([r'.\pwsh.exe', r'bin\pwsh.exe'], r'.;bin;;');
      expect(found.shell, isNull);
    });
  });

  group('detection on POSIX', () {
    test('bash is the first one on an absolute PATH entry', () {
      final found = _posix([
        '/opt/bin/bash',
        '/usr/bin/bash',
        '/usr/bin/setsid',
      ], 'bin:/opt/bin:/usr/bin').shell!;
      expect(found.kind, ShellKind.bash);
      expect(found.name, 'bash');
      expect(found.executable, '/opt/bin/bash');
      expect(found.setsid, '/usr/bin/setsid');
      expect(found.isPosix, isTrue);
    });

    test('a missing setsid leaves the shell usable', () {
      final found = _posix(['/bin/bash'], '/bin').shell!;
      expect(found.setsid, isNull);
    });
  });

  group('no shell', () {
    test('no shell found fails attach-time detection with a hint', () {
      final windows = _windows([
        '$_system32\\bash.exe',
        '$_git\\cmd\\git.exe',
      ], '$_system32;$_git\\cmd');
      expect(windows.shell, isNull);
      expect(windows.failure, startsWith('no shell found; tried '));
      expect(windows.failure, contains('pwsh'));
      expect(windows.failure, contains('powershell'));
      expect(windows.failure, contains('git-bash'));
      expect(windows.hint, contains('Git for Windows'));

      final posix = _posix(const [], '/usr/bin');
      expect(posix.shell, isNull);
      expect(posix.failure, 'no shell found; tried bash');
      expect(posix.hint, contains('bash'));
    });
  });

  group('real detection', () {
    test('finds Git Bash or PowerShell on Windows, never System32 bash', () {
      final found = detectShell();
      expect(found.shell, isNotNull, reason: '${found.failure}');
      final exe = found.shell!.executable.toLowerCase();
      expect(File(exe).existsSync(), isTrue);
      expect(p.split(exe), isNot(contains('system32')));
      if (found.shell!.kind == ShellKind.gitBash) {
        expect(p.basename(exe), 'bash.exe');
      }
    }, skip: Platform.isWindows ? false : 'Windows only');

    test('finds bash on Linux and macOS', () {
      final found = detectShell();
      expect(found.shell, isNotNull, reason: '${found.failure}');
      expect(found.shell!.kind, ShellKind.bash);
      expect(p.isAbsolute(found.shell!.executable), isTrue);
      expect(File(found.shell!.executable).existsSync(), isTrue);
    }, skip: Platform.isWindows ? 'POSIX only' : false);
  });
}
