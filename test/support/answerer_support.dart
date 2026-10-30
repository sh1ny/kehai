import 'dart:async';

import 'package:kehai/kehai.dart';

/// An [Answerer] that records what reaches it and lets a test reply later.
final class RecordingAnswerer implements Answerer {
  /// Every item delivered, in order.
  final List<PromptItem> items = [];

  /// Every key withdrawn, in order.
  final List<String> withdrawn = [];

  final List<Completer<PromptItem>> _waiting = [];

  @override
  void prompt(PromptItem item) {
    items.add(item);
    if (_waiting.isNotEmpty) _waiting.removeAt(0).complete(item);
  }

  @override
  void withdraw(String key) => withdrawn.add(key);

  /// The item number [index] (0-based), waiting for it when it has not come.
  Future<PromptItem> item(int index) {
    if (items.length > index) return Future.value(items[index]);
    final completer = Completer<PromptItem>();
    _waiting.add(completer);
    return completer.future.then((_) => item(index));
  }
}
