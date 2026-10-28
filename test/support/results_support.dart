import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/src/results/descriptor.dart';
import 'package:path/path.dart' as p;

/// The handle used by most result tests.
const testHandle = 'r/7f3a9c1b2d4e';

/// A stored result file and its descriptor.
typedef StoredResult = ({File file, ResultDescriptor descriptor});

/// Counts lines in [bytes] by the design definition: `\n`-terminated
/// segments plus a final non-empty unterminated one.
int countLines(List<int> bytes) {
  var n = 0;
  for (final b in bytes) {
    if (b == 0x0a) n++;
  }
  if (bytes.isNotEmpty && bytes.last != 0x0a) n++;
  return n;
}

/// Writes [bytes] to `<dir>/<name>` and describes them.
StoredResult storeBytes(
  Directory dir,
  List<int> bytes, {
  String name = 'result.bin',
  String handle = testHandle,
}) {
  final file = File(p.join(dir.path, name))..writeAsBytesSync(bytes);
  return (
    file: file,
    descriptor: ResultDescriptor(
      handle: handle,
      sha256: sha256.convert(bytes).toString(),
      bytes: bytes.length,
      lines: countLines(bytes),
    ),
  );
}

/// Writes [lines], each `\n`-terminated, as a stored result.
StoredResult storeLines(
  Directory dir,
  Iterable<String> lines, {
  String name = 'result.bin',
  String handle = testHandle,
}) => storeBytes(
  dir,
  utf8.encode(lines.map((l) => '$l\n').join()),
  name: name,
  handle: handle,
);
