// A hook that fails at once: prints argv[1] (if any) to stderr and exits with
// the code in argv[0] (default 1). Exit 2 is the deny signal.
import 'dart:io';

Future<void> main(List<String> args) async {
  final code = args.isEmpty ? 1 : int.parse(args.first);
  if (args.length > 1) stderr.write(args[1]);
  await stderr.flush();
  exit(code);
}
