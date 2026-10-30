/// xxHash32 with a streaming, copyable state (design D4).
///
/// The anchor hash needs a state that can be copied by value, so a run of
/// trailing whitespace of any length costs constant memory; no package offers
/// that. The algorithm is the published xxHash32 and is tested against its
/// reference vectors.
library;

import 'dart:typed_data';

const int _p1 = 0x9E3779B1;
const int _p2 = 0x85EBCA77;
const int _p3 = 0xC2B2AE3D;
const int _p4 = 0x27D4EB2F;
const int _p5 = 0x165667B1;
const int _mask = 0xFFFFFFFF;

int _rotl(int x, int r) => ((x << r) | (x >> (32 - r))) & _mask;

int _round(int acc, int input) =>
    (_rotl((acc + input * _p2) & _mask, 13) * _p1) & _mask;

/// One-shot xxHash32 of [bytes] with [seed].
int xxHash32(List<int> bytes, [int seed = 0]) {
  final state = XxHash32(seed);
  final all = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  state.add(all, 0, all.length);
  return state.digest();
}

/// A streaming xxHash32 state.
///
/// Bytes may arrive in any chunking; the result does not depend on it.
/// [digest] does not change the state, and [copyFrom] copies it by value.
final class XxHash32 {
  /// Creates an empty state with [seed].
  XxHash32([this.seed = 0]) {
    reset();
  }

  /// The seed.
  final int seed;

  int _v1 = 0;
  int _v2 = 0;
  int _v3 = 0;
  int _v4 = 0;
  int _length = 0;
  int _held = 0;
  final Uint8List _tail = Uint8List(16);
  late final ByteData _tailView = ByteData.sublistView(_tail);

  /// Resets to the empty input.
  void reset() {
    _v1 = (seed + _p1 + _p2) & _mask;
    _v2 = (seed + _p2) & _mask;
    _v3 = seed & _mask;
    _v4 = (seed - _p1) & _mask;
    _length = 0;
    _held = 0;
  }

  /// Becomes a copy of [other], which must have the same seed.
  void copyFrom(XxHash32 other) {
    _v1 = other._v1;
    _v2 = other._v2;
    _v3 = other._v3;
    _v4 = other._v4;
    _length = other._length;
    _held = other._held;
    _tail.setRange(0, other._held, other._tail);
  }

  /// Adds one byte.
  void addByte(int byte) {
    _tail[_held++] = byte;
    _length++;
    if (_held == 16) {
      _stripe(_tailView, 0);
      _held = 0;
    }
  }

  /// Adds `buffer[start, end)`.
  void add(Uint8List buffer, int start, int end) {
    var i = start;
    _length += end - start;
    if (_held > 0) {
      final take = (16 - _held) < end - i ? 16 - _held : end - i;
      _tail.setRange(_held, _held + take, buffer, i);
      _held += take;
      i += take;
      if (_held < 16) return;
      _stripe(_tailView, 0);
      _held = 0;
    }
    if (end - i >= 16) {
      final view = ByteData.sublistView(buffer);
      for (; end - i >= 16; i += 16) {
        _stripe(view, i);
      }
    }
    if (i < end) {
      _tail.setRange(0, end - i, buffer, i);
      _held = end - i;
    }
  }

  void _stripe(ByteData data, int at) {
    _v1 = _round(_v1, data.getUint32(at, Endian.little));
    _v2 = _round(_v2, data.getUint32(at + 4, Endian.little));
    _v3 = _round(_v3, data.getUint32(at + 8, Endian.little));
    _v4 = _round(_v4, data.getUint32(at + 12, Endian.little));
  }

  /// The 32-bit hash of the bytes added so far.
  int digest() {
    var h = _length >= 16
        ? (_rotl(_v1, 1) + _rotl(_v2, 7) + _rotl(_v3, 12) + _rotl(_v4, 18)) &
              _mask
        : (seed + _p5) & _mask;
    h = (h + _length) & _mask;
    var i = 0;
    for (; _held - i >= 4; i += 4) {
      h = (h + _tailView.getUint32(i, Endian.little) * _p3) & _mask;
      h = (_rotl(h, 17) * _p4) & _mask;
    }
    for (; i < _held; i++) {
      h = (h + _tail[i] * _p5) & _mask;
      h = (_rotl(h, 11) * _p1) & _mask;
    }
    h ^= h >> 15;
    h = (h * _p2) & _mask;
    h ^= h >> 13;
    h = (h * _p3) & _mask;
    h ^= h >> 16;
    return h;
  }
}
