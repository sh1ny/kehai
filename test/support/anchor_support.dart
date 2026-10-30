import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kehai/src/tools/block_hash.dart';
import 'package:kehai/src/tools/xxhash32.dart';

/// The recorded reference values in `test/fixtures/anchors/reference.json`.
Map<String, Object?> anchorReference() =>
    jsonDecode(File('test/fixtures/anchors/reference.json').readAsStringSync())
        as Map<String, Object?>;

/// Splits [bytes] into chunks of [size] bytes (the last one may be shorter).
Iterable<Uint8List> chunked(List<int> bytes, int size) sync* {
  final all = Uint8List.fromList(bytes);
  for (var i = 0; i < all.length; i += size) {
    final end = i + size > all.length ? all.length : i + size;
    yield Uint8List.sublistView(all, i, end);
  }
}

bool _blank(int byte) => byte == 0x20 || byte == 0x09;

/// The anchor hashes of [bytes], each block's text built whole in memory per
/// the spec definition: leading BOM removed, CRLF and CR as line ends,
/// trailing spaces, tabs and CRs stripped, lines joined with `\n`.
List<String> definitionHashes(List<int> bytes) {
  var start = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    start = 3;
  }
  final lines = <List<int>>[];
  var line = <int>[];
  var open = false;
  for (var i = start; i < bytes.length; i++) {
    final b = bytes[i];
    if (b == 0x0a || b == 0x0d) {
      if (b == 0x0d && i + 1 < bytes.length && bytes[i + 1] == 0x0a) i++;
      lines.add(line);
      line = <int>[];
      open = false;
    } else {
      line.add(b);
      open = true;
    }
  }
  if (open) lines.add(line);
  final out = <String>[];
  for (var b = 0; b < lines.length; b += blockLines) {
    final text = <int>[];
    for (var i = b; i < b + blockLines && i < lines.length; i++) {
      var end = lines[i].length;
      while (end > 0 && _blank(lines[i][end - 1])) {
        end--;
      }
      if (i > b) text.add(0x0a);
      text.addAll(lines[i].sublist(0, end));
    }
    out.add(anchorHex(xxHash32(text)));
  }
  return out;
}
