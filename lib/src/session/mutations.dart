/// One unfinished filesystem mutation supplied by its engine.
///
/// `runId` is the original call attempt; `callPath` locates its call node.
/// A null `temporary` represents absent legacy provenance.
typedef MutationTarget = ({
  String runId,
  String callPath,
  String target,
  String? temporary,
  String session,
});

/// Reads the temporary path while preserving absent legacy provenance.
///
/// Throws [StateError] for a present empty or non-string field.
String? mutationTemporary(Map<String, Object?> record) {
  if (!record.containsKey('temporary')) return null;
  final temporary = record['temporary'];
  if (temporary is! String || temporary.isEmpty) {
    throw StateError('Invalid mutation temporary path.');
  }
  return temporary;
}

/// The engine's capture and mutation-finish sequence allocator.
final class MutationSequence {
  MutationSequence(this._high);

  int _high;

  /// The highest sequence reserved in this engine.
  int get high => _high;

  /// Reserves a number that cannot be reused during this engine run.
  int reserve() => ++_high;

  /// Preserves a newer persisted high-water mark.
  void raise(int value) {
    if (value > _high) _high = value;
  }
}

Map<String, Object?> _map(Object? value) {
  if (value == null) return const {};
  if (value is Map<String, Object?>) return value;
  throw StateError('Invalid mutation metadata map.');
}

int _counter(Object? value) {
  if (value == null) return 0;
  if (value is int && value >= 0) return value;
  throw StateError('Invalid mutation sequence counter.');
}

Map<String, Object?> _ownedRecord(
  Map<String, Object?> records,
  MutationTarget mutation,
) {
  final temporary = mutation.temporary;
  if (temporary != null && temporary.isEmpty) {
    throw StateError('Invalid mutation temporary path.');
  }
  final existing = _map(records[mutation.runId]);
  if (existing.isNotEmpty &&
      (existing['foreign'] == true ||
          existing['session'] != mutation.session ||
          existing['target'] != mutation.target ||
          mutationTemporary(existing) != temporary)) {
    throw StateError('Mutation run ownership or target changed.');
  }
  return existing;
}

/// Builds the metadata merge for a removed mutation and bounded history.
Map<String, Object?> orphanMutationMerge(
  Map<String, Object?> meta,
  MutationTarget mutation, {
  int? finishedSeq,
}) {
  final records = Map<String, Object?>.of(_map(meta['orphanedMutations']));
  final existing = _ownedRecord(records, mutation);
  final record = <String, Object?>{
    ...existing,
    'target': mutation.target,
    'temporary': ?mutation.temporary,
    'session': mutation.session,
  };
  if (finishedSeq != null && record['finishedSeq'] is! int) {
    record['finishedSeq'] = finishedSeq;
  }
  records[mutation.runId] = record;
  final vcs = Map<String, Object?>.of(_map(meta['vcs']));
  var high = _counter(vcs['seqHigh']);
  var floor = _counter(vcs['attributionFloor']);
  if (finishedSeq != null && finishedSeq > high) high = finishedSeq;
  while (true) {
    var finishedCount = 0;
    String? oldestKey;
    int? oldestSeq;
    for (final MapEntry(:key, :value) in records.entries) {
      final item = _map(value);
      final seq = item['finishedSeq'];
      if (item['foreign'] == true || seq is! int) continue;
      finishedCount++;
      if (oldestSeq == null || seq < oldestSeq) {
        oldestSeq = seq;
        oldestKey = key;
      }
    }
    if (finishedCount <= 64) break;
    records.remove(oldestKey);
    if (oldestSeq! > floor) floor = oldestSeq;
  }
  vcs['seqHigh'] = high;
  if (floor > 0 || vcs.containsKey('attributionFloor')) {
    vcs['attributionFloor'] = floor;
  }
  return {'orphanedMutations': records, 'vcs': vcs};
}

/// Preserves newly lost live targets without rewriting an existing record.
///
/// The caller appends this merge before committing the cut in the same queue
/// operation. An empty result means preservation is already durable.
Map<String, Object?> preserveMutationTargets(
  Map<String, Object?> meta,
  Iterable<MutationTarget> targets,
) {
  final original = _map(meta['orphanedMutations']);
  Map<String, Object?>? updated;
  for (final mutation in targets) {
    final existing = _ownedRecord(updated ?? original, mutation);
    if (existing.isNotEmpty) continue;
    updated ??= Map<String, Object?>.of(original);
    updated[mutation.runId] = {
      'target': mutation.target,
      'temporary': ?mutation.temporary,
      'session': mutation.session,
    };
  }
  return updated == null ? const {} : {'orphanedMutations': updated};
}

/// Derives the unfinished edit/write call keys from a frozen tree.
Set<String> openMutationCallKeys(Map<String, Object?> tree) {
  final calls = _map(_map(tree['body'])['calls']);
  return {
    for (final MapEntry(:key, :value) in calls.entries)
      if (value is Map<String, Object?> &&
          (value['tool'] == 'edit' || value['tool'] == 'write') &&
          value['target'] is String &&
          value['quiesced'] != true)
        key,
  };
}

/// Adds bounded foreign uncertainty using the parent's current tree and runs.
///
/// The caller invokes this inside the parent's serialized fork decision.
Map<String, Object?> forkMutationMeta(
  Map<String, Object?> parentMeta,
  Map<String, Object?> currentTree,
  Iterable<MutationTarget> live,
) {
  final inherited = _map(parentMeta['orphanedMutations']);
  final retained = <String, Object?>{};
  final foreign = <String, Object?>{};
  var overflow = _map(parentMeta['vcs'])['foreignOverflow'] == true;
  void keep(String id, String target, String session, String? temporary) {
    if (temporary != null && temporary.isEmpty) {
      throw StateError('Invalid mutation temporary path.');
    }
    if (foreign.containsKey(id)) return;
    if (foreign.length == 16) {
      overflow = true;
      return;
    }
    foreign[id] = {
      'target': target,
      'temporary': ?temporary,
      'session': session,
      'foreign': true,
    };
  }

  // Replace inherited unfinished records rather than duplicating them at each
  // generation. Finished history remains subject to the existing 64 bound.
  for (final MapEntry(:key, :value) in inherited.entries) {
    final record = _map(value);
    if (record case {
      'target': final String target,
      'session': final String session,
    }) {
      final temporary = mutationTemporary(record);
      if (record['foreign'] == true || record['finishedSeq'] is! int) {
        keep(key, target, session, temporary);
      } else {
        retained[key] = record;
      }
    } else {
      throw StateError('Invalid orphaned mutation record.');
    }
  }
  final parentSession = parentMeta['session'];
  final body = currentTree['body'];
  final rawCalls = body is Map<String, Object?> ? body['calls'] : null;
  final calls = rawCalls is Map<String, Object?>
      ? rawCalls
      : const <String, Object?>{};
  if (parentSession is String) {
    for (final MapEntry(:key, :value) in calls.entries) {
      if (value is! Map<String, Object?> ||
          (value['tool'] != 'edit' && value['tool'] != 'write') ||
          value['quiesced'] == true) {
        continue;
      }
      final target = value['target'];
      final attempt = value['attempt'];
      if (target is String) {
        keep(
          attempt is String ? attempt : 'legacy:$key',
          target,
          parentSession,
          mutationTemporary(value),
        );
      }
    }
  }
  for (final mutation in live) {
    keep(mutation.runId, mutation.target, mutation.session, mutation.temporary);
  }
  if (inherited.isEmpty && foreign.isEmpty && !overflow) return parentMeta;
  final vcs = _map(parentMeta['vcs']);
  return {
    ...parentMeta,
    'orphanedMutations': {...retained, ...foreign},
    if (overflow) 'vcs': {...vcs, 'foreignOverflow': true},
  };
}
