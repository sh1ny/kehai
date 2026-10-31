/// A stand-in child engine that does nothing until its standard input ends.
library;

import 'dart:io';

Future<void> main() async {
  await stdin.drain<void>();
}
