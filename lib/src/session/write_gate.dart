import 'dart:async';
import 'dart:collection';

/// The number of writer operations the engine lets run at once.
const int writeGatePermits = 48;

/// Admits the engine's writer operations in arrival order, at most
/// [permits] at a time (design D17).
///
/// An operation holds a permit only while its own writer call runs and never
/// awaits another gated operation, so the gate cannot deadlock. It keeps the
/// writer's own pending-operation limit from being reached by many concurrent
/// callers.
final class WriteGate {
  /// Creates a gate with [permits] permits.
  WriteGate({this.permits = writeGatePermits});

  /// How many operations may run at once.
  final int permits;

  final Queue<Completer<void>> _waiting = Queue();
  int _held = 0;

  /// Runs [operation] when it is first in line and a permit is free.
  Future<T> run<T>(Future<T> Function() operation) async {
    if (_held >= permits || _waiting.isNotEmpty) {
      final turn = Completer<void>();
      _waiting.add(turn);
      // The releasing operation hands its permit over, so [_held] stays put.
      await turn.future;
    } else {
      _held++;
    }
    try {
      return await operation();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _held--;
      }
    }
  }
}
