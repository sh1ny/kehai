import 'package:kehai/src/workspace/frontmatter.dart';
import 'package:test/test.dart';

void main() {
  test('text without a leading --- line has no frontmatter', () {
    final f = parseFrontmatter('# Title\n---\nx: 1\n---\n');
    expect(f.present, isFalse);
    expect(f.error, isNull);
    expect(f.body, '# Title\n---\nx: 1\n---\n');
  });

  test('a mapping between the first two --- lines is read, body follows', () {
    final f = parseFrontmatter(
      '---\r\nname: "OPSX: Propose"\r\nuser-invocable: false\r\nother: [1, 2]\r\n---\r\nBody\r\n',
    );
    expect(f.present, isTrue);
    expect(f.error, isNull);
    expect(f.data['name'], 'OPSX: Propose');
    expect(f.data['user-invocable'], false);
    expect(f.body, 'Body\r\n');
  });

  test('an unclosed block is an error', () {
    final f = parseFrontmatter('---\nname: x\nBody\n');
    expect(f.error, contains('not closed'));
  });

  test('invalid YAML reports the file line', () {
    final f = parseFrontmatter('---\nname: x\nbad: [1, 2\n---\nBody\n');
    expect(f.error, startsWith('invalid YAML frontmatter at line '));
  });

  test('a scalar or list is not a mapping', () {
    expect(parseFrontmatter('---\n- a\n- b\n---\n').error, contains('mapping'));
  });
}
