part of 'vcs_collector.dart';

const Set<String> _gitCollectorCommands = {
  'rev-parse',
  'status',
  'add',
  'write-tree',
  'diff',
  'hash-object',
};

extension _GitCollector on _VcsCollectorEngine {
  Future<VcsCollection> _collectGit(
    _CollectionRun run, {
    required String executable,
    required String workspace,
    required String repository,
    required VcsCollection? previous,
    required int turn,
    required DateTime time,
    required int? captureSequence,
    required bool jobsLive,
  }) async {
    final baseEnvironment = gitEnvironment();
    final topLevelResult = await _gitCommand(
      run,
      executable: executable,
      cwd: workspace,
      command: 'rev-parse',
      arguments: const ['--show-toplevel'],
      environment: baseEnvironment,
    );
    _requireGitSuccess('git', topLevelResult);
    if (topLevelResult._stdoutTruncated) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: invalid git repository root',
      );
    }
    final topLevel = _oneGitLine(topLevelResult.stdout);
    if (topLevel.isEmpty) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: invalid git repository root',
      );
    }
    final repositoryRoot = p.normalize(p.absolute(topLevel));

    final statusResult = await _gitCommand(
      run,
      executable: executable,
      cwd: repositoryRoot,
      command: 'status',
      arguments: const [
        '--porcelain=v2',
        '--branch',
        '-z',
        '--untracked-files=all',
      ],
      environment: baseEnvironment,
    );
    _requireGitSuccess('git', statusResult, allowTruncated: true);
    final status = _parseGitStatus(statusResult);

    final indexResult = await _gitCommand(
      run,
      executable: executable,
      cwd: repositoryRoot,
      command: 'rev-parse',
      arguments: const ['--git-path', 'index'],
      environment: baseEnvironment,
    );
    _requireGitSuccess('git', indexResult);
    if (indexResult._stdoutTruncated) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: invalid git index path',
      );
    }
    final indexPath = _oneGitLine(indexResult.stdout);
    if (indexPath.isEmpty) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: invalid git index path',
      );
    }
    final userIndex = p.isAbsolute(indexPath)
        ? indexPath
        : p.join(repositoryRoot, indexPath);
    final privateIndex = await this.privateIndex(
      run,
      repository: repository,
      sourcePath: userIndex,
    );
    final privateEnvironment = gitEnvironment(privateIndex: privateIndex);

    final addResult = await _gitCommand(
      run,
      executable: executable,
      cwd: repositoryRoot,
      command: 'add',
      arguments: const ['-A'],
      environment: privateEnvironment,
    );
    _requireGitSuccess('git', addResult);

    final treeResult = await _gitCommand(
      run,
      executable: executable,
      cwd: repositoryRoot,
      command: 'write-tree',
      arguments: const [],
      environment: privateEnvironment,
    );
    _requireGitSuccess('git', treeResult);
    if (treeResult._stdoutTruncated) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: invalid git tree id',
      );
    }
    final tree = _oneGitLine(treeResult.stdout);
    if (tree.isEmpty) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: invalid git tree id',
      );
    }

    var comparisonBase = status.oid;
    var unborn = comparisonBase == '(initial)';
    if (unborn) {
      final emptyTreeResult = await _gitCommand(
        run,
        executable: executable,
        cwd: repositoryRoot,
        command: 'hash-object',
        arguments: const ['-w', '-t', 'tree', '--stdin'],
        environment: privateEnvironment,
      );
      _requireGitSuccess('git', emptyTreeResult);
      if (emptyTreeResult._stdoutTruncated) {
        throw const _CollectorFailure(
          SensoriumReason.failed,
          'failed: invalid empty tree id',
        );
      }
      comparisonBase = _oneGitLine(emptyTreeResult.stdout);
      if (comparisonBase.isEmpty) {
        throw const _CollectorFailure(
          SensoriumReason.failed,
          'failed: invalid empty tree id',
        );
      }
    }

    final pathsFuture = _gitCommand(
      run,
      executable: executable,
      cwd: repositoryRoot,
      command: 'diff',
      arguments: [
        '--name-status',
        '-z',
        '--no-renames',
        '--no-ext-diff',
        '--no-textconv',
        comparisonBase,
        tree,
      ],
      environment: privateEnvironment,
    );
    final priorBaseline = previous?.baseline;
    final backendChanged =
        priorBaseline != null && priorBaseline.backend != 'git';
    final Future<VcsProcessResult>? deltaFuture =
        priorBaseline == null || backendChanged
        ? null
        : _gitCommand(
            run,
            executable: executable,
            cwd: repositoryRoot,
            command: 'diff',
            arguments: [
              '--numstat',
              '-z',
              '--no-renames',
              '--no-ext-diff',
              '--no-textconv',
              priorBaseline.id,
              tree,
            ],
            environment: privateEnvironment,
          );
    final followups = await Future.wait<VcsProcessResult>([
      pathsFuture,
      ?deltaFuture,
    ]);
    final pathsResult = followups.first;
    _requireGitSuccess('git', pathsResult, allowTruncated: true);
    final summary = _parseGitNameStatus(pathsResult);
    final conflicts = status.conflicts;
    for (final path in conflicts) {
      summary.files.putIfAbsent(path, () => 'M');
    }

    var baselineLost = backendChanged;
    var deltas = <VcsDelta>[];
    var deltaPartial = false;
    if (deltaFuture != null) {
      final deltaResult = followups[1];
      if (deltaResult.exitCode != 0 && _looksLikeMissingBaseline(deltaResult)) {
        baselineLost = true;
      } else {
        _requireGitSuccess('git', deltaResult, allowTruncated: true);
        final parsed = _parseGitNumstat(deltaResult);
        deltas = parsed.deltas;
        deltaPartial = parsed.partial;
      }
    }

    final orderedPaths = summary.files.keys.toList(growable: false);
    final visiblePaths = orderedPaths
        .take(12)
        .map((path) => _clipUtf8(path, 64))
        .toList(growable: false);
    final visibleConflicts = conflicts
        .take(12)
        .map((path) => _clipUtf8(path, 64))
        .toList(growable: false);
    final branch = status.branch == '(detached)' || status.branch.isEmpty
        ? 'detached'
        : status.branch;
    final change = unborn ? '(no commits)' : null;
    final operation = unborn ? null : _shortObjectId(status.oid);
    final partial = status.partial || summary.partial || deltaPartial;
    final value = SensoriumVcs(
      branch: _clipUtf8(branch, 128),
      paths: visiblePaths,
      backend: 'git',
      change: change,
      operation: operation,
      modified: summary.modified,
      added: summary.added,
      deleted: summary.deleted,
      conflicts: visibleConflicts,
      partial: partial,
      totalPaths: orderedPaths.length,
      conflictCount: conflicts.length,
    );
    final baseline = this.baseline(
      'git',
      tree,
      turn,
      time,
      sequence: captureSequence,
      jobsLive: jobsLive,
    );
    final reason = baselineLost
        ? 'baseline lost'
        : priorBaseline == null
        ? 'no baseline'
        : null;
    return VcsCollection(
      observation: SensoriumAvailable(value),
      baseline: baseline,
      changes: deltas,
      deltaPartial: deltaPartial,
      reason: reason,
      baselineLost: baselineLost,
    );
  }

  Future<VcsProcessResult> _gitCommand(
    _CollectionRun run, {
    required String executable,
    required String cwd,
    required String command,
    required List<String> arguments,
    required Map<String, String> environment,
  }) {
    if (!_gitCollectorCommands.contains(command)) {
      throw StateError('Git command is outside the collector allowlist.');
    }
    return this.command(
      run,
      executable: executable,
      cwd: cwd,
      arguments: ['--no-pager', '-c', 'color.ui=false', command, ...arguments],
      environment: environment,
      tool: 'git',
    );
  }
}

final class _GitData {
  const _GitData(this.bytes, this.length, this.partial);

  final List<int> bytes;
  final int length;
  final bool partial;
}

final class _GitStatus {
  const _GitStatus({
    required this.branch,
    required this.oid,
    required this.conflicts,
    required this.partial,
  });

  final String branch;
  final String oid;
  final List<String> conflicts;
  final bool partial;
}

final class _GitSummary {
  const _GitSummary(this.files, this.partial);

  final Map<String, String> files;
  final bool partial;

  int get modified =>
      files.values.where((status) => status != 'A' && status != 'D').length;
  int get added => files.values.where((status) => status == 'A').length;
  int get deleted => files.values.where((status) => status == 'D').length;
}

final class _GitNumstat {
  const _GitNumstat(this.deltas, this.partial);

  final List<VcsDelta> deltas;
  final bool partial;
}

_GitData _gitData(VcsProcessResult result) {
  final length = result.stdout.length < _vcsOutputLimit
      ? result.stdout.length
      : _vcsOutputLimit;
  return _GitData(result.stdout, length, result._stdoutTruncated);
}

void _requireGitSuccess(
  String tool,
  VcsProcessResult result, {
  bool allowTruncated = false,
}) {
  if (result.exitCode == 0 || allowTruncated && result._stdoutTruncated) {
    return;
  }
  throw _CollectorFailure(
    SensoriumReason.failed,
    _processFailure(tool, result),
  );
}

String _oneGitLine(List<int> bytes) {
  var end = bytes.length;
  while (end > 0 && (bytes[end - 1] == 10 || bytes[end - 1] == 13)) {
    end--;
  }
  return _decodeBytes(bytes, 0, end);
}

String _shortObjectId(String id) => id.length <= 7 ? id : id.substring(0, 7);

_GitStatus _parseGitStatus(VcsProcessResult result) {
  final data = _gitData(result);
  String? branch;
  String? oid;
  final conflicts = <String>[];
  final conflictSet = <String>{};
  var entries = 0;
  var partial = data.partial;
  var cursor = 0;
  while (cursor < data.length) {
    final end = _nextNul(data.bytes, cursor, data.length);
    if (end < 0) {
      if (partial) break;
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: malformed git status',
      );
    }
    final start = cursor;
    cursor = end + 1;
    if (start == end) continue;
    if (_bytePrefix(data.bytes, start, end, '# branch.oid ')) {
      oid = _decodeBytes(data.bytes, start + 13, end);
      continue;
    }
    if (_bytePrefix(data.bytes, start, end, '# branch.head ')) {
      branch = _decodeBytes(data.bytes, start + 14, end);
      continue;
    }
    if (data.bytes[start] == 35) continue;
    if (entries == _vcsEntryLimit) {
      partial = true;
      break;
    }
    entries++;
    final kind = data.bytes[start];
    if (kind == 63) {
      if (end - start <= 2) {
        throw const _CollectorFailure(
          SensoriumReason.failed,
          'failed: malformed git status path',
        );
      }
      continue;
    }
    final spaces = switch (kind) {
      49 => 8,
      50 => 9,
      117 => 10,
      _ => 0,
    };
    final pathStart = _afterSpaces(data.bytes, start, end, spaces);
    if (spaces == 0 || pathStart < 0 || pathStart == end) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: malformed git status row',
      );
    }
    if (kind == 117) {
      final path = _repositoryPath(_decodeBytes(data.bytes, pathStart, end));
      if (conflictSet.add(path)) conflicts.add(path);
    }
    if (kind == 50) {
      final originalEnd = _nextNul(data.bytes, cursor, data.length);
      if (originalEnd < 0) {
        if (partial) break;
        throw const _CollectorFailure(
          SensoriumReason.failed,
          'failed: malformed git rename row',
        );
      }
      cursor = originalEnd + 1;
    }
  }
  if (data.partial) partial = true;
  if (branch == null || oid == null || branch.isEmpty || oid.isEmpty) {
    throw const _CollectorFailure(
      SensoriumReason.failed,
      'failed: missing git status identity',
    );
  }
  return _GitStatus(
    branch: branch,
    oid: oid,
    conflicts: conflicts,
    partial: partial,
  );
}

_GitSummary _parseGitNameStatus(VcsProcessResult result) {
  final data = _gitData(result);
  final files = <String, String>{};
  var partial = data.partial;
  var cursor = 0;
  var entries = 0;
  while (cursor < data.length) {
    final statusEnd = _nextNul(data.bytes, cursor, data.length);
    if (statusEnd < 0) {
      if (partial) break;
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: malformed git name-status',
      );
    }
    final status = _decodeBytes(data.bytes, cursor, statusEnd);
    cursor = statusEnd + 1;
    if (status.isEmpty) continue;
    final code = status[0];
    final firstEnd = _nextNul(data.bytes, cursor, data.length);
    if (firstEnd < 0) {
      if (partial) break;
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: malformed git name-status path',
      );
    }
    final firstPath = _repositoryPath(
      _decodeBytes(data.bytes, cursor, firstEnd),
    );
    cursor = firstEnd + 1;
    if (firstPath.isEmpty) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: empty git name-status path',
      );
    }
    if (code == 'R' || code == 'C') {
      final secondEnd = _nextNul(data.bytes, cursor, data.length);
      if (secondEnd < 0) {
        if (partial) break;
        throw const _CollectorFailure(
          SensoriumReason.failed,
          'failed: malformed git rename paths',
        );
      }
      final secondPath = _repositoryPath(
        _decodeBytes(data.bytes, cursor, secondEnd),
      );
      cursor = secondEnd + 1;
      if (secondPath.isEmpty) {
        throw const _CollectorFailure(
          SensoriumReason.failed,
          'failed: empty git rename path',
        );
      }
      files.putIfAbsent(firstPath, () => 'D');
      files.putIfAbsent(secondPath, () => 'A');
      entries += 2;
    } else {
      files.putIfAbsent(
        firstPath,
        () => switch (code) {
          'A' => 'A',
          'D' => 'D',
          _ => 'M',
        },
      );
      entries++;
    }
    if (entries >= _vcsEntryLimit && cursor < data.length) {
      partial = true;
      break;
    }
  }
  return _GitSummary(files, partial);
}

_GitNumstat _parseGitNumstat(VcsProcessResult result) {
  final data = _gitData(result);
  final deltas = <VcsDelta>[];
  var partial = data.partial;
  var cursor = 0;
  var entries = 0;
  while (cursor < data.length) {
    final end = _nextNul(data.bytes, cursor, data.length);
    if (end < 0) {
      if (partial) break;
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: malformed git numstat',
      );
    }
    final firstTab = _findByte(data.bytes, cursor, end, 9);
    final secondTab = firstTab < 0
        ? -1
        : _findByte(data.bytes, firstTab + 1, end, 9);
    if (firstTab < 0 || secondTab < 0 || secondTab + 1 == end) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: malformed git numstat row',
      );
    }
    final added = _numstatCount(data.bytes, cursor, firstTab);
    final removed = _numstatCount(data.bytes, firstTab + 1, secondTab);
    final binary = added == null || removed == null;
    final pathStart = secondTab + 1;
    final path = _repositoryPath(_decodeBytes(data.bytes, pathStart, end));
    deltas.add(
      VcsDelta(
        path: path,
        added: added ?? 0,
        removed: removed ?? 0,
        binary: binary,
        pathIsUtf8: _isValidUtf8(data.bytes, pathStart, end),
      ),
    );
    entries++;
    cursor = end + 1;
    if (entries == _vcsEntryLimit && cursor < data.length) {
      partial = true;
      break;
    }
  }
  return _GitNumstat(deltas, partial);
}

int _nextNul(List<int> bytes, int start, int end) =>
    _findByte(bytes, start, end, 0);

int _findByte(List<int> bytes, int start, int end, int target) {
  for (var index = start; index < end; index++) {
    if (bytes[index] == target) return index;
  }
  return -1;
}

int _afterSpaces(List<int> bytes, int start, int end, int count) {
  var found = 0;
  for (var index = start; index < end; index++) {
    if (bytes[index] == 32 && ++found == count) return index + 1;
  }
  return -1;
}

bool _bytePrefix(List<int> bytes, int start, int end, String prefix) {
  if (end - start < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[start + i] != prefix.codeUnitAt(i)) return false;
  }
  return true;
}

int? _numstatCount(List<int> bytes, int start, int end) {
  if (end - start == 1 && bytes[start] == 45) return null;
  if (start == end || end - start > 12) {
    throw const _CollectorFailure(
      SensoriumReason.failed,
      'failed: invalid git line count',
    );
  }
  var value = 0;
  for (var i = start; i < end; i++) {
    final digit = bytes[i] - 48;
    if (digit < 0 || digit > 9) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: invalid git line count',
      );
    }
    value = value * 10 + digit;
  }
  return value;
}
