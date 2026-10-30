import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/session_support.dart';

const _sha = 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
const _handle = 'r/abcdef012345';
const _other = 'r/111111111111';

ResultDescriptor _descriptor() =>
    ResultDescriptor(handle: _handle, sha256: _sha, bytes: 3, lines: 1);

/// The ownership guard of a call node: it exists with this attempt.
GuardedDecision _owned(GuardedRead read, Object? value) {
  final node = read('body/calls/c1');
  if (node is! Map<String, Object?> || node['attempt'] != 'a1') {
    return const GuardedRefusal('stale');
  }
  return GuardedAppend(rec(1, 'body/calls/c1', Op.merge, value));
}

int _lines(SessionWriter writer) =>
    journalOf(writer.sessionDir).readAsLinesSync().length;

void main() {
  late Directory root;
  late SessionWriter writer;
  setUp(() async {
    root = await tempDir();
    writer = await createWriter(root);
  });

  group('applyGuarded', () {
    test('appends the built record', () async {
      await writer.apply(rec(1, 'body/calls/c1', Op.set, {'attempt': 'a1'}));
      final before = _lines(writer);

      final outcome = await writer.applyGuarded(
        (read) => _owned(read, {'status': 'running'}),
      );

      expect(outcome, isA<Applied>());
      expect((outcome as Applied).update.record.path, 'body/calls/c1');
      expect(_lines(writer), before + 1);
      expect(
        writer.tree.get(SessionPath.parse('body/calls/c1/status')),
        'running',
      );
    });

    test(
      'returns stale when a rewind queued before removed the owner',
      () async {
        await writer.apply(rec(1, 'body/seed', Op.set, 1));
        await writer.apply(rec(2, 'body/calls/c1', Op.set, {'attempt': 'a1'}));
        final before = _lines(writer);

        final rewound = writer.rewind(1);
        final guarded = writer.applyGuarded(
          (read) => _owned(read, {'status': 'running'}),
        );
        await rewound;
        final outcome = await guarded;

        expect(
          outcome,
          isA<Refused>().having((r) => r.reason, 'reason', 'stale'),
        );
        expect(_lines(writer), before + 1, reason: 'only the rewind landed');
        expect(
          writer.tree.contains(SessionPath.parse('body/calls/c1')),
          isFalse,
        );
      },
    );

    test('a custom refusal completes the call and appends nothing', () async {
      final before = _lines(writer);

      final outcome = await writer.applyGuarded(
        (_) => const GuardedRefusal('unsettled'),
      );

      expect(
        outcome,
        isA<Refused>().having((r) => r.reason, 'reason', 'unsettled'),
      );
      expect(_lines(writer), before);
    });

    test(
      'refuses descriptors missing, listing every unregistered handle',
      () async {
        await writer.apply(rec(1, 'body/calls/c1', Op.set, {'attempt': 'a1'}));
        await writer.recordResult(_descriptor());
        final before = _lines(writer);

        final outcome = await writer.applyGuarded(
          (read) => _owned(read, {
            'result': {'handle': _other, 'complete': true},
            'extra': [
              {'handle': 'r/222222222222', 'complete': false},
              {'handle': _handle, 'complete': true},
            ],
          }),
        );

        expect(
          outcome,
          isA<Refused>()
              .having((r) => r.reason, 'reason', 'descriptors missing')
              .having((r) => r.handles, 'handles', [_other, 'r/222222222222']),
        );
        expect(_lines(writer), before, reason: 'a refusal appends nothing');
        expect(writer.tree.get(SessionPath.parse('body/calls/c1')), {
          'attempt': 'a1',
        });
      },
    );

    test(
      'a handle named in call input is not a reference and is not checked',
      () async {
        await writer.apply(rec(1, 'body/calls/c1', Op.set, {'attempt': 'a1'}));

        final outcome = await writer.applyGuarded(
          (read) => _owned(read, {
            'input': {'handle': 'r/333333333333', 'from': 401},
          }),
        );

        expect(outcome, isA<Applied>());
      },
    );

    test('appends once the referenced descriptor is registered', () async {
      await writer.apply(rec(1, 'body/calls/c1', Op.set, {'attempt': 'a1'}));
      GuardedDecision build(GuardedRead read) => _owned(read, {
        'result': {'handle': _handle, 'complete': true},
      });

      expect(await writer.applyGuarded(build), isA<Refused>());
      await writer.recordResult(_descriptor());

      expect(await writer.applyGuarded(build), isA<Applied>());
    });

    test(
      'checks descriptors at the queue head after a queued rewind',
      () async {
        await writer.apply(rec(1, 'body/calls/c1', Op.set, {'attempt': 'a1'}));
        await writer.recordResult(_descriptor());
        await writer.apply(rec(2, 'body/other', Op.set, 1));

        final rewound = writer.rewind(0);
        final guarded = writer.applyGuarded(
          (_) => GuardedAppend(
            rec(2, 'body/calls/d1', Op.set, {
              'result': {'handle': _handle, 'complete': true},
            }),
          ),
        );
        await rewound;

        expect(
          await guarded,
          isA<Refused>().having((r) => r.handles, 'handles', [_handle]),
        );
      },
    );
  });
}
