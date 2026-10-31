/// The console code page switch of the line client (design D14).
library;

import 'package:kehai/src/client/console_codepage.dart';
import 'package:test/test.dart';

final class _FakePages implements ConsoleCodePages {
  _FakePages(this.input, this.output, {this.canSet = true});

  @override
  int input;

  @override
  int output;

  final bool canSet;

  @override
  bool setInput(int codePage) {
    if (canSet) input = codePage;
    return canSet;
  }

  @override
  bool setOutput(int codePage) {
    if (canSet) output = codePage;
    return canSet;
  }
}

void main() {
  test('console code pages become UTF-8 and are restored on exit', () {
    final pages = _FakePages(437, 850);

    final restore = useUtf8Console(pages);
    expect([pages.input, pages.output], [65001, 65001]);

    restore();
    expect([pages.input, pages.output], [437, 850]);
  });

  test('a console already in UTF-8 is left as it was', () {
    final pages = _FakePages(65001, 65001);

    useUtf8Console(pages)();

    expect([pages.input, pages.output], [65001, 65001]);
  });

  test('pages that cannot be set are not restored over', () {
    final pages = _FakePages(437, 850, canSet: false);

    useUtf8Console(pages)();

    expect([pages.input, pages.output], [437, 850]);
  });
}
