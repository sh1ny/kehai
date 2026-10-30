/// Central truncation across the roster (change core-tools, task 12.1).
///
/// A tool streams its whole output to the result store and never cuts it; the
/// model sees only what `composeResult` renders from the stored bytes. The
/// first test runs every tool of the roster through a real runtime and
/// compares what the tool produced with what was stored and with what the
/// model got. The second one scans the tool and job sources for a cut that
/// happens outside the composer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/anchor_support.dart';
import '../support/job_support.dart';
import '../support/session_support.dart';

/// A [ToolOutput] that forwards to the runtime's output and keeps a copy.
final class _Spy implements ToolOutput {
  _Spy(this.inner);

  final ToolOutput inner;
  final BytesBuilder produced = BytesBuilder(copy: true);

  @override
  bool get isClosed => inner.isClosed;

  @override
  Future<void> write(List<int> bytes) {
    produced.add(bytes);
    return inner.write(bytes);
  }

  @override
  Future<void> writeText(String text) => write(utf8.encode(text));
}

/// Runs a real tool and records what it wrote, per call id.
final class _Tee implements Tool {
  _Tee(this.inner, this.produced);

  final Tool inner;
  final Map<String, Uint8List> produced;

  @override
  Future<ToolOutcome> run(ToolContext c, Map<String, Object?> input) async {
    final spy = _Spy(c.output);
    try {
      return await inner.run(
        ToolContext(
          callKey: c.callKey,
          callId: c.callId,
          output: spy,
          cancel: c.cancel,
          workspace: c.workspace,
          config: c.config,
          prompts: c.prompts,
          kehaiHome: c.kehaiHome,
          shell: c.shell,
          jobs: c.jobs,
          permission: c.permission,
        ),
        input,
      );
    } finally {
      produced[c.callId] = spy.produced.toBytes();
    }
  }
}

/// Answers every question with [text] as soon as it is asked.
final class _Replier implements Answerer {
  _Replier(this.text);

  final String text;
  late final ToolRuntime runtime;

  @override
  void prompt(PromptItem item) {
    scheduleMicrotask(() => runtime.prompts.reply(item.key, text));
  }

  @override
  void withdraw(String key) {}
}

ToolCall _call(String id, String name, Map<String, Object?> args) =>
    ToolCall(callId: id, name: name, argumentsJson: jsonEncode(args));

String _keyOf(String callId) =>
    'c-${sha256.convert(utf8.encode(callId)).toString().substring(0, 12)}';

String _numbered(String prefix, int n) =>
    [for (var i = 1; i <= n; i++) '$prefix $i\n'].join();

const int _roomTokens = 8000;

void main() {
  test(
    "every tool's full bytes are stored and only the composer cuts",
    () async {
      final root = await tempDir();
      final ws = Directory(p.join(root.path, 'ws'))..createSync();
      File(p.join(ws.path, 'big.txt'))
          .writeAsStringSync(_numbered('line', 2000));
      final editBytes = utf8.encode(_numbered('row', 3200));
      File(p.join(ws.path, 'edit.txt')).writeAsBytesSync(editBytes);
      File(p.join(ws.path, 'grep.txt')).writeAsStringSync(
        [for (var i = 1; i <= 4000; i++) 'needle $i in a long enough row\n']
            .join(),
      );
      final many = Directory(p.join(ws.path, 'many'))..createSync();
      for (var i = 0; i < 2500; i++) {
        File(
          p.join(many.path, 'file_${i.toString().padLeft(5, '0')}_padding.dat'),
        ).writeAsStringSync('');
      }
      final seq = [for (var i = 1; i <= 30000; i++) '$i\n'].join();
      final answer = 'x' * 60000;

      final writer = await createWriter(root);
      final store = ResultStore(writer.sessionDir);
      final replier = _Replier(answer);
      final produced = <String, Uint8List>{};
      final runtime = await ToolRuntime.attach(
        writer,
        store,
        workspace: ws,
        gate: const AllowAllStage(),
        answerer: replier,
        tools: {
          'read': _Tee(const ReadTool(), produced),
          'edit': _Tee(const EditTool(), produced),
          'write': _Tee(const WriteTool(), produced),
          'grep': _Tee(
            GrepTool(resolveRg(configPath: 'config.json')),
            produced,
          ),
          'find': _Tee(
            FindTool(resolveRg(configPath: 'config.json')),
            produced,
          ),
          'ls': _Tee(const LsTool(), produced),
          'ask': _Tee(const AskTool(), produced),
          'bash': _Tee(const BashTool(), produced),
          'job': _Tee(const JobTool(), produced),
          'read_more': _Tee(const ReadMoreTool(), produced),
          'search_result': _Tee(SearchResultTool(ResultSearcher()), produced),
        },
      );
      replier.runtime = runtime;
      addTearDown(runtime.close);

      Map<String, Object?> nodeOf(String id) =>
          writer.tree.get(SessionPath.parse('body/calls/${_keyOf(id)}'))!
              as Map<String, Object?>;

      ResolvedResult resolved(String id) {
        final handle =
            (nodeOf(id)['result']! as Map<String, Object?>)['handle']!
                as String;
        return resolveHandle(writer.tree, writer.sessionDir, handle);
      }

      /// Runs [call] and checks the three claims for it; returns the stored
      /// bytes and the text the model got.
      Future<(Uint8List, String)> check(
        ToolCall call, {
        required bool large,
        List<int>? full,
        ResultPolicy? policy,
      }) async {
        final item = await runtime.run(call);
        final node = nodeOf(call.callId);
        expect(node['status'], 'settled', reason: call.name);
        final result = resolved(call.callId);
        final stored = result.file.readAsBytesSync();

        // The stored bytes are the tool's whole output. `bash` and `job`
        // answer with a result the job supervisor stored, so their producer is
        // the job's process, whose output the test knows ([full]).
        final expected = full ?? produced[call.callId]!;
        expect(
          stored,
          expected,
          reason: '${call.name}: stored bytes differ from its full output',
        );
        expect(stored.length, result.descriptor.bytes, reason: call.name);

        // The model text is the central composition of the stored bytes.
        final composed = await composeResult(
          call.name,
          ResultStatus.values.byName(node['envelope']! as String),
          node['summary']! as String,
          result.descriptor,
          result.file,
          policy: policy,
        );
        expect(item.output, composed, reason: call.name);

        // And only that shortens it.
        if (large) {
          expect(
            estimateTokens(stored.length),
            greaterThan(_roomTokens),
            reason: '${call.name}: the fixture is not large enough',
          );
          expect(
            item.output.length,
            lessThan(stored.length),
            reason: call.name,
          );
          expect(item.output, contains(result.descriptor.handle));
          expect(item.output, contains('read_more'), reason: call.name);
        }
        return (stored, item.output);
      }

      // read: 2000 lines against a 400 line room.
      final (readStored, readText) = await check(
        _call('t-read', 'read', {'path': 'big.txt'}),
        large: false,
      );
      expect(readStored.length, greaterThan(utf8.encode(readText).length));
      expect(readText, contains('read_more'));
      expect(
        utf8.decode(readStored),
        contains('line 2000'),
        reason: 'the last line is stored although the model was not shown it',
      );
      expect(readText, isNot(contains('line 2000\n')));

      // edit: the touched blocks of a 3200 line rewrite.
      final anchors = [
        for (final (i, h) in definitionHashes(editBytes).indexed)
          '${i * 16 + 1}#$h',
      ];
      final (editStored, _) = await check(
        _call('t-edit', 'edit', {
          'path': 'edit.txt',
          'anchors': anchors,
          'ops': [
            {
              'op': 'replace',
              'start': 1,
              'end': 3200,
              'text': _numbered('new row', 3200).trimRight(),
            },
          ],
        }),
        large: true,
      );
      expect(utf8.decode(editStored), contains('new row 3200'));

      // write: the content goes to the file, not to the output.
      final (writeStored, _) = await check(
        _call('t-write', 'write', {
          'path': 'out/new.txt',
          'content': _numbered('content', 5000),
        }),
        large: false,
        full: const [],
      );
      expect(writeStored, isEmpty);
      expect(
        File(p.join(ws.path, 'out', 'new.txt')).readAsStringSync(),
        _numbered('content', 5000),
      );

      // bash: 30000 lines.
      final (bashStored, _) = await check(
        _call('t-bash', 'bash', {'command': 'seq 1 30000'}),
        large: true,
        full: utf8.encode(seq),
      );
      expect(bashStored.length, seq.length);

      // job: the finished job's output, by its id.
      final jobs =
          writer.tree.get(SessionPath.parse('jobs'))! as Map<String, Object?>;
      expect(jobs, hasLength(1));
      await check(
        _call('t-job', 'job', {'id': jobs.keys.single, 'action': 'output'}),
        large: true,
        full: utf8.encode(seq),
        // `job output` composes with the `bash` cut (head and tail).
        policy: ResultPolicy.bash,
      );

      // grep, find and ls: long listings.
      final (grepStored, _) = await check(
        _call('t-grep', 'grep', {'pattern': 'needle', 'path': 'grep.txt'}),
        large: true,
      );
      expect(utf8.decode(grepStored).trimRight().split('\n'), hasLength(4000));
      final (findStored, _) = await check(
        _call('t-find', 'find', {'glob': 'many/*.dat'}),
        large: true,
      );
      expect(utf8.decode(findStored).trimRight().split('\n').toSet(), {
        for (var i = 0; i < 2500; i++)
          'many/file_${i.toString().padLeft(5, '0')}_padding.dat',
      });
      final (lsStored, _) = await check(
        _call('t-ls', 'ls', {'path': 'many'}),
        large: true,
        full: utf8.encode(
          [
            for (var i = 0; i < 2500; i++)
              'file_${i.toString().padLeft(5, '0')}_padding.dat\n',
          ].join(),
        ),
      );
      expect(lsStored, isNotEmpty);

      // ask: one long reply, a single line over the per-line cap.
      final (askStored, askText) = await check(
        _call('t-ask', 'ask', {'question': 'Say something long'}),
        large: false,
        full: utf8.encode(jsonEncode({'text': answer})),
      );
      expect(askStored.length, greaterThan(utf8.encode(askText).length));

      // read_more and search_result page through a stored result with the
      // composer itself: they store that page whole and answer with it as it
      // is, and leave the result they read alone.
      final source = resolved('t-bash');
      final before = sha256.convert(source.file.readAsBytesSync()).toString();

      for (final (call, expectedPage) in [
        (
          _call('t-more', 'read_more', {
            'handle': source.descriptor.handle,
            'from': 29000,
            'lines': 50,
          }),
          await readMore(
            source.file,
            source.descriptor,
            from: 29000,
            lines: 50,
          ),
        ),
        (
          _call('t-search', 'search_result', {
            'handle': source.descriptor.handle,
            'pattern': r'^2999\d$',
          }),
          await ResultSearcher().searchResult(
            source.file,
            source.descriptor,
            r'^2999\d$',
          ),
        ),
      ]) {
        final item = await runtime.run(call);
        expect(nodeOf(call.callId)['status'], 'settled', reason: call.name);
        final stored = resolved(call.callId).file.readAsBytesSync();
        expect(stored, produced[call.callId], reason: call.name);
        expect(item.output, expectedPage, reason: call.name);
        expect(utf8.decode(stored), expectedPage, reason: call.name);
      }
      final page = resolved('t-more').file.readAsStringSync();
      expect(page, contains('29000\n'));
      expect(page, contains('29049\n'));
      expect(page, isNot(contains('29050\n')));
      final found = resolved('t-search').file.readAsStringSync();
      expect(found, contains('29990'));
      expect(found, isNot(contains('30000')));

      expect(sha256.convert(source.file.readAsBytesSync()).toString(), before);
      expect(
        sha256.convert(source.file.readAsBytesSync()).toString(),
        source.descriptor.sha256,
      );
    },
    skip: skipWithoutShell(),
  );

  test('no tool or job source cuts output outside the composer', () {
    final cut = RegExp(
      r'\.substring\(|\btake\(|\.sublist\(|\.sublistView\(|\.takeWhile\(|'
      r'\.getRange\(|\.removeRange\(',
    );
    final found = <String>[];
    final used = <_Allowed>{};
    for (final dir in ['lib/src/tools', 'lib/src/jobs']) {
      for (final file in Directory(dir).listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        final name = p.posix.joinAll(p.split(p.relative(file.path)));
        final lines = file.readAsLinesSync();
        for (final (i, line) in lines.indexed) {
          final code = line.trimLeft();
          if (code.startsWith('//')) continue;
          if (!cut.hasMatch(line)) continue;
          final allowed = _allowlist.where(
            (a) => a.file == name && line.contains(a.snippet),
          );
          if (allowed.isEmpty) {
            found.add('$name:${i + 1}: ${code.trim()}');
          } else {
            used.addAll(allowed);
          }
        }
      }
    }
    expect(
      found,
      isEmpty,
      reason:
          'a tool-local cut: cut in the composer, or add the line to the '
          'allowlist with the reason it is not output',
    );
    expect(
      _allowlist.where((a) => !used.contains(a)).map((a) => a.snippet),
      isEmpty,
      reason: 'allowlist entries that no longer match a source line',
    );
  });
}

/// A source line allowed to slice data, with the reason it is not a cut of
/// what the model sees.
final class _Allowed {
  const _Allowed(this.file, this.snippet, this.reason);

  final String file;
  final String snippet;
  final String reason;
}

const List<_Allowed> _allowlist = [
  _Allowed(
    'lib/src/tools/glob_match.dart',
    "pattern.substring(1)",
    'glob pattern parsing: drops a leading slash from the pattern',
  ),
  _Allowed(
    'lib/src/tools/glob_match.dart',
    'pattern.substring(i + 1, close)',
    'glob pattern parsing: the text of a [class]',
  ),
  _Allowed(
    'lib/src/tools/glob_match.dart',
    'members.substring(1)',
    'glob pattern parsing: drops the negation mark of a [class]',
  ),
  _Allowed(
    'lib/src/tools/runtime.dart',
    "toString().substring(0, 12)",
    'the 12 hex digits of a call key, an identifier and not output',
  ),
  _Allowed(
    'lib/src/jobs/recovery.dart',
    "'r/\${sha.substring(0, 12)}'",
    'the 12 hex digits of a result handle, an identifier and not output',
  ),
  _Allowed(
    'lib/src/tools/search.dart',
    'chunk.sublist(0, room)',
    'rg stderr kept for a diagnostic, capped in memory; never stored output',
  ),
  _Allowed(
    'lib/src/tools/search.dart',
    'if (i > from) _head.add(chunk.sublist(from, i));',
    'rg line rewrite: the path of an unfinished line, carried to the next chunk whole',
  ),
  _Allowed(
    'lib/src/tools/search.dart',
    'out.add(chunk.sublist(i, end));',
    'rg line rewrite: the matched text of a line, streamed out in full',
  ),
  _Allowed(
    'lib/src/tools/search.dart',
    'path.sublist(2)',
    'rg line rewrite: drops the leading ./ of a path',
  ),
  _Allowed(
    'lib/src/tools/edit.dart',
    'Uint8List.sublistView(bytes, _begin[n - 1], _end[n - 1])',
    'a zero-copy view of one line of the file being edited, not output',
  ),
  _Allowed(
    'lib/src/tools/edit.dart',
    'Uint8List.sublistView(bytes, _end[n - 1], _next[n - 1])',
    'a zero-copy view of one line ending of the file being edited',
  ),
  _Allowed(
    'lib/src/tools/edit.dart',
    'Uint8List.sublistView(bytes, _begin[from - 1], _next[to - 1])',
    'a zero-copy view of a line range of the file being edited',
  ),
  _Allowed(
    'lib/src/tools/edit.dart',
    'Uint8List.sublistView(file.bytes, 0, file.bom)',
    'the byte order mark of the file being edited, kept on write',
  ),
  _Allowed(
    'lib/src/tools/read.dart',
    'Uint8List.sublistView(_out, 0, _length)',
    'the filled part of the read buffer, flushed whole to the output',
  ),
  _Allowed(
    'lib/src/tools/xxhash32.dart',
    'ByteData.sublistView(',
    'views for the anchor hash; not output',
  ),
];
