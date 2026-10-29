/// Ctrl-C during `kehai logout openai` (design D6a), run in-process.
@Timeout(Duration(minutes: 1))
library;

import 'dart:async';

import 'package:kehai/src/cli/cli.dart';
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/login_support.dart';

void main() {
  late TestHome home;
  late FakeOpenAi fake;

  setUp(() async {
    home = TestHome();
    fake = await FakeOpenAi.start();
  });

  test('an interrupt during revocation still clears the tokens and exits '
      'zero with the not-confirmed line', () async {
    home.store.replace(loggedInRecord(generation: 3));
    fake.revocationScripts.add(
      const RevocationScript(delay: Duration(seconds: 25)),
    );
    final interrupts = StreamController<Object?>.broadcast();
    final out = StringBuffer();
    final err = StringBuffer();

    final pending = runCli(
      ['logout', 'openai'],
      environment: {
        'KEHAI_HOME': home.path,
        'KEHAI_OPENAI_ISSUER': fake.issuer,
        'KEHAI_OPENAI_API_BASE': fake.apiBase,
      },
      out: out,
      err: err,
      interrupts: interrupts.stream,
    );
    while (fake.revocationRequests.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    interrupts.add(null);
    final code = await pending.timeout(const Duration(seconds: 10));

    expect(code, 0, reason: '$out\n$err');
    expect(out.toString(), contains('remote revocation was not confirmed'));
    expect(out.toString(), isNot(contains('refresh-')));
    final record = home.store.load()!;
    expect(record.tokens, isNull);
    expect(record.generation, 4);
    expect(interrupts.hasListener, isFalse, reason: 'subscription disposed');
    await interrupts.close();
  });
}
