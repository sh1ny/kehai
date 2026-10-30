// A hook that copies its stdin to stdout until end of input, then exits 0.
import 'dart:io';

Future<void> main() async {
  await stdout.addStream(stdin);
  await stdout.flush();
}
