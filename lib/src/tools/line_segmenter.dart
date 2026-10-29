/// Splits a byte stream into lines, whatever the chunking (design D4).
///
/// The one definition of a line shared by the block hasher and the `read`
/// renderer, so the anchor a line carries is computed over the same lines the
/// renderer shows. A line ends at LF, CRLF or a lone CR. A final newline does
/// not add an empty line, and a UTF-8 BOM at byte 0 of the stream is skipped.
library;

import 'dart:typed_data';

const int _lf = 0x0a;
const int _cr = 0x0d;
const List<int> _bom = [0xEF, 0xBB, 0xBF];

/// Receives the pieces of the lines a [LineSegmenter] finds.
abstract interface class LineSink {
  /// A run of line content, `buffer[start, end)`; a line may arrive in many
  /// runs. It never holds a line terminator.
  void content(Uint8List buffer, int start, int end);

  /// The current line ended, at a terminator or at the end of the input.
  void lineEnd();

  /// Whether the segmenter should return to its caller now. It is checked
  /// after every [lineEnd].
  bool get stop;
}

/// Splits chunks into lines for a [LineSink], keeping what it needs between
/// chunks: a CR waiting for its LF, a partly matched BOM, and the line ending
/// counts.
final class LineSegmenter {
  /// Creates a segmenter for [sink].
  ///
  /// With [afterCr] the first byte is the LF of a CRLF whose CR ended the
  /// previous block. With [skipBom] a BOM at the start of the stream is
  /// dropped.
  LineSegmenter(this.sink, {this._afterCr = false, bool skipBom = true})
    : _bomDone = !skipBom;

  /// The sink that receives the lines.
  final LineSink sink;

  bool _afterCr;
  bool _bomDone;
  int _bomMatched = 0;
  bool _lineOpen = false;

  /// Lines ended by a lone LF so far.
  int lf = 0;

  /// Lines ended by CRLF so far.
  int crlf = 0;

  /// Lines ended by a lone CR so far.
  int cr = 0;

  /// Whether the next byte continues a CRLF split across blocks or chunks.
  bool get afterCr => _afterCr;

  /// Feeds `buffer[start, end)` and returns the index where it stopped.
  ///
  /// It stops at `end`, or right after a line terminator when `sink.stop` is
  /// set. A byte of a terminator that was cut off carries over to the next
  /// call.
  int feed(Uint8List buffer, int start, int end) {
    var i = start;
    if (!_bomDone) {
      while (i < end && !_bomDone) {
        if (buffer[i] == _bom[_bomMatched]) {
          i++;
          if (++_bomMatched == _bom.length) {
            _bomMatched = 0;
            _bomDone = true;
          }
        } else {
          _flushBom();
        }
      }
    }
    while (i < end) {
      if (_afterCr) {
        _afterCr = false;
        if (buffer[i] == _lf) {
          cr--;
          crlf++;
          i++;
          continue;
        }
      }
      var j = i;
      while (j < end && buffer[j] != _lf && buffer[j] != _cr) {
        j++;
      }
      if (j > i) {
        _lineOpen = true;
        sink.content(buffer, i, j);
      }
      if (j == end) return end;
      if (buffer[j] == _cr) {
        _afterCr = true;
        cr++;
      } else {
        lf++;
      }
      _lineOpen = false;
      i = j + 1;
      sink.lineEnd();
      if (sink.stop) return i;
    }
    return i;
  }

  /// Ends the stream: a partly matched BOM is content after all, and an open
  /// last line without a terminator ends here.
  void finish() {
    if (!_bomDone) _flushBom();
    if (_lineOpen) {
      _lineOpen = false;
      sink.lineEnd();
    }
  }

  void _flushBom() {
    _bomDone = true;
    if (_bomMatched > 0) {
      _lineOpen = true;
      sink.content(Uint8List.fromList(_bom), 0, _bomMatched);
      _bomMatched = 0;
    }
  }
}
