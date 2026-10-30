import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/session_support.dart';
import '../support/tool_support.dart';

void main() {
  late Directory ws;
  setUp(() async => ws = await tempDir());

  Future<(ToolOutcome, RecordingOutput)> write(
    String path,
    String content, {
    FileWriteSeams seams = const FileWriteSeams(),
  }) async {
    final output = RecordingOutput();
    final outcome = await WriteTool(seams: seams)
        .run(toolContext(ws, output), {'path': path, 'content': content});
    return (outcome, output);
  }

  test('write creates missing directories and reports created', () async {
    final (outcome, _) = await write('tool/new/gen.dart', 'a\nb\n');

    final file = File(p.join(ws.path, 'tool', 'new', 'gen.dart'));
    expect(outcome.status, ResultStatus.ok, reason: outcome.summary);
    expect(outcome.summary, 'created tool/new/gen.dart (4 bytes, 2 lines)');
    expect(file.readAsStringSync(), 'a\nb\n');
    expect(
      Directory(p.dirname(file.path)).listSync().map((e) => p.basename(e.path)),
      ['gen.dart'],
    );

    final (again, _) = await write('tool/new/gen.dart', 'solo');
    expect(again.summary, 'replaced tool/new/gen.dart (4 bytes, 1 line)');
    expect(file.readAsStringSync(), 'solo');

    final (empty, _) = await write('tool/new/empty.txt', '');
    expect(empty.summary, 'created tool/new/empty.txt (0 bytes, 0 lines)');

    final (dir, _) = await write('tool', 'x');
    expect(dir.status, ResultStatus.error);
    expect(dir.summary, 'tool is a directory');
  });

  test('failed rename leaves the target and no temporary file', () async {
    final target = File(p.join(ws.path, 'target.txt'))
      ..writeAsBytesSync([0x01, 0x02, 0xFF, 0x0a]);
    final before = target.readAsBytesSync();
    var attempts = 0;

    final (outcome, _) = await write(
      'target.txt',
      'replacement\n',
      seams: FileWriteSeams(
        rename: (from, to) async {
          attempts++;
          expect(File(from).existsSync(), isTrue, reason: 'temp is written');
          throw const FileSystemException('The process cannot access the file');
        },
      ),
    );

    expect(attempts, 1);
    expect(outcome.status, ResultStatus.error);
    expect(outcome.summary, contains('rename failed'));
    expect(outcome.summary, contains('cannot access'));
    expect(target.readAsBytesSync(), before);
    expect(ws.listSync().map((e) => p.basename(e.path)), ['target.txt']);
  });

  test(
    'permission bits of the target survive a write',
    skip: Platform.isWindows ? 'POSIX permission bits' : null,
    () async {
      final target = File(p.join(ws.path, 'script.sh'))
        ..writeAsStringSync('old');
      Process.runSync('chmod', ['750', target.path]);

      await write('script.sh', 'new');

      expect(target.statSync().mode & 0xFFF, int.parse('750', radix: 8));
      expect(utf8.decode(target.readAsBytesSync()), 'new');
    },
  );

  test(
    'the temporary file has the target mode before any content is written',
    skip: Platform.isWindows ? 'POSIX permission bits' : null,
    () async {
      final target = File(p.join(ws.path, '.env'))..writeAsStringSync('old');
      Process.runSync('chmod', ['600', target.path]);
      int? mode;
      int? length;

      await write(
        '.env',
        'SECRET=new',
        seams: FileWriteSeams(
          beforeContent: (temporary) async {
            final stat = File(temporary).statSync();
            mode = stat.mode & 0xFFF;
            length = stat.size;
          },
        ),
      );

      expect(length, 0);
      expect(mode, int.parse('600', radix: 8));
      expect(target.statSync().mode & 0xFFF, int.parse('600', radix: 8));
      expect(target.readAsStringSync(), 'SECRET=new');
    },
  );
}
