import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/bash_support.dart';

void main() {
  group('search jobs', () {
    test('grep and find run rg as shell-less supervised jobs', () async {
      final h = await BashHarness.create();
      File(p.join(h.workspace.path, 'a.txt')).writeAsStringSync('needle\n');

      final grep = await h.call('grep', {'pattern': 'needle'});

      expect(grep, contains('a.txt:1: needle'));
      expect(h.jobNodes, hasLength(1));
      var job = h.jobNodes.values.single;
      expect(job['kind'], 'shell');
      expect(job['shell'], isNull);
      expect(job['state'], 'settled');
      expect(job['exit'], 0);
      expect(job['cmd'], contains('rg'));

      final find = await h.call('find', {'glob': '*.txt'});

      expect(find, contains('a.txt'));
      expect(h.jobNodes, hasLength(2));
      job = h.jobNodes.values.last;
      expect(job['shell'], isNull);
      expect(job['cmd'], contains('--files'));
    });
  });
}
