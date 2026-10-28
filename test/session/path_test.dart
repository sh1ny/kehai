import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

Matcher invalidPath(String detail) => isA<SessionError>()
    .having((e) => e.reason, 'reason', 'invalid path')
    .having((e) => e.message, 'message', contains(detail));

void main() {
  group('SessionPath', () {
    test('valid path addresses exactly one node', () {
      final tree = SessionTree();
      tree.apply(
        const JournalRecord(
          turn: 3,
          path: 'body/t3/calls/c1:read/status',
          op: Op.set,
          value: 'running',
        ),
      );

      expect(
        tree.canonical(),
        '{"body":{"t3":{"calls":{"c1:read":{"status":"running"}}}}}',
      );
      expect(
        tree.get(SessionPath.parse('body/t3/calls/c1:read/status')),
        'running',
      );
      expect(tree.contains(SessionPath.parse('body/t3/calls')), isTrue);
      expect(tree.contains(SessionPath.parse('body/t3/calls/c1')), isFalse);
    });

    test('segments, root and boundary lengths', () {
      final path = SessionPath.parse('body/a_b.c:d-E9');
      expect(path.segments, ['body', 'a_b.c:d-E9']);
      expect(path.root, 'body');
      expect(path.toString(), 'body/a_b.c:d-E9');
      expect(SessionPath.parse('').isEmpty, isTrue);
      expect(SessionPath.roots, {
        'meta',
        'body',
        'scratch',
        'checkpoints',
        'jobs',
        'collectors',
        'results',
      });
      for (final root in SessionPath.roots) {
        expect(SessionPath.parse(root).segments, [root]);
      }
      expect(SessionPath.parse('body/${'a' * 128}').segments, hasLength(2));
      expect(
        SessionPath.parse(['body', ...List.filled(31, 'x')].join('/')),
        isA<SessionPath>(),
      );
    });

    test('malformed paths are rejected with the offending rule', () {
      final cases = <String, String>{
        'body//x': 'empty segment',
        '/body': 'empty segment',
        'body/': 'empty segment',
        'unknown/x': '"unknown"',
        'body/a b': '"a b"',
        'body/a/bé': 'bé',
        ['body', ...List.filled(32, 'x')].join('/'): '33 segments',
        'body/${'a' * 129}': '129 characters',
      };
      cases.forEach((text, detail) {
        expect(
          () => SessionPath.parse(text),
          throwsA(invalidPath(detail)),
          reason: text,
        );
      });
    });
  });

  group('record path rules', () {
    JournalRecord rec(String path, Op op, [Object? value]) =>
        JournalRecord(turn: 1, path: path, op: op, value: value);

    test('empty path is valid only for origin and rewind', () {
      validateRecordShape(rec('', Op.set, {}), isOrigin: true);
      validateRecordShape(rec('', Op.rewind, 1), isOrigin: false);
      for (final op in [Op.set, Op.merge, Op.del]) {
        expect(
          () => validateRecordShape(rec('', op, {}), isOrigin: false),
          throwsA(invalidPath('empty path')),
          reason: op.wire,
        );
      }
      expect(
        () => validateRecordShape(rec('', Op.merge, {}), isOrigin: true),
        throwsA(invalidPath('origin')),
      );
    });

    test('rewind must use the empty path', () {
      expect(
        () => validateRecordShape(rec('body/a', Op.rewind, 1), isOrigin: false),
        throwsA(invalidPath('rewind')),
      );
    });

    test('record with a non-JSON value is invalid', () {
      expect(
        () => validateRecordShape(
          rec('body/a', Op.set, Object()),
          isOrigin: false,
        ),
        throwsA(
          isA<SessionError>().having(
            (e) => e.reason,
            'reason',
            'invalid record',
          ),
        ),
      );
    });
  });
}
