/// The streaming block hasher behind the anchors of `read` and `edit`
/// (design D4, ADR 0010 "Block-anchor contract").
///
/// A block is 16 lines. Its anchor hash is xxHash32, seed 0, of the block's
/// lines with trailing spaces and tabs removed, joined with `\n`, keeping the
/// low 16 bits. The hasher gets the bytes in chunks of any size and holds two
/// fixed-size hash states, so its memory does not depend on line length.
library;

import 'dart:typed_data';

import 'line_segmenter.dart';
import 'xxhash32.dart';

/// Lines per block.
const int blockLines = 16;

/// Formats the low 16 bits of [hash] as 4 uppercase hex digits.
String anchorHex(int hash) =>
    (hash & 0xFFFF).toRadixString(16).toUpperCase().padLeft(4, '0');

/// Hashes the blocks of a stream, one block at a time.
///
/// Trailing whitespace is trimmed in a stream with two states. `committed`
/// holds the block's bytes up to the last non-blank one. A run of spaces and
/// tabs goes into `speculative`, a copy of `committed`. If content follows,
/// `speculative` becomes `committed`, which keeps the exact order of the
/// run's spaces and tabs; at a line end it is dropped, which trims the run.
final class BlockHasher implements LineSink {
  /// Creates a hasher.
  ///
  /// With [hashing] false it only splits and counts lines, which is how
  /// `read` skips to a window and counts the rest of the file. With
  /// [stopAtBlock] false it does not hand control back at block ends.
  /// [afterCr] and [skipBom] are as for [LineSegmenter].
  BlockHasher({
    this.hashing = true,
    this.stopAtBlock = true,
    bool afterCr = false,
    bool skipBom = true,
  }) {
    segmenter = LineSegmenter(this, afterCr: afterCr, skipBom: skipBom);
  }

  /// Whether block hashes are computed.
  bool hashing;

  /// Whether [feed] returns at the end of each block.
  bool stopAtBlock;

  /// The line splitter, which also holds the line ending counts.
  late final LineSegmenter segmenter;

  final XxHash32 _committed = XxHash32();
  final XxHash32 _speculative = XxHash32();
  bool _hasSpeculative = false;
  bool _separatorPending = false;
  int _inBlock = 0;
  int _total = 0;

  /// Lines of the current block so far.
  int get linesInBlock => _inBlock;

  /// Lines seen in total.
  int get totalLines => _total;

  /// Whether the current block holds all [blockLines] lines.
  bool get blockDone => _inBlock >= blockLines;

  @override
  bool get stop => stopAtBlock && blockDone;

  /// Feeds `buffer[start, end)` and returns the index where it stopped; see
  /// [LineSegmenter.feed].
  int feed(Uint8List buffer, int start, int end) =>
      segmenter.feed(buffer, start, end);

  /// Ends the input, which closes an open last line.
  void finishInput() => segmenter.finish();

  /// The anchor hash of the current block; it starts the next block.
  String takeHash() {
    final hash = hashing ? anchorHex(_committed.digest()) : '';
    startBlock();
    return hash;
  }

  /// Starts a new block without producing a hash.
  void startBlock() {
    _committed.reset();
    _hasSpeculative = false;
    _separatorPending = false;
    _inBlock = 0;
  }

  void _separator() {
    if (_separatorPending) {
      _separatorPending = false;
      _committed.addByte(0x0a);
    }
  }

  @override
  void content(Uint8List buffer, int start, int end) {
    if (!hashing) return;
    _separator();
    var i = start;
    while (i < end) {
      final byte = buffer[i];
      if (byte == 0x20 || byte == 0x09) {
        if (!_hasSpeculative) {
          _speculative.copyFrom(_committed);
          _hasSpeculative = true;
        }
        _speculative.addByte(byte);
        i++;
      } else {
        var j = i + 1;
        while (j < end && buffer[j] != 0x20 && buffer[j] != 0x09) {
          j++;
        }
        if (_hasSpeculative) {
          _committed.copyFrom(_speculative);
          _hasSpeculative = false;
        }
        _committed.add(buffer, i, j);
        i = j;
      }
    }
  }

  @override
  void lineEnd() {
    if (hashing) {
      _separator();
      _hasSpeculative = false;
    }
    _total++;
    _inBlock++;
    if (hashing && _inBlock < blockLines) _separatorPending = true;
  }
}

/// The anchor hash of every block of the input given as [chunks].
///
/// This is the whole-input form of [BlockHasher], used by tests and `edit`.
List<String> blockHashes(Iterable<List<int>> chunks) {
  final hasher = BlockHasher();
  final hashes = <String>[];
  for (final chunk in chunks) {
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    var at = 0;
    while (at < bytes.length) {
      at = hasher.feed(bytes, at, bytes.length);
      if (hasher.blockDone) hashes.add(hasher.takeHash());
    }
  }
  hasher.finishInput();
  if (hasher.linesInBlock > 0) hashes.add(hasher.takeHash());
  return hashes;
}
