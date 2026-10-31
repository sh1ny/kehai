/// The `read` tool: a file as numbered lines with block anchors (design D4).
///
/// Every block of 16 lines is read twice: a hash pass computes its anchor,
/// then a render pass streams the same bytes back out with the anchor on the
/// block's first line. Only one block's hash, a 64 KiB read buffer and a
/// 160 KiB write buffer are held, whatever the line lengths, the line count
/// or `limit`.
library;

import 'dart:io';
import 'dart:typed_data';

import '../results/composer.dart';
import '../results/line_scanner.dart' show scanBufferBytes;
import 'block_hash.dart';
import 'file_access.dart';
import 'line_segmenter.dart';
import 'tool.dart';

/// The size past which `read` wants a `limit`.
const int maxUnlimitedReadBytes = 64 * 1024 * 1024;

/// How much of the start of a file is searched for a NUL byte.
const int _sniffBytes = 8 * 1024;

/// The write buffer fills to this before a render pass hands it on.
const int _flushBytes = 32 * 1024;

/// Positional reads of the file being read.
abstract interface class ReadSource {
  /// Reads up to `buffer.length` bytes at [position] and returns how many
  /// were read; 0 means the end of the file.
  Future<int> readAt(int position, Uint8List buffer);

  /// Closes the file.
  Future<void> close();
}

/// Opens [file] for reading.
typedef ReadSourceOpener = Future<ReadSource> Function(File file);

/// Test seams of [ReadTool].
final class ReadSeams {
  /// Creates seams; every callback is optional.
  const ReadSeams({this.open, this.afterHashPass});

  /// Opens the file, so a test can count what is read.
  final ReadSourceOpener? open;

  /// Runs after the hash pass of the block numbered [block] (from 0) and
  /// before its render pass.
  final Future<void> Function(int block)? afterHashPass;
}

/// Reads a text file as numbered lines with block anchors.
final class ReadTool implements Tool {
  /// Creates the tool.
  const ReadTool({this.seams = const ReadSeams()});

  /// The test seams.
  final ReadSeams seams;

  @override
  Future<ToolOutcome> run(ToolContext context, Map<String, Object?> input) {
    final path = input['path']! as String;
    final absolute = absolutePath(context.workspace, path);
    final denied =
        credentialDenial(context, absolute) ?? movedDenial(context, absolute);
    if (denied != null) return Future.value(denied);
    return switch (FileSystemEntity.typeSync(absolute)) {
      FileSystemEntityType.notFound => Future.value(
        failure('no such file $path'),
      ),
      FileSystemEntityType.directory => Future.value(
        failure('$path is a directory; use ls'),
      ),
      _ => _read(
        context,
        path,
        File(absolute),
        input['offset'] as int?,
        input['limit'] as int?,
      ),
    };
  }

  Future<ToolOutcome> _read(
    ToolContext context,
    String path,
    File file,
    int? offset,
    int? limit,
  ) async {
    final before = await file.stat();
    final source = await (seams.open ?? _openFile)(file);
    try {
      return await _Pass(
        context,
        seams,
        path,
        file,
        source,
        before,
      ).run(offset, limit);
    } finally {
      await source.close();
    }
  }
}

final class _FileSource implements ReadSource {
  _FileSource(this._file);

  final RandomAccessFile _file;

  @override
  Future<int> readAt(int position, Uint8List buffer) async {
    await _file.setPosition(position);
    return _file.readInto(buffer);
  }

  @override
  Future<void> close() => _file.close();
}

Future<ReadSource> _openFile(File file) async => _FileSource(await file.open());

/// One read of one file.
final class _Pass {
  _Pass(
    this.context,
    this.seams,
    this.path,
    this.file,
    this.source,
    this.before,
  );

  final ToolContext context;
  final ReadSeams seams;
  final String path;
  final File file;
  final ReadSource source;
  final FileStat before;

  final Uint8List _data = Uint8List(scanBufferBytes);
  int _dataStart = 0;
  int _dataLength = 0;

  /// Whether the file was read from disk since it was last compared with
  /// [before].
  bool _unchecked = false;

  int get _size => before.size;

  /// Makes `_data` hold the bytes at [position] when the file has any.
  Future<void> _fill(int position) async {
    if (position >= _dataStart && position < _dataStart + _dataLength) return;
    _dataStart = position;
    _dataLength = position >= _size ? 0 : await source.readAt(position, _data);
    _unchecked = true;
  }

  /// Whether the file's size or modification time differ from [before].
  Future<bool> _changed() async {
    _unchecked = false;
    final now = await file.stat();
    return now.size != before.size || now.modified != before.modified;
  }

  static const _changedMessage = 'file changed during read; read it again';

  static const _stopped = ToolOutcome(
    status: ResultStatus.error,
    summary: 'read stopped: output closed',
    complete: false,
  );

  Future<ToolOutcome> run(int? offset, int? limit) async {
    await _fill(0);
    final sniff = _dataLength < _sniffBytes ? _dataLength : _sniffBytes;
    for (var i = 0; i < sniff; i++) {
      if (_data[i] == 0) {
        return failure('binary file $path ($_size bytes)');
      }
    }
    if (_size > maxUnlimitedReadBytes && limit == null) {
      return failure(
        'file is ${mebibytes(_size)}; read it with offset and limit',
      );
    }

    final hasher = BlockHasher(hashing: false);
    var position = 0;
    var eof = false;
    // Set when the call is cancelled or its output closed during a pass that
    // renders nothing; the read then unwinds so the source closes promptly.
    var stopped = false;

    /// Feeds [segmenter] from `position` until [done] or the end of the
    /// file; [flush] runs after each feed.
    Future<void> advance(
      LineSegmenter segmenter,
      Future<void> Function() flush,
      bool Function() done,
    ) async {
      while (!done()) {
        if (context.cancel.isCancelled || context.output.isClosed) {
          stopped = true;
          return;
        }
        if (position >= _size) {
          segmenter.finish();
          eof = true;
          return;
        }
        await _fill(position);
        if (_dataLength == 0) {
          segmenter.finish();
          eof = true;
          return;
        }
        final at = position - _dataStart;
        final fed = segmenter.feed(_data, at, _dataLength);
        position += fed - at;
        await flush();
      }
    }

    Future<void> noFlush() async {}

    // Skip the blocks before the one holding `offset`, counting only.
    final first = offset == null ? 0 : (offset - 1) ~/ blockLines;
    for (var block = 0; block < first && !eof; block++) {
      await advance(hasher.segmenter, noFlush, () => hasher.blockDone);
      if (stopped) return _stopped;
      hasher.startBlock();
    }
    var startLine = first * blockLines + 1;
    if (eof) {
      return failure('offset $offset beyond last line ${hasher.totalLines}');
    }

    hasher.hashing = true;
    final lastWanted = limit == null ? null : (offset ?? 1) + limit - 1;
    final renderer = _Renderer(context.output);
    var block = first;
    while (true) {
      final blockPosition = position;
      final blockAfterCr = hasher.segmenter.afterCr;
      if (!eof) {
        await advance(hasher.segmenter, noFlush, () => hasher.blockDone);
        if (stopped) return _stopped;
      }
      final lines = hasher.linesInBlock;
      if (lines == 0) {
        if (block == first && offset != null) {
          return failure(
            'offset $offset beyond last line ${hasher.totalLines}',
          );
        }
        break;
      }
      if (block == first && offset != null && offset > startLine + lines - 1) {
        return failure(
          'offset $offset beyond last line ${startLine + lines - 1}',
        );
      }
      final anchor = hasher.takeHash();
      await seams.afterHashPass?.call(block);

      // Render pass: the same bytes again, with their numbers and the anchor.
      renderer.startBlock(startLine, anchor);
      final segmenter = LineSegmenter(
        renderer,
        afterCr: blockAfterCr,
        skipBom: blockPosition == 0,
      );
      final resume = position;
      position = blockPosition;
      while (!renderer.blockDone) {
        await _fill(position);
        if (_dataLength == 0) {
          segmenter.finish();
          break;
        }
        final at = position - _dataStart;
        final stopped = segmenter.feed(_data, at, _dataLength);
        position += stopped - at;
        if (renderer.pending >= _flushBytes) await renderer.flush();
        if (context.cancel.isCancelled || context.output.isClosed) {
          return _stopped;
        }
      }
      await renderer.flush();
      if (renderer.lines != lines) {
        return failure(_changedMessage);
      }
      position = resume;
      // Checking after every pass would cost a stat per 16 lines of a file of
      // empty lines; a pass served from the buffer read nothing new, and the
      // check at the end covers it.
      if (_unchecked && await _changed()) return failure(_changedMessage);

      startLine += lines;
      block++;
      if (eof || lines < blockLines) break;
      if (lastWanted != null && startLine > lastWanted) break;
    }

    // Count the rest of the file without hashing or rendering it.
    final shownEnd = startLine - 1;
    hasher
      ..hashing = false
      ..stopAtBlock = false;
    await advance(hasher.segmenter, noFlush, () => eof);
    if (stopped) return _stopped;
    if (await _changed()) return failure(_changedMessage);

    final total = hasher.totalLines;
    final shownStart = first * blockLines + 1;
    final ending = _dominantEnding(hasher.segmenter);
    final summary = total == 0
        ? '$path: 0 lines'
        : shownStart == 1 && shownEnd == total
        ? '$path: ${_count(total)}, $ending'
        : '$path: lines $shownStart–$shownEnd of $total, $ending';
    return ToolOutcome(summary: summary);
  }
}

String _count(int lines) => lines == 1 ? '1 line' : '$lines lines';

String _dominantEnding(LineSegmenter s) {
  if (s.lf == 0 && s.crlf == 0 && s.cr == 0) return 'no line ending';
  if (s.lf >= s.crlf && s.lf >= s.cr) return 'LF';
  return s.crlf >= s.cr ? 'CRLF' : 'CR';
}

/// Writes the lines of one block as `N:text` or `N#HASH:text`.
final class _Renderer implements LineSink {
  _Renderer(this._output);

  final ToolOutput _output;
  // A line piece is at most one read buffer; the buffer is flushed once it
  // holds _flushBytes, so this leaves room for the line that crosses it.
  final Uint8List _out = Uint8List(_flushBytes + scanBufferBytes + 64);
  int _length = 0;
  int _number = 0;
  String _anchor = '';
  int _inBlock = 0;
  bool _prefixed = false;

  /// Lines rendered in the current block.
  int get lines => _inBlock;

  /// Bytes waiting to be flushed.
  int get pending => _length;

  bool get blockDone => _inBlock >= blockLines;

  void startBlock(int firstLine, String anchor) {
    _number = firstLine;
    _anchor = anchor;
    _inBlock = 0;
    _prefixed = false;
  }

  Future<void> flush() async {
    if (_length == 0) return;
    final chunk = Uint8List.fromList(Uint8List.sublistView(_out, 0, _length));
    _length = 0;
    await _output.write(chunk);
  }

  @override
  bool get stop => blockDone || _length >= _flushBytes;

  void _prefix() {
    _prefixed = true;
    _putNumber(_number);
    if (_inBlock == 0) {
      _out[_length++] = 0x23;
      for (var i = 0; i < _anchor.length; i++) {
        _out[_length++] = _anchor.codeUnitAt(i);
      }
    }
    _out[_length++] = 0x3a;
  }

  void _putNumber(int n) {
    var digits = 1;
    for (var t = n; t >= 10; t ~/= 10) {
      digits++;
    }
    var at = _length + digits;
    _length = at;
    do {
      _out[--at] = 0x30 + n % 10;
      n ~/= 10;
    } while (n > 0);
  }

  @override
  void content(Uint8List buffer, int start, int end) {
    if (!_prefixed) _prefix();
    _out.setRange(_length, _length + end - start, buffer, start);
    _length += end - start;
  }

  @override
  void lineEnd() {
    if (!_prefixed) _prefix();
    _out[_length++] = 0x0a;
    _prefixed = false;
    _number++;
    _inBlock++;
  }
}
