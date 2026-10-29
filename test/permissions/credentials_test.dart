import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/session_support.dart';

const String _secret = 'SECRET-TOKEN-0123456789';

/// The family of names the credential store writes in the Kehai home.
const List<String> _credentialNames = [
  'auth.json',
  'auth.dpapi',
  'auth.lock',
  'auth.json.1234_0.tmp',
];

void main() {
  late Directory ws;
  late Directory home;
  setUp(() async {
    ws = await tempDir();
    home = Directory(p.join(ws.path, '.kehai-home'))..createSync();
    for (final name in _credentialNames) {
      File(p.join(home.path, name)).writeAsStringSync(_secret);
    }
  });

  Future<ToolRuntime> attach({required bool gated}) async {
    final writer = await createWriter(ws);
    final runtime = await ToolRuntime.attach(
      writer,
      ResultStore(writer.sessionDir),
      workspace: ws,
      kehaiHome: home,
      yolo: true,
      gate: gated ? null : const AllowAllStage(),
    );
    addTearDown(runtime.close);
    return runtime;
  }

  Map<String, Object?> args(String tool, String path) => switch (tool) {
    'read' => {'path': path},
    'edit' => {
      'path': path,
      'anchors': ['1#AAAA'],
      'ops': [
        {'op': 'delete', 'start': 1, 'end': 1},
      ],
    },
    _ => {'path': path, 'content': 'overwritten'},
  };

  test(
    'file tools refuse every auth.* in the Kehai home even under yolo',
    () async {
      // The gate refuses first; with no gate the tools refuse on their own.
      for (final gated in [true, false]) {
        final runtime = await attach(gated: gated);
        var n = 0;
        for (final name in _credentialNames) {
          for (final tool in ['read', 'edit', 'write']) {
            final paths = [
              p.join('.kehai-home', name),
              p.join(home.path, name),
              p.join('sub', '..', '.kehai-home', name),
            ];
            for (final path in paths) {
              final id = 'c${gated ? 'g' : 'n'}${n++}';
              final item = await runtime.run(
                ToolCall(
                  callId: id,
                  name: tool,
                  argumentsJson: jsonEncode(args(tool, path)),
                ),
              );

              final reason = 'gated=$gated $tool $path';
              expect(item.output, startsWith('[$tool denied]'), reason: reason);
              expect(
                item.output,
                contains('credential files are not readable by tools'),
                reason: reason,
              );
              expect(item.output, isNot(contains(_secret)), reason: reason);
              final node =
                  runtime.writer.tree.get(
                        SessionPath.parse('body/calls/${callKey(id)}'),
                      )!
                      as Map<String, Object?>;
              expect(node['status'], 'settled', reason: reason);
              expect(node['envelope'], 'denied', reason: reason);
              final handle =
                  (node['result']! as Map<String, Object?>)['handle']!
                      as String;
              final stored = resolveHandle(
                runtime.writer.tree,
                runtime.writer.sessionDir,
                handle,
              ).file.readAsStringSync();
              expect(stored, isNot(contains(_secret)), reason: reason);
            }
          }
        }
        // Nothing was read, edited, replaced or left behind.
        for (final name in _credentialNames) {
          expect(
            File(p.join(home.path, name)).readAsStringSync(),
            _secret,
            reason: name,
          );
        }
        expect(
          home.listSync().map((e) => p.basename(e.path)).toList()..sort(),
          [..._credentialNames]..sort(),
        );
      }
    },
  );
}
