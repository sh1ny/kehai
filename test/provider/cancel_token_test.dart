import 'dart:async';

import 'package:kehai/src/provider/provider.dart';
import 'package:test/test.dart';

void main() {
  group('CancelToken.listen', () {
    test('calls the listener once on cancel and detaches it', () async {
      final token = CancelToken();
      var calls = 0;
      token.listen(() => calls++);
      expect(token.listenerCount, 1);

      token
        ..cancel()
        ..cancel();
      expect(calls, 0, reason: 'listeners run in a microtask');
      await Future<void>.delayed(Duration.zero);

      expect(calls, 1);
      expect(token.listenerCount, 0);
    });

    test('a detached listener is not called', () async {
      final token = CancelToken();
      var calls = 0;
      final detach = token.listen(() => calls++);
      detach();
      expect(token.listenerCount, 0);

      token.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 0);
    });

    test('an already cancelled token calls the listener at once', () async {
      final token = CancelToken()..cancel();
      final called = Completer<void>();
      token.listen(called.complete);
      await called.future.timeout(const Duration(seconds: 1));
      expect(token.listenerCount, 0);
    });
  });
}
