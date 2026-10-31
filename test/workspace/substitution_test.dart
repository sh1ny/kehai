import 'package:kehai/src/workspace/substitution.dart';
import 'package:test/test.dart';

void main() {
  test('CLAUDE_SKILL_DIR becomes the forward-slash base and shell variables '
      'stay', () {
    final out = substitute(
      r'run ${CLAUDE_SKILL_DIR}/scripts/ then $HOME and ${BASH_SOURCE}',
      baseDir: r'F:\work\.claude\skills\specwright-pr',
      arguments: '',
    );
    expect(
      out,
      r'run F:/work/.claude/skills/specwright-pr/scripts/ then $HOME and '
      r'${BASH_SOURCE}',
    );
  });

  test(r'$ARGUMENTS with no args becomes empty and no ARGUMENTS line is '
      'added', () {
    final out = renderLoaded(r'Do: $ARGUMENTS.', arguments: '');
    expect(out, 'Do: .');
  });

  test('args without a placeholder add an ARGUMENTS line; a skill adds its '
      'base directory line', () {
    expect(
      renderLoaded('Body\n', arguments: 'next', baseDir: '/r/s'),
      'Base directory for this skill: /r/s\n\nBody\n\nARGUMENTS: next',
    );
    expect(
      renderLoaded(r'Use $ARGUMENTS now', arguments: 'next'),
      'Use next now',
    );
  });

  test(r'arguments that look like placeholders are not substituted again', () {
    expect(
      substitute(
        r'$ARGUMENTS',
        baseDir: '/b',
        arguments: r'${CLAUDE_SKILL_DIR}',
      ),
      r'${CLAUDE_SKILL_DIR}',
    );
  });
}
