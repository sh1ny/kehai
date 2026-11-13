part of 'vcs_collector.dart';

const Set<String> _jjCollectorCommands = {'log', 'op', 'diff'};

const String _jjSnapshotTemplate =
    r'json({"kind"=>"identity","commit"=>commit_id,"change"=>change_id,"description"=>description.first_line(),"parents"=>parents.map(|p|p.commit_id())}) ++ "\n" ++ diff.files().map(|f|json({"kind"=>"status","path"=>f.path(),"status"=>f.status_char()})).join("\n") ++ "\n" ++ conflicted_files.map(|f|json({"kind"=>"conflict","path"=>f.path()})).join("\n")';

extension _JjCollector on _VcsCollectorEngine {
  Future<VcsCollection> _collectJj(
    _CollectionRun run, {
    required String executable,
    required String repository,
    required VcsCollection? previous,
    required int turn,
    required DateTime time,
    required int? captureSequence,
    required bool jobsLive,
  }) async {
    final snapshotResult = await _jjCommand(
      run,
      executable: executable,
      cwd: repository,
      command: 'log',
      arguments: ['-r', '@', '--no-graph', '-T', _jjSnapshotTemplate],
    );
    _requireJjSuccess('jj', snapshotResult, allowTruncated: true);
    final snapshot = _parseJjSnapshot(snapshotResult);

    final priorBaseline = previous?.baseline;
    final backendChanged =
        priorBaseline != null && priorBaseline.backend != 'jj';
    final operationFuture = _jjCommand(
      run,
      executable: executable,
      cwd: repository,
      command: 'op',
      arguments: const [
        'log',
        '--ignore-working-copy',
        '-n1',
        '--no-graph',
        '-T',
        'id',
      ],
    );
    final Future<VcsProcessResult>? deltaFuture =
        priorBaseline == null || backendChanged
        ? null
        : _jjCommand(
            run,
            executable: executable,
            cwd: repository,
            command: 'diff',
            arguments: [
              '--ignore-working-copy',
              '--from',
              priorBaseline.id,
              '--to',
              snapshot.commit,
              '--git',
            ],
          );
    final followups = await Future.wait<VcsProcessResult>([
      operationFuture,
      if (deltaFuture != null) deltaFuture,
    ]);
    final operationResult = followups.first;
    _requireJjSuccess('jj', operationResult);
    if (operationResult._stdoutTruncated) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: invalid jj operation id',
      );
    }
    final operation = _jjSingleLine(operationResult.stdout);
    if (operation.isEmpty) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: missing jj operation id',
      );
    }

    var baselineLost = backendChanged;
    var deltas = <VcsDelta>[];
    var deltaPartial = false;
    if (deltaFuture != null) {
      final deltaResult = followups[1];
      if (deltaResult.exitCode != 0 && _looksLikeMissingBaseline(deltaResult)) {
        baselineLost = true;
      } else {
        _requireJjSuccess('jj', deltaResult, allowTruncated: true);
        final parsed = _parseJjGitDiff(deltaResult);
        deltas = parsed.deltas;
        deltaPartial = parsed.partial;
      }
    }

    final statuses = snapshot.statuses;
    var modified = 0;
    var added = 0;
    var deleted = 0;
    for (final status in statuses.values) {
      switch (status) {
        case 'A':
          added++;
        case 'D':
          deleted++;
        default:
          modified++;
      }
    }
    final visiblePaths = statuses.keys
        .take(12)
        .map((path) => _clipUtf8(path, 64))
        .toList(growable: false);
    final visibleConflicts = snapshot.conflicts
        .take(12)
        .map((path) => _clipUtf8(path, 64))
        .toList(growable: false);
    final partial = snapshot.partial || deltaPartial;
    final value = SensoriumVcs(
      branch: 'working copy',
      paths: visiblePaths,
      backend: 'jj',
      change: _clipUtf8(snapshot.change, 128),
      description: _clipUtf8(snapshot.description, 512),
      parent: snapshot.parents.isEmpty
          ? null
          : _clipUtf8(snapshot.parents.first, 128),
      operation: _clipUtf8(operation, 128),
      modified: modified,
      added: added,
      deleted: deleted,
      conflicts: visibleConflicts,
      partial: partial,
      totalPaths: statuses.length,
      conflictCount: snapshot.conflicts.length,
    );
    final baseline = this.baseline(
      'jj',
      snapshot.commit,
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
      reason: reason,
      baselineLost: baselineLost,
    );
  }

  Future<VcsProcessResult> _jjCommand(
    _CollectionRun run, {
    required String executable,
    required String cwd,
    required String command,
    required List<String> arguments,
  }) {
    if (!_jjCollectorCommands.contains(command)) {
      throw StateError('jj command is outside the collector allowlist.');
    }
    return this.command(
      run,
      executable: executable,
      cwd: cwd,
      arguments: ['--no-pager', '--color=never', command, ...arguments],
      environment: jjEnvironment(),
      tool: 'jj',
    );
  }
}

final class _JjSnapshot {
  const _JjSnapshot({
    required this.commit,
    required this.change,
    required this.description,
    required this.parents,
    required this.statuses,
    required this.conflicts,
    required this.partial,
  });

  final String commit;
  final String change;
  final String description;
  final List<String> parents;
  final Map<String, String> statuses;
  final List<String> conflicts;
  final bool partial;
}

final class _JjDeltas {
  const _JjDeltas(this.deltas, this.partial);

  final List<VcsDelta> deltas;
  final bool partial;
}

final class _PatchFile {
  _PatchFile(
    this.oldPath,
    this.newPath, {
    this.oldPathIsUtf8 = true,
    this.newPathIsUtf8 = true,
  });

  String? oldPath;
  String? newPath;
  bool oldPathIsUtf8;
  bool newPathIsUtf8;
  int added = 0;
  int removed = 0;
  bool binary = false;
  bool inHunk = false;
}

final class _DecodedPatchPath {
  const _DecodedPatchPath(this.path, this.pathIsUtf8);

  final String path;
  final bool pathIsUtf8;
}

final class _GitPathToken {
  const _GitPathToken(this.bytes, this.next);

  final List<int> bytes;
  final int next;
}

_GitData _jjData(VcsProcessResult result) {
  final length = result.stdout.length < _vcsOutputLimit
      ? result.stdout.length
      : _vcsOutputLimit;
  return _GitData(result.stdout, length, result._stdoutTruncated);
}

void _requireJjSuccess(
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

_JjSnapshot _parseJjSnapshot(VcsProcessResult result) {
  final data = _jjData(result);
  String? commit;
  String? change;
  String? description;
  List<String>? parents;
  final statuses = <String, String>{};
  final conflicts = <String>[];
  final conflictSet = <String>{};
  var entries = 0;
  var partial = data.partial;
  var cursor = 0;
  while (cursor < data.length) {
    final newline = _findByte(data.bytes, cursor, data.length, 10);
    if (newline < 0 && partial) break;
    final end = newline < 0 ? data.length : newline;
    var contentEnd = end;
    if (contentEnd > cursor && data.bytes[contentEnd - 1] == 13) contentEnd--;
    if (contentEnd == cursor) {
      cursor = newline < 0 ? data.length : newline + 1;
      continue;
    }
    final decoded = _decodeJsonLine(data.bytes, cursor, contentEnd);
    if (decoded is! Map<String, dynamic>) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: invalid jj snapshot row',
      );
    }
    final kind = decoded['kind'];
    if (kind == 'identity') {
      if (commit != null || entries != 0) {
        throw const _CollectorFailure(
          SensoriumReason.failed,
          'failed: invalid jj snapshot identity',
        );
      }
      final rawCommit = decoded['commit'];
      final rawChange = decoded['change'];
      final rawDescription = decoded['description'];
      final rawParents = decoded['parents'];
      if (rawCommit is! String ||
          rawChange is! String ||
          rawDescription is! String ||
          rawParents is! List ||
          rawParents.any((parent) => parent is! String)) {
        throw const _CollectorFailure(
          SensoriumReason.failed,
          'failed: invalid jj snapshot identity',
        );
      }
      commit = rawCommit;
      change = rawChange;
      description = rawDescription;
      parents = rawParents.cast<String>();
    } else {
      if (commit == null) {
        throw const _CollectorFailure(
          SensoriumReason.failed,
          'failed: jj snapshot identity is missing',
        );
      }
      if (entries == _vcsEntryLimit) {
        partial = true;
        break;
      }
      entries++;
      if (kind == 'status') {
        final rawPath = decoded['path'];
        final rawStatus = decoded['status'];
        if (rawPath is! String || rawStatus is! String || rawStatus.isEmpty) {
          throw const _CollectorFailure(
            SensoriumReason.failed,
            'failed: invalid jj status row',
          );
        }
        statuses[_repositoryPath(rawPath)] = rawStatus
            .substring(0, 1)
            .toUpperCase();
      } else if (kind == 'conflict') {
        final rawPath = decoded['path'];
        if (rawPath is! String) {
          throw const _CollectorFailure(
            SensoriumReason.failed,
            'failed: invalid jj conflict row',
          );
        }
        final path = _repositoryPath(rawPath);
        if (conflictSet.add(path)) conflicts.add(path);
        statuses.putIfAbsent(path, () => 'C');
      } else {
        throw const _CollectorFailure(
          SensoriumReason.failed,
          'failed: unknown jj snapshot row',
        );
      }
    }
    cursor = newline < 0 ? data.length : newline + 1;
  }
  if (commit == null ||
      change == null ||
      description == null ||
      parents == null) {
    throw const _CollectorFailure(
      SensoriumReason.failed,
      'failed: missing jj snapshot identity',
    );
  }
  return _JjSnapshot(
    commit: _clipUtf8(commit, 128),
    change: _clipUtf8(change, 128),
    description: _clipUtf8(description, 512),
    parents: parents,
    statuses: statuses,
    conflicts: conflicts,
    partial: partial,
  );
}

Object? _decodeJsonLine(List<int> bytes, int start, int end) {
  try {
    return jsonDecode(utf8.decode(_byteView(bytes, start, end)));
  } on FormatException {
    throw const _CollectorFailure(
      SensoriumReason.failed,
      'failed: malformed jj snapshot',
    );
  }
}

String _jjSingleLine(List<int> bytes) {
  var end = bytes.length;
  while (end > 0 && (bytes[end - 1] == 10 || bytes[end - 1] == 13)) {
    end--;
  }
  return _decodeBytes(bytes, 0, end);
}

_JjDeltas _parseJjGitDiff(VcsProcessResult result) {
  final data = _jjData(result);
  final deltas = <VcsDelta>[];
  var partial = data.partial;
  var cursor = 0;
  _PatchFile? current;
  var entries = 0;

  void finishFile() {
    final file = current;
    if (file == null) return;
    final path = file.newPath ?? file.oldPath;
    final pathIsUtf8 = file.newPath == null
        ? file.oldPathIsUtf8
        : file.newPathIsUtf8;
    if (path == null || path.isEmpty) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: jj diff path is missing',
      );
    }
    if (entries >= _vcsEntryLimit) {
      partial = true;
      current = null;
      return;
    }
    deltas.add(
      VcsDelta(
        path: path,
        added: file.binary ? 0 : file.added,
        removed: file.binary ? 0 : file.removed,
        binary: file.binary,
        pathIsUtf8: pathIsUtf8,
      ),
    );
    entries++;
    current = null;
  }

  while (cursor < data.length) {
    final newline = _findByte(data.bytes, cursor, data.length, 10);
    if (newline < 0 && partial) break;
    final end = newline < 0 ? data.length : newline;
    if (_bytePrefix(data.bytes, cursor, end, 'diff --git ')) {
      finishFile();
      if (entries >= _vcsEntryLimit) {
        partial = true;
        break;
      }
      current = _newPatchFile(data.bytes, cursor + 11, end);
    } else if (current case final file?) {
      _readPatchLine(file, data.bytes, cursor, end);
    } else if (end > cursor) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: malformed jj diff',
      );
    }
    cursor = newline < 0 ? data.length : newline + 1;
  }
  finishFile();
  return _JjDeltas(deltas, partial);
}

_PatchFile _newPatchFile(List<int> bytes, int start, int end) {
  final header = _headerPaths(bytes, start, end);
  return _PatchFile(
    header.$1,
    header.$2,
    oldPathIsUtf8: header.$3,
    newPathIsUtf8: header.$4,
  );
}

void _readPatchLine(_PatchFile file, List<int> bytes, int start, int end) {
  if (_bytePrefix(bytes, start, end, 'GIT binary patch') ||
      _bytePrefix(bytes, start, end, 'Binary files ')) {
    file.binary = true;
    return;
  }
  if (!file.inHunk && _bytePrefix(bytes, start, end, '--- ')) {
    final value = _patchPath(bytes, start + 4, end);
    if (value != null) {
      file
        ..oldPath = value.path
        ..oldPathIsUtf8 = value.pathIsUtf8;
    }
    return;
  }
  if (!file.inHunk && _bytePrefix(bytes, start, end, '+++ ')) {
    final value = _patchPath(bytes, start + 4, end);
    if (value != null) {
      file
        ..newPath = value.path
        ..newPathIsUtf8 = value.pathIsUtf8;
    }
    return;
  }
  if (_bytePrefix(bytes, start, end, '@@')) {
    file.inHunk = true;
    return;
  }
  if (!file.inHunk || start == end) return;
  if (bytes[start] == 43) {
    file.added++;
  } else if (bytes[start] == 45) {
    file.removed++;
  }
}

(String?, String?, bool, bool) _headerPaths(
  List<int> bytes,
  int start,
  int end,
) {
  if (start >= end) return (null, null, true, true);
  final oldToken = _pathToken(bytes, start, end);
  if (oldToken != null && oldToken.next < end && bytes[oldToken.next] == 32) {
    final newToken = _pathToken(bytes, oldToken.next + 1, end);
    if (newToken != null && newToken.next == end) {
      final oldPath = _stripGitPath(oldToken.bytes, 'a/');
      final newPath = _stripGitPath(newToken.bytes, 'b/');
      return (
        oldPath,
        newPath,
        oldPath == null ||
            _isValidUtf8(oldToken.bytes, 2, oldToken.bytes.length),
        newPath == null ||
            _isValidUtf8(newToken.bytes, 2, newToken.bytes.length),
      );
    }
  }

  (String?, String?, bool, bool)? equalPaths;
  (String?, String?, bool, bool)? candidate;
  for (var index = start; index + 2 < end; index++) {
    if (bytes[index] != 32 ||
        bytes[index + 1] != 98 ||
        bytes[index + 2] != 47) {
      continue;
    }
    if (!_bytePrefix(bytes, start, index, 'a/') ||
        !_bytePrefix(bytes, index + 1, end, 'b/')) {
      continue;
    }
    final oldPath = _repositoryPath(_decodeBytes(bytes, start + 2, index));
    final newPath = _repositoryPath(_decodeBytes(bytes, index + 3, end));
    final decoded = (
      oldPath,
      newPath,
      _isValidUtf8(bytes, start + 2, index),
      _isValidUtf8(bytes, index + 3, end),
    );
    candidate ??= decoded;
    if (oldPath == newPath) equalPaths = decoded;
  }
  return equalPaths ?? candidate ?? (null, null, true, true);
}

_DecodedPatchPath? _patchPath(List<int> bytes, int start, int end) {
  if (start >= end) return null;
  List<int> value;
  if (bytes[start] == 34) {
    final token = _pathToken(bytes, start, end);
    if (token == null) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: malformed quoted jj path',
      );
    }
    var next = token.next;
    while (next < end && bytes[next] == 32) {
      next++;
    }
    if (next != end) {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: malformed quoted jj path',
      );
    }
    value = token.bytes;
  } else {
    value = _byteView(bytes, start, end);
  }
  if (_byteEquals(value, '/dev/null')) return null;
  final stripped = _stripGitPathBytes(value);
  if (stripped == null) return null;
  return _DecodedPatchPath(
    _repositoryPath(_decodeBytes(stripped, 0, stripped.length)),
    _isValidUtf8(stripped, 0, stripped.length),
  );
}

_GitPathToken? _pathToken(List<int> bytes, int start, int end) {
  if (start >= end) return null;
  if (bytes[start] != 34) {
    var cursor = start;
    while (cursor < end && bytes[cursor] != 32) {
      cursor++;
    }
    return _GitPathToken(_byteView(bytes, start, cursor), cursor);
  }
  final value = <int>[];
  var cursor = start + 1;
  while (cursor < end) {
    final byte = bytes[cursor++];
    if (byte == 34) return _GitPathToken(value, cursor);
    if (byte != 92) {
      value.add(byte);
      continue;
    }
    if (cursor == end) return null;
    final escaped = bytes[cursor++];
    switch (escaped) {
      case 97:
        value.add(7);
      case 98:
        value.add(8);
      case 116:
        value.add(9);
      case 110:
        value.add(10);
      case 118:
        value.add(11);
      case 102:
        value.add(12);
      case 114:
        value.add(13);
      case 101:
        value.add(27);
      case 92:
        value.add(92);
      case 34:
        value.add(34);
      default:
        if (escaped >= 48 && escaped <= 55) {
          var octal = escaped - 48;
          var count = 1;
          while (count < 3 && cursor < end) {
            final digit = bytes[cursor];
            if (digit < 48 || digit > 55) break;
            octal = octal * 8 + digit - 48;
            cursor++;
            count++;
          }
          value.add(octal & 0xff);
        } else if (escaped == 120 && cursor + 1 < end) {
          final high = _hexDigit(bytes[cursor]);
          final low = _hexDigit(bytes[cursor + 1]);
          if (high < 0 || low < 0) return null;
          value.add(high * 16 + low);
          cursor += 2;
        } else {
          return null;
        }
    }
  }
  return null;
}

String? _stripGitPath(List<int> bytes, String prefix) {
  if (prefix.length != 2 ||
      bytes.length < 2 ||
      bytes[0] != prefix.codeUnitAt(0) ||
      bytes[1] != prefix.codeUnitAt(1)) {
    return null;
  }
  return _repositoryPath(_decodeBytes(bytes, 2, bytes.length));
}

List<int>? _stripGitPathBytes(List<int> bytes) {
  if (bytes.length < 2 ||
      bytes[1] != 47 ||
      (bytes[0] != 97 && bytes[0] != 98)) {
    return null;
  }
  return _byteView(bytes, 2, bytes.length);
}

bool _byteEquals(List<int> bytes, String text) {
  if (bytes.length != text.length) return false;
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] != text.codeUnitAt(i)) return false;
  }
  return true;
}

int _hexDigit(int byte) => switch (byte) {
  >= 48 && <= 57 => byte - 48,
  >= 65 && <= 70 => byte - 55,
  >= 97 && <= 102 => byte - 87,
  _ => -1,
};
