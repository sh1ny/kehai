/// Agent jobs on resume (subagents spec: *Agent jobs on resume*; design D11:
/// the typed result in the crash-safe handoff).
///
/// A killed engine is simulated by the state it leaves: the job node, the
/// launch record and the spool files, written by hand and reopened.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/job_support.dart';
import '../support/session_support.dart';

const String _id = 'j1';
const String _launch = 'l1';
const String _role = 'specwright-reviewer';
const String _typed =
    'agent specwright-reviewer done (3 steps, session child-1)\n'
    'VERDICT: APPROVE\n';

Map<String, String> get _spools => {
  for (final s in JobKind.agent.streams) s: '.spool-$_launch-$s',
};

/// Writes the spool [stream] of the session in [dir] with [text].
File _spool(Directory dir, String stream, String text) {
  final results = Directory(p.join(dir.path, resultsDirName))
    ..createSync(recursive: true);
  return File(p.join(results.path, _spools[stream]))..writeAsStringSync(text);
}

Map<String, Object?> _entry(String stream, String text) {
  final bytes = utf8.encode(text);
  return {
    'spool': _spools[stream],
    'sha256': sha256.convert(bytes).toString(),
    'bytes': bytes.length,
    'lines': '\n'.allMatches(text).length,
    'complete': true,
  };
}

/// A session whose engine died with an agent job running.
///
/// [text] maps a stream to the content of its spool file; [intent] lists the
/// streams of a committed handoff intent.
Future<Directory> _crashed({
  required Map<String, String> text,
  Set<String> intent = const {},
  bool hello = true,
}) async {
  final root = await tempDir();
  final writer = await SessionWriter.create(root);
  final session = writer.tree.get(SessionPath.parse('meta/session'));
  await writer.apply(
    rec(1, 'jobs/$_id', Op.set, {
      'kind': 'agent',
      'cmd': _role,
      'cwd': '.',
      'shell': 'bash',
      'launch': _launch,
      'state': 'running',
      'spool': _spools,
      if (hello)
        'agent': {'role': _role, 'model': 'gpt-fake', 'session': 'child-1'},
    }),
  );
  await writer.apply(
    rec(1, 'meta/handoffs/$_launch', Op.set, {
      'job': _id,
      'session': session,
      'spools': _spools,
    }),
  );
  for (final MapEntry(:key, :value) in text.entries) {
    _spool(writer.sessionDir, key, value);
  }
  if (intent.isNotEmpty) {
    await writer.apply(
      rec(1, 'meta/handoffs/$_launch', Op.merge, {
        'streams': {for (final s in intent) s: _entry(s, text[s]!)},
        'outcome': {
          'state': 'settled',
          'ended': '2026-01-01T00:00:00.000Z',
          'exit': 0,
          'agent': {
            'role': _role,
            'model': 'gpt-fake',
            'session': 'child-1',
            'status': 'done',
            'steps': 3,
            'usage': {'total_tokens': 9},
          },
        },
      }),
    );
  }
  await writer.close();
  return writer.sessionDir;
}

String _resultText(Reopened r) {
  final ref = r.node('jobs/$_id')['result']! as Map<String, Object?>;
  return utf8.decode(
    resolveHandle(
      r.writer.tree,
      r.writer.sessionDir,
      ref['handle']! as String,
    ).file.readAsBytesSync(),
  );
}

void main() {
  const streams = {
    'stdout': '{"hello":1}\n',
    'stderr': '',
    'output': '{"hello":1}\n',
    'result': _typed,
  };

  test(
    'resume after the intent settles the job with a resolvable result',
    () async {
      final dir = await _crashed(text: streams, intent: streams.keys.toSet());
      // Published before the crash: its spool is gone, the final name holds it.
      final published =
          File(p.join(dir.path, resultsDirName, _spools['stderr']))..renameSync(
            p.join(
              dir.path,
              resultsDirName,
              sha256.convert(utf8.encode('')).toString(),
            ),
          );
      expect(published.existsSync(), isFalse);

      final r = await reopen(dir);

      final node = r.node('jobs/$_id');
      expect(node['state'], 'settled');
      expect(node['exit'], 0);
      expect(node.containsKey('absent'), isFalse);
      expect(node['agent'], {
        'role': _role,
        'model': 'gpt-fake',
        'session': 'child-1',
        'status': 'done',
        'steps': 3,
        'usage': {'total_tokens': 9},
      });
      expect((node['result']! as Map)['complete'], isTrue);
      expect(_resultText(r), _typed);
      expect(r.stream('jobs/$_id', 'stdout'), '{"hello":1}\n');
      expect(r.at('meta/handoffs/$_launch'), isNull);
      expect(r.spools(), isEmpty);
      expect(r.runtime.resumed.jobs, 1);
      expect(r.runtime.resumed.discarded, 0);
    },
  );

  test(
    'resume before the intent cancels the job with the interrupted text',
    () async {
      final dir = await _crashed(
        text: {
          'stdout': '{"hello":1}\n',
          'stderr': '',
          'output': '{"hello":1}\n',
        },
      );

      final r = await reopen(dir);

      final node = r.node('jobs/$_id');
      expect(node['state'], 'cancelled');
      expect(node['reason'], 'interrupted');
      expect(node['cmd'], _role);
      expect(node.containsKey('result'), isFalse);
      expect(node['absent'], contains('result'));
      final agent = node['agent']! as Map<String, Object?>;
      expect(agent['status'], 'cancelled');
      expect(agent['role'], _role);
      expect(agent['session'], 'child-1');
      expect(r.stream('jobs/$_id', 'stdout'), '{"hello":1}\n');
      expect(r.complete('jobs/$_id', 'stdout'), isFalse);
      expect(r.at('meta/handoffs/$_launch'), isNull);
      expect(r.runtime.resumed.discarded, 0);
    },
  );

  test('an uncommitted result spool is discarded and counted', () async {
    for (final written in [_typed, 'agent specwright-reviewer do']) {
      final dir = await _crashed(
        text: {
          'stdout': '{"hello":1}\n',
          'stderr': '',
          'output': '{"hello":1}\n',
          'result': written,
        },
      );
      final resultSha = sha256.convert(utf8.encode(written)).toString();

      final r = await reopen(dir);

      final node = r.node('jobs/$_id');
      expect(node['state'], 'cancelled', reason: written);
      expect(node['reason'], 'interrupted');
      expect(node.containsKey('result'), isFalse);
      expect(node['absent'], contains('result'));
      expect((node['agent']! as Map)['status'], 'cancelled');
      expect(r.spools(), isEmpty, reason: 'the result spool is deleted');
      expect(
        File(p.join(dir.path, resultsDirName, resultSha)).existsSync(),
        isFalse,
        reason: 'the result is never published',
      );
      expect(r.runtime.resumed.discarded, 1);
      expect(
        r.runtime.resumed.warning,
        contains('1 agent results discarded before their handoff'),
      );
      expect(r.at('meta/handoffs/$_launch'), isNull);
    }
  });

  test(
    'a running agent job is finalized interrupted and never relaunched',
    () async {
      final dir = await _crashed(text: {'stdout': '{"hel', 'output': '{"hel'});
      final before = journalLength(dir);

      final r = await reopen(dir);

      final node = r.node('jobs/$_id');
      expect(node['state'], 'cancelled');
      expect(node['reason'], 'interrupted');
      expect((node['agent']! as Map)['status'], 'cancelled');
      expect(r.stream('jobs/$_id', 'output'), '{"hel');
      expect(r.runtime.resumed.jobs, 1);
      expect(r.runtime.resumed.warning, contains('may still run'));
      expect(
        r.records().skip(before).where((e) => e.path == 'jobs/$_id').length,
        1,
        reason: 'finalized once, no new launch of the job',
      );
      expect(r.spools(), isEmpty, reason: 'no child, nothing writes a spool');
    },
  );
}
