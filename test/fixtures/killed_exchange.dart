// The killed-engine fixture of the loop and rpc resume tests.
//
// usage: killed_exchange.dart <sessions dir> <workspace>
//
// Creates a session under <sessions dir> for <workspace>, submits request
// `r9` against a provider that streams `par` and then never answers, and
// prints `READY <pid> <session dir>` once the delta was seen, so the exchange
// and its step are `running` on disk. Then it waits until it is killed.
import 'dart:async';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;

import '../support/fake_provider.dart';

Future<void> main(List<String> args) async {
  // Keep the isolate alive until the parent kills the process.
  Timer.periodic(const Duration(hours: 1), (_) {});
  final workspace = Directory(args[1]);
  final writer = await SessionWriter.create(Directory(args[0]));
  await writer.apply(
    JournalRecord(
      turn: writer.currentTurn,
      path: 'meta/workspace',
      op: Op.set,
      value: p.canonicalize(realPath(workspace.path)!),
    ),
  );
  final runtime = await ToolRuntime.attach(
    writer,
    ResultStore(writer.sessionDir),
    workspace: workspace,
    gate: const AllowAllStage(),
  );
  final driver = ExchangeDriver(
    writer: writer,
    runtime: runtime,
    provider: FakeProvider((request, cancel, call) async* {
      yield const TextDelta('par');
      await Completer<void>().future;
    }),
    model: 'gpt-fake',
  );
  driver.deltas.listen((_) {
    stdout.writeln('READY $pid ${writer.sessionDir.path}');
    stdout.flush();
  });
  await driver.submit(id: 'r9', text: 'hello', turn: writer.currentTurn);
  await Completer<void>().future;
}
