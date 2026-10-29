/// Token estimation for serialized requests (design D10).
library;

import 'dart:convert';

import 'provider.dart';

/// The UTF-8 bytes assumed to make one token.
const int _bytesPerToken = 3;

/// Estimates the input tokens of a serialized request.
///
/// [serialized] is either the request body bytes (a `List<int>`) or a
/// JSON-encodable value, which is encoded to JSON first. The estimate is the
/// UTF-8 byte count divided by three, rounded up, so it errs high.
TokenEstimate estimateTokens(Object serialized) {
  final length = serialized is List<int>
      ? serialized.length
      : utf8.encode(jsonEncode(serialized)).length;
  return TokenEstimate((length + _bytesPerToken - 1) ~/ _bytesPerToken);
}
