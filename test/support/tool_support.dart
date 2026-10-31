import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kehai/kehai.dart';

/// A [ToolOutput] that records what a tool wrote.
///
/// With [keep] false it only counts, so a test can run a tool over gigabytes.
final class RecordingOutput implements ToolOutput {
  /// Creates an output; [keep] says whether the bytes are retained.
  RecordingOutput({this.keep = true});

  /// Whether the bytes are retained in [bytes].
  final bool keep;

  final BytesBuilder _bytes = BytesBuilder(copy: false);

  /// Bytes written in total.
  int total = 0;

  /// The largest single write.
  int maxChunk = 0;

  /// The number of writes.
  int writes = 0;

  /// Newline bytes seen, when [countNewlines] is on.
  int newlines = 0;

  /// `#` bytes seen, when [countNewlines] is on.
  int hashes = 0;

  /// Whether to count `\n` and `#` bytes in every chunk.
  bool countNewlines = false;

  /// The first bytes written, up to 64.
  final List<int> head = [];

  /// The last byte written.
  int last = -1;

  /// Called with every chunk, when set.
  void Function(List<int> chunk)? onChunk;

  @override
  bool get isClosed => false;

  /// Everything written, when [keep] is on.
  Uint8List get bytes => _bytes.toBytes();

  /// Everything written as text, when [keep] is on.
  String get text => utf8.decode(bytes);

  /// The written lines, when [keep] is on.
  List<String> get lines {
    final all = text;
    if (all.isEmpty) return const [];
    return (all.endsWith('\n') ? all.substring(0, all.length - 1) : all).split(
      '\n',
    );
  }

  @override
  Future<void> write(List<int> data) async {
    if (data.isEmpty) return;
    total += data.length;
    writes++;
    if (data.length > maxChunk) maxChunk = data.length;
    if (head.length < 64) head.addAll(data.take(64 - head.length));
    last = data.last;
    onChunk?.call(data);
    if (keep) _bytes.add(Uint8List.fromList(data));
    if (countNewlines) {
      for (final b in data) {
        if (b == 0x0a) newlines++;
        if (b == 0x23) hashes++;
      }
    }
  }

  @override
  Future<void> writeText(String text) => write(utf8.encode(text));
}

/// A context for running a tool directly.
ToolContext toolContext(
  Directory workspace,
  ToolOutput output, {
  Directory? kehaiHome,
  CancelToken? cancel,
  Map<String, Object?>? permission,
}) => ToolContext(
  callKey: 'c-test',
  callId: 'test',
  output: output,
  cancel: cancel ?? CancelToken(),
  workspace: workspace,
  config: const UserConfig(),
  kehaiHome: kehaiHome,
  permission: permission,
);

/// A [ReadSource] over a real file that counts what is read.
final class CountingSource implements ReadSource {
  CountingSource._(this._file, this.stats);

  final RandomAccessFile _file;

  /// The shared counters.
  final ReadStats stats;

  /// Opens [file] and counts into [stats].
  static Future<ReadSource> open(File file, ReadStats stats) async =>
      CountingSource._(await file.open(), stats);

  @override
  Future<int> readAt(int position, Uint8List buffer) async {
    await _file.setPosition(position);
    final n = await _file.readInto(buffer);
    stats.reads++;
    stats.bytes += n;
    if (buffer.length > stats.maxRequest) stats.maxRequest = buffer.length;
    return n;
  }

  @override
  Future<void> close() => _file.close();
}

/// Counters of a [CountingSource].
final class ReadStats {
  /// The number of reads.
  int reads = 0;

  /// The bytes read.
  int bytes = 0;

  /// The largest buffer handed to a read.
  int maxRequest = 0;

  /// A [ReadSeams] that counts into this object.
  ReadSeams get seams =>
      ReadSeams(open: (file) => CountingSource.open(file, this));
}

/// Writes [unit] repeated [times] to [file], a megabyte at a time.
void writeRepeated(File file, Uint8List unit, int times) {
  final raf = file.openSync(mode: FileMode.write);
  try {
    for (var i = 0; i < times; i++) {
      raf.writeFromSync(unit);
    }
  } finally {
    raf.closeSync();
  }
}
