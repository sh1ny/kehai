// A hook that never exits and ignores SIGTERM. When argv[0] is given, it
// records its pid there first. Only SIGKILL (or a tree kill on Windows) ends it.
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) {});
  }
  if (args.isNotEmpty) {
    final tmp = File('${args.first}.tmp')..writeAsStringSync('$pid\n');
    tmp.renameSync(args.first);
  }
  // Keep the isolate alive until the process is killed.
  Timer.periodic(const Duration(hours: 1), (_) {});
  await Completer<void>().future;
}
