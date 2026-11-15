import 'dart:async';

import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('expected ready and release paths');
    exitCode = 2;
    return;
  }

  final ready = File(arguments[0]);
  final release = File(arguments[1]);
  ready.writeAsStringSync('blocked');

  final releaseSignal = Completer<void>();
  final watcher = release.parent
      .watch(events: FileSystemEvent.create | FileSystemEvent.modify)
      .listen((_) {
        if (release.existsSync() && !releaseSignal.isCompleted) {
          releaseSignal.complete();
        }
      });
  if (!release.existsSync()) await releaseSignal.future;
  await watcher.cancel();

  await stdout.addStream(stdin);
}
