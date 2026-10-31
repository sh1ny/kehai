import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/anchor_support.dart';
import '../support/session_support.dart';
import '../support/tool_support.dart';

String _rows(int n) => [for (var i = 1; i <= n; i++) 'row $i\n'].join();

/// The anchors `1#H`, `17#H`, … of [bytes], as `read` would show them.
List<String> _anchors(List<int> bytes) => [
  for (final (i, h) in definitionHashes(bytes).indexed) '${i * 16 + 1}#$h',
];

Map<String, Object?> _replace(int start, int end, String text) => {
  'op': 'replace',
  'start': start,
  'end': end,
  'text': text,
};

Map<String, Object?> _insert(int after, String text) => {
  'op': 'insert',
  'after': after,
  'text': text,
};

Map<String, Object?> _delete(int start, int end) => {
  'op': 'delete',
  'start': start,
  'end': end,
};

void main() {
  late Directory ws;
  late int renames;
  late EditTool tool;
  setUp(() async {
    ws = await tempDir();
    renames = 0;
    tool = EditTool(
      seams: FileWriteSeams(
        rename: (from, to) async {
          renames++;
          await File(from).rename(to);
        },
      ),
    );
  });

  File put(String name, List<int> bytes) =>
      File(p.join(ws.path, name))..writeAsBytesSync(bytes);

  Future<(ToolOutcome, RecordingOutput)> edit(
    String path,
    List<String> anchors,
    List<Map<String, Object?>> ops, {
    EditTool? using,
  }) async {
    final output = RecordingOutput();
    final outcome = await (using ?? tool).run(toolContext(ws, output), {
      'path': path,
      'anchors': anchors,
      'ops': ops,
    });
    return (outcome, output);
  }

  List<String> names() =>
      [for (final e in ws.listSync()) p.basename(e.path)]..sort();

  test(
    'replace and insert apply on original numbering in one rename',
    () async {
      final file = put('v.txt', utf8.encode(_rows(40)));
      final anchors = _anchors(file.readAsBytesSync());

      final (outcome, output) = await edit(
        'v.txt',
        [anchors[0], anchors[1]],
        [_replace(3, 4, 'a\nb\nc'), _insert(20, 'X')],
      );

      final want = [
        'row 1',
        'row 2',
        'a',
        'b',
        'c',
        for (var i = 5; i <= 20; i++) 'row $i',
        'X',
        for (var i = 21; i <= 40; i++) 'row $i',
      ];
      final bytes = file.readAsBytesSync();
      expect(outcome.status, ResultStatus.ok, reason: outcome.summary);
      expect(utf8.decode(bytes), '${want.join('\n')}\n');
      expect(renames, 1);
      expect(names(), ['v.txt'], reason: 'no temporary file remains');
      expect(outcome.summary, 'edited v.txt: 2 operations, 40 → 42 lines');

      // The touched blocks of the new file are shown with fresh anchors; the
      // block after them is listed because the line count changed.
      final fresh = definitionHashes(bytes);
      expect(fresh, hasLength(3));
      final lines = output.lines;
      expect(lines, hasLength(33));
      for (var i = 0; i < 32; i++) {
        final prefix = i % 16 == 0
            ? '${i + 1}#${fresh[i ~/ 16]}:'
            : '${i + 1}:';
        expect(lines[i], '$prefix${want[i]}');
      }
      expect(lines[32], 'later anchors: 33#${fresh[2]}');
    },
  );

  test('overlapping and out-of-range ops are rejected unchanged', () async {
    final file = put('h.txt', utf8.encode(_rows(100)));
    final before = file.readAsBytesSync();
    final anchors = _anchors(before);

    final overlap = await edit('h.txt', anchors, [
      _replace(5, 8, 'x'),
      _delete(7, 9),
    ]);
    final beyond = await edit('h.txt', anchors, [_replace(120, 120, 'x')]);
    final inside = await edit('h.txt', anchors, [
      _replace(5, 8, 'x'),
      _insert(6, 'y'),
    ]);
    final twice = await edit('h.txt', anchors, [
      _insert(9, 'x'),
      _insert(9, 'y'),
    ]);
    final after = await edit('h.txt', anchors, [_insert(101, 'x')]);
    final adjacent = await edit('h.txt', anchors, [
      _insert(4, 'y'),
      _replace(5, 8, 'x'),
      _insert(8, 'z'),
    ]);

    expect(overlap.$1.status, ResultStatus.error);
    expect(overlap.$1.summary, 'operations overlap at lines 7–8');
    expect(beyond.$1.summary, 'line 120 does not exist (file has 100 lines)');
    expect(inside.$1.summary, 'operations overlap at lines 6–7');
    expect(twice.$1.summary, 'operations overlap after line 9');
    expect(after.$1.summary, 'line 101 does not exist (file has 100 lines)');
    expect(adjacent.$1.status, ResultStatus.ok, reason: adjacent.$1.summary);
    expect(renames, 1, reason: 'only the valid edit renamed');
    final now = utf8.decode(file.readAsBytesSync()).split('\n');
    expect(now.sublist(3, 9), ['row 4', 'y', 'x', 'z', 'row 9', 'row 10']);
    expect(now, hasLength(100), reason: '99 lines and the final newline');

    // The rejection is also the call's body.
    expect(overlap.$2.text, 'operations overlap at lines 7–8\n');
  });

  test('no-op edit is rejected and the file is not rewritten', () async {
    final file = put('v.txt', utf8.encode(_rows(40)));
    final before = file.readAsBytesSync();
    final stat = file.statSync();

    final (outcome, _) = await edit(
      'v.txt',
      [_anchors(before)[0]],
      [_replace(3, 3, 'row 3')],
    );

    expect(outcome.status, ResultStatus.error);
    expect(outcome.summary, 'edit made no change');
    expect(renames, 0);
    expect(file.readAsBytesSync(), before);
    expect(file.statSync().modified, stat.modified);
    expect(names(), ['v.txt']);
  });

  test('moved block reports stale anchor with its new hash', () async {
    final file = put('v.txt', utf8.encode(_rows(40)));
    final anchors = _anchors(file.readAsBytesSync());
    final lines = utf8.decode(file.readAsBytesSync()).split('\n')
      ..insert(1, 'inserted');
    file.writeAsStringSync(lines.join('\n'));
    final moved = file.readAsBytesSync();
    final newHash = definitionHashes(moved)[1];

    final (outcome, _) = await edit(
      'v.txt',
      [anchors[1]],
      [_replace(18, 18, 'changed')],
    );

    expect(outcome.status, ResultStatus.error);
    expect(
      outcome.summary,
      'stale anchor ${anchors[1]}: lines 17–32 now hash $newHash; '
      'read the file again',
    );
    expect(file.readAsBytesSync(), moved);
    expect(renames, 0);
  });

  test('every stale anchor is listed in one rejection', () async {
    final file = put('v.txt', utf8.encode(_rows(40)));
    final anchors = _anchors(file.readAsBytesSync());
    final lines = utf8.decode(file.readAsBytesSync()).split('\n');
    lines[0] = 'changed first';
    lines[32] = 'changed last';
    file.writeAsStringSync(lines.join('\n'));
    final changed = file.readAsBytesSync();
    final now = definitionHashes(changed);

    final (outcome, output) = await edit(
      'v.txt',
      [anchors[0], anchors[2]],
      [_replace(2, 2, 'x'), _replace(34, 34, 'y')],
    );

    expect(outcome.status, ResultStatus.error);
    expect(output.lines, [
      'stale anchor ${anchors[0]}: lines 1–16 now hash ${now[0]}; '
          'read the file again',
      'stale anchor ${anchors[2]}: lines 33–40 now hash ${now[2]}; '
          'read the file again',
    ]);
    expect(file.readAsBytesSync(), changed);
  });

  test('unnamed touched block and non-block anchor are rejected', () async {
    final file = put('v.txt', utf8.encode(_rows(40)));
    final before = file.readAsBytesSync();
    final anchors = _anchors(before);

    final unnamed = await edit('v.txt', [anchors[0]], [_replace(20, 21, 'x')]);
    final notStart = await edit('v.txt', ['18#BBBB'], [_replace(20, 21, 'x')]);
    final garbage = await edit('v.txt', ['nonsense'], [_replace(20, 21, 'x')]);
    final gone = await edit('v.txt', [anchors[0], '49#AAAA'], [_delete(1, 1)]);

    expect(unnamed.$1.summary, 'no anchor for block 17 (lines 17–32)');
    expect(
      notStart.$1.summary,
      '18#BBBB is not a block anchor; blocks start at 1, 17, 33, …',
    );
    expect(
      garbage.$1.summary,
      'nonsense is not a block anchor; blocks start at 1, 17, 33, …',
    );
    expect(gone.$1.status, ResultStatus.error);
    expect(gone.$1.summary, contains('49#AAAA'));
    expect(file.readAsBytesSync(), before);
    expect(renames, 0);
  });

  test('BOM and per-line endings survive an edit byte for byte', () async {
    final lines = [for (var i = 1; i <= 20; i++) 'row $i'];
    final original = <int>[
      0xEF,
      0xBB,
      0xBF,
      for (var i = 0; i < 20; i++) ...[
        ...utf8.encode(lines[i]),
        ...(i == 8 ? [0x0a] : [0x0d, 0x0a]),
      ],
    ];
    final file = put('c.txt', original);
    final anchors = _anchors(original);

    final (outcome, _) = await edit(
      'c.txt',
      [anchors[0]],
      [_replace(3, 3, 'new three\nextra')],
    );

    final want = <int>[
      0xEF,
      0xBB,
      0xBF,
      for (var i = 0; i < 20; i++) ...[
        if (i == 2)
          ...utf8.encode('new three\r\nextra')
        else
          ...utf8.encode(lines[i]),
        ...(i == 8 ? [0x0a] : [0x0d, 0x0a]),
      ],
    ];
    expect(outcome.status, ResultStatus.ok, reason: outcome.summary);
    expect(file.readAsBytesSync(), want);

    // The last line has no newline: replacing another line keeps that, and
    // inserting after it moves the missing newline to the new last line.
    final tail = put('t.txt', utf8.encode('a\r\nb\r\nc'));
    await edit('t.txt', _anchors(tail.readAsBytesSync()), [
      _replace(1, 1, 'A'),
    ]);
    expect(utf8.decode(tail.readAsBytesSync()), 'A\r\nb\r\nc');
    await edit('t.txt', _anchors(tail.readAsBytesSync()), [_insert(3, 'd\ne')]);
    expect(utf8.decode(tail.readAsBytesSync()), 'A\r\nb\r\nc\r\nd\r\ne');
    final cr = put('r.txt', utf8.encode('a\rb\rc\r'));
    await edit('r.txt', _anchors(cr.readAsBytesSync()), [_insert(0, 'z')]);
    expect(utf8.decode(cr.readAsBytesSync()), 'z\ra\rb\rc\r');
    final empty = put('e.txt', const []);
    await edit('e.txt', const [], [_insert(0, 'only')]);
    expect(utf8.decode(empty.readAsBytesSync()), 'only\n');
    final swapped = put('s.txt', utf8.encode('x\ny\nz'));
    await edit('s.txt', _anchors(swapped.readAsBytesSync()), [_delete(2, 3)]);
    expect(utf8.decode(swapped.readAsBytesSync()), 'x\n');

    // Deleting the unterminated last line and inserting after it adds no
    // blank line: the delete already left the output ending in a newline.
    final gone = put('g.txt', utf8.encode('a\nb'));
    await edit('g.txt', _anchors(gone.readAsBytesSync()), [
      _delete(2, 2),
      _insert(2, 'c'),
    ]);
    expect(utf8.decode(gone.readAsBytesSync()), 'a\nc');
  });

  test('invalid UTF-8 file is refused unchanged', () async {
    final bytes = Uint8List.fromList([...utf8.encode('ok\n'), 0xFF, 0x0a]);
    final file = put('bad.txt', bytes);

    final (outcome, _) = await edit('bad.txt', ['1#AAAA'], [_delete(1, 1)]);

    expect(outcome.status, ResultStatus.error);
    expect(outcome.summary, 'bad.txt is not valid UTF-8; edit refused');
    expect(file.readAsBytesSync(), bytes);
    expect(renames, 0);
  });

  test('20 MiB file is refused with the 16 MiB limit', () async {
    final file = File(p.join(ws.path, 'big.txt'));
    writeRepeated(
      file,
      Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 0x61),
      20,
    );
    final stat = file.statSync();

    final (outcome, _) = await edit('big.txt', ['1#AAAA'], [_delete(1, 1)]);

    expect(outcome.status, ResultStatus.error);
    expect(outcome.summary, 'file too large to edit (20.0 MiB, limit 16 MiB)');
    expect(file.statSync().size, stat.size);
    expect(file.statSync().modified, stat.modified);
    expect(renames, 0);
  });

  test(
    'a file changed after validation is rejected before the rename',
    () async {
      final file = put('v.txt', utf8.encode(_rows(40)));
      final anchors = _anchors(file.readAsBytesSync());
      final racing = EditTool(
        seams: FileWriteSeams(
          rename: tool.seams.rename,
          beforeRename: () async =>
              file.writeAsStringSync('someone else\n', mode: FileMode.append),
        ),
      );

      final (outcome, _) = await edit(
        'v.txt',
        [anchors[0]],
        [_replace(1, 1, 'mine')],
        using: racing,
      );

      expect(outcome.status, ResultStatus.error);
      expect(outcome.summary, 'file changed during edit; read the file again');
      expect(file.readAsStringSync(), endsWith('someone else\n'));
      expect(file.readAsStringSync(), startsWith('row 1\n'));
      expect(renames, 0);
      expect(names(), ['v.txt']);
    },
  );

  test(
    'two parallel edits of one file serialize; the second is stale',
    () async {
      final file = put('v.txt', utf8.encode(_rows(40)));
      final anchors = _anchors(file.readAsBytesSync());

      final results = await Future.wait([
        edit('v.txt', [anchors[0]], [_replace(1, 1, 'first')]),
        edit('v.txt', [anchors[0]], [_replace(2, 2, 'second')]),
      ]);

      expect(
        results[0].$1.status,
        ResultStatus.ok,
        reason: results[0].$1.summary,
      );
      expect(results[1].$1.status, ResultStatus.error);
      expect(results[1].$1.summary, startsWith('stale anchor 1#'));
      expect(file.readAsStringSync(), startsWith('first\nrow 2\n'));
    },
  );

  test('an orphan temporary file is reported in the next summary', () async {
    final file = put('v.txt', utf8.encode(_rows(3)));
    put('.v.txt.kehai-deadbeef', const [1]);

    final (outcome, _) = await edit(
      'v.txt',
      [_anchors(file.readAsBytesSync())[0]],
      [_delete(1, 1)],
    );

    expect(outcome.status, ResultStatus.ok);
    expect(outcome.summary, contains('.v.txt.kehai-deadbeef'));
    expect(names(), ['.v.txt.kehai-deadbeef', 'v.txt']);
  });

  group('approval binding', () {
    Future<ToolOutcome> approved(List<int> shown) async {
      final target = realPath(p.join(ws.path, 'a.txt'))!;
      final bytes = File(target).readAsBytesSync();
      return tool.run(
        toolContext(
          ws,
          RecordingOutput(),
          permission: {
            'decision': 'allow',
            'by': 'answer',
            'target': target,
            'sha256': sha256.convert(shown).toString(),
          },
        ),
        {
          'path': 'a.txt',
          'anchors': _anchors(bytes),
          'ops': [_delete(1, 1)],
        },
      );
    }

    test('an edit of a file changed after approval is refused', () async {
      final shown = utf8.encode('a\nb\n');
      final file = put('a.txt', utf8.encode('z\nb\n'));

      final outcome = await approved(shown);

      expect(outcome.status, ResultStatus.denied);
      expect(outcome.summary, fileChangedRefusal);
      expect(file.readAsStringSync(), 'z\nb\n');
      expect(renames, 0);
    });

    test('an edit with the approved hash applies', () async {
      final shown = utf8.encode('a\nb\n');
      final file = put('a.txt', shown);

      final outcome = await approved(shown);

      expect(outcome.status, ResultStatus.ok, reason: outcome.summary);
      expect(file.readAsStringSync(), 'b\n');
    });
  });
}
