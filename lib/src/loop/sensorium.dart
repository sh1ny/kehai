/// The bounded full request-only sensorium and its context accounting.
library;

import 'dart:convert';

import '../provider/provider.dart';
import '../session/scratch.dart';

/// The finite section allocations, including their labels and indentation.
abstract final class SensoriumAllocations {
  static const turn = 30;
  static const budget = 40;
  static const vcs = 250;
  static const changes = 200;
  static const diagnostics = 300;
  static const tests = 150;
  static const processes = 150;
  static const plan = 60;
  static const scratch = maxScratchSectionTokens;
  static const checkpoints = 60;
  static const notices = 80;
  static const framing = 20;
  static const defaultMaxTokens = 1500;
  static const foldedVcs = 40;
  static const foldedTests = 40;
  static const foldedProcesses = 40;

  static const sectionCaps = <String, int>{
    'turn': turn,
    'budget': budget,
    'vcs': vcs,
    'changes_since_last_turn': changes,
    'diagnostics': diagnostics,
    'tests': tests,
    'processes': processes,
    'plan': plan,
    'scratch': scratch,
    'checkpoints': checkpoints,
    'notices': notices,
  };
  static const immutableCaps = <String, int>{
    'turn': turn,
    'budget': budget,
    'scratch': scratch,
    'notices': notices,
  };
  static const foldedCaps = <String, int>{
    'vcs': foldedVcs,
    'changes_since_last_turn': changes,
    'diagnostics': diagnostics,
    'tests': foldedTests,
    'processes': foldedProcesses,
    'plan': plan,
    'checkpoints': checkpoints,
  };
  static const minimumMaxTokens =
      turn +
      budget +
      scratch +
      notices +
      foldedVcs +
      changes +
      diagnostics +
      foldedTests +
      foldedProcesses +
      plan +
      checkpoints +
      framing;
}

/// A bounded reason vocabulary for finite supplied observations.
enum SensoriumReason {
  notCollected,
  failed,
  timedOut,
  noRepository,
  disabled,
  jjNotFound,
  gitNotFound,
  noBaseline,
  baselineLost,
  cleanupPending,
}

/// The availability of a supplied section, not a collector registration.
sealed class SensoriumObservation<T> {
  const SensoriumObservation();
}

/// A current observation, including a supported empty value.
final class SensoriumAvailable<T> extends SensoriumObservation<T> {
  const SensoriumAvailable(this.value);
  final T value;
}

/// A last known observation with an age and a bounded failure reason.
final class SensoriumStale<T> extends SensoriumObservation<T> {
  const SensoriumStale(this.value, {required this.age, required this.reason});
  final T value;
  final Duration age;
  final SensoriumReason reason;
}

/// An explicitly unobserved or failed section.
final class SensoriumUnavailable<T> extends SensoriumObservation<T> {
  const SensoriumUnavailable(this.reason);
  final SensoriumReason reason;
}

/// The frozen source facts; offset is diagnostic within one journal only.
final class SensoriumSource {
  const SensoriumSource({required this.turn, required this.time, this.offset});
  final int turn;
  final DateTime time;
  final int? offset;
}

/// The route-qualified budget facts used by the composition operation.
final class SensoriumBudget {
  const SensoriumBudget({
    required this.model,
    this.used,
    this.window,
    this.usedEstimated = false,
    this.windowEstimated = false,
    this.compactionThreshold,
    this.turnsSinceCompaction,
  });
  final String model;
  final int? used;
  final int? window;
  final bool usedEstimated;
  final bool windowEstimated;
  final int? compactionThreshold;
  final int? turnsSinceCompaction;
}

/// A VCS summary supplied without scanning the workspace.
final class SensoriumVcs {
  const SensoriumVcs({
    required this.branch,
    required this.paths,
    this.backend = 'git',
    this.change,
    this.description,
    this.parent,
    this.operation,
    this.modified = 0,
    this.added = 0,
    this.deleted = 0,
    this.conflicts = const [],
    this.partial = false,
    this.totalPaths,
    this.conflictCount,
  });
  final String branch;
  final Iterable<String> paths;
  final String backend;
  final String? change;
  final String? description;
  final String? parent;
  final String? operation;
  final int modified;
  final int added;
  final int deleted;
  final Iterable<String> conflicts;
  final bool partial;
  final int? totalPaths;
  final int? conflictCount;
}

/// The origin a captured file difference can prove.
enum SensoriumChangeBy { agent, user, unknown }

/// One changed path, its line counts and its verified origin.
final class SensoriumChange {
  const SensoriumChange(
    this.path, {
    required this.added,
    required this.removed,
    this.by = SensoriumChangeBy.unknown,
    this.binary = false,
  });
  final String path;
  final int added;
  final int removed;
  final SensoriumChangeBy by;
  final bool binary;
}

/// A supplied difference from one captured baseline.
final class SensoriumChanges {
  const SensoriumChanges({
    required this.sinceTurn,
    required this.rows,
    this.totalPaths,
    this.partial = false,
  });
  final int sinceTurn;
  final Iterable<SensoriumChange> rows;
  final int? totalPaths;
  final bool partial;
}

/// One supplied diagnostic, with bounded presentation applied at composition.
final class SensoriumDiagnostic {
  const SensoriumDiagnostic(this.path, this.message);
  final String path;
  final String message;
}

/// A supplied test outcome, with optional failing-name details.
final class SensoriumTests {
  const SensoriumTests({required this.passed, required this.failedNames});
  final int passed;
  final Iterable<String> failedNames;
}

/// A live process fact, never a log reader or spool reference.
final class SensoriumProcess {
  const SensoriumProcess({
    required this.id,
    required this.kind,
    required this.command,
    required this.state,
    required this.started,
  });
  final String id;
  final String kind;
  final String command;
  final String state;
  final DateTime? started;
}

/// A checkpoint preview ordered oldest to newest by the source.
final class SensoriumCheckpoint {
  const SensoriumCheckpoint(this.name);
  final String name;
}

/// The finite notice codes; recovery prose remains a separate request item.
enum SensoriumNotice {
  compactionRecovery('compaction_recovery'),
  legacyWindowIgnored('legacy_window_ignored'),
  vcsTimeout('vcs_timeout'),
  vcsFailed('vcs_failed'),
  userEdits('user_edits'),
  baselineReset('baseline_reset');

  const SensoriumNotice(this.code);
  final String code;
}

/// One request's finite typed composition input.
final class SensoriumSnapshot {
  const SensoriumSnapshot({
    required this.source,
    required this.workspaceName,
    required this.budget,
    this.vcs = const SensoriumUnavailable(SensoriumReason.notCollected),
    this.changes = const SensoriumUnavailable(SensoriumReason.notCollected),
    this.diagnostics = const SensoriumUnavailable(SensoriumReason.notCollected),
    this.tests = const SensoriumUnavailable(SensoriumReason.notCollected),
    this.processes = const [],
    this.plan = const SensoriumUnavailable(SensoriumReason.notCollected),
    required this.scratch,
    this.checkpoints = const SensoriumUnavailable(SensoriumReason.notCollected),
    this.notices = const {},
  });
  final SensoriumSource source;
  final String workspaceName;
  final SensoriumBudget budget;
  final SensoriumObservation<SensoriumVcs> vcs;
  final SensoriumObservation<SensoriumChanges> changes;
  final SensoriumObservation<Iterable<SensoriumDiagnostic>> diagnostics;
  final SensoriumObservation<SensoriumTests> tests;
  final Iterable<SensoriumProcess> processes;
  final SensoriumObservation<String> plan;
  final ScratchState scratch;
  final SensoriumObservation<Iterable<SensoriumCheckpoint>> checkpoints;
  final Set<SensoriumNotice> notices;
}

/// The fixed source-order reductions, never including immutable sections.
enum SensoriumFold { processes, vcs, diagnostics, tests, changes, checkpoints }

/// A successfully composed full observation.
final class SensoriumComposition {
  const SensoriumComposition({
    required this.text,
    required this.tokens,
    required this.mode,
    required this.folds,
  });
  final String text;
  final int tokens;
  final String mode;
  final List<SensoriumFold> folds;
}

/// A local composition refusal with a bounded, value-free diagnostic.
final class SensoriumCompositionError implements Exception {
  const SensoriumCompositionError({required this.code, required this.message});
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Composes one full snapshot, permitting a lower direct-test ceiling.
SensoriumComposition composeSensorium(
  SensoriumSnapshot snapshot, {
  int maxTokens = SensoriumAllocations.defaultMaxTokens,
}) {
  final sections = _Sections(snapshot);
  final folds = <SensoriumFold>[];
  for (var stage = 0; stage <= SensoriumFold.values.length; stage++) {
    final rendered = sections.render(folds);
    final text = '<sensorium>\n${rendered.join('\n')}\n</sensorium>';
    // Select folds against the entire budget allocation, not its current text.
    final reserved =
        (utf8.encode(text).length -
            utf8.encode(rendered[1]).length +
            SensoriumAllocations.budget * 3 +
            2) ~/
        3;
    if (reserved <= maxTokens && estimateText(text) <= maxTokens) {
      return SensoriumComposition(
        text: text,
        tokens: estimateText(text),
        mode: 'full',
        folds: List.unmodifiable(folds),
      );
    }
    if (stage < SensoriumFold.values.length) {
      folds.add(SensoriumFold.values[stage]);
    } else {
      throw SensoriumCompositionError(
        code: 'ceiling',
        message:
            'Sensorium requires $reserved tokens; configured ceiling is $maxTokens.',
      );
    }
  }
  throw StateError('unreachable sensorium stage');
}

/// Replaces only the budget section of an already generated full observation.
///
/// Source previews and folds remain frozen while request accounting converges.
SensoriumComposition sensoriumWithBudget(
  SensoriumComposition composition,
  SensoriumBudget budget, {
  required int maxTokens,
}) {
  final start = composition.text.indexOf('\nbudget:') + 1;
  final end = composition.text.indexOf('\nvcs:', start);
  final text = composition.text.replaceRange(
    start,
    end,
    _budgetSection(budget),
  );
  final tokens = estimateText(text);
  if (tokens > maxTokens) {
    throw SensoriumCompositionError(
      code: 'ceiling',
      message:
          'Sensorium requires $tokens tokens; configured ceiling is $maxTokens.',
    );
  }
  return SensoriumComposition(
    text: text,
    tokens: tokens,
    mode: composition.mode,
    folds: composition.folds,
  );
}

String _reason(SensoriumReason reason) => switch (reason) {
  SensoriumReason.notCollected => 'not collected',
  SensoriumReason.failed => 'failed',
  SensoriumReason.timedOut => 'timeout',
  SensoriumReason.noRepository => 'no repository',
  SensoriumReason.disabled => 'disabled',
  SensoriumReason.jjNotFound => 'jj not found',
  SensoriumReason.gitNotFound => 'git not found',
  SensoriumReason.noBaseline => 'no baseline',
  SensoriumReason.baselineLost => 'baseline lost',
  SensoriumReason.cleanupPending => 'cleanup pending',
};

String _number(int value) => value > -1000000 && value < 1000000
    ? '$value'
    : value.toStringAsExponential(0);

String _age(Duration age) {
  final seconds = age.inSeconds < 0 ? 0 : age.inSeconds;
  return seconds < 60 ? '${_number(seconds)}s' : '${_number(seconds ~/ 60)}m';
}

// Scan only a bounded prefix; never encode or join an unbounded display field.
String _clip(String value, int bytes) {
  final out = StringBuffer();
  var size = 0;
  for (final original in value.runes) {
    final rune =
        original < 32 ||
            original == 0x85 ||
            original == 0x2028 ||
            original == 0x2029
        ? 32
        : original;
    final width = rune <= 0x7f
        ? 1
        : rune <= 0x7ff
        ? 2
        : rune <= 0xffff
        ? 3
        : 4;
    if (size + width > bytes) {
      final prefix = out.toString();
      final shortened = StringBuffer();
      var kept = 0;
      for (final r in prefix.runes) {
        final w = r <= 0x7f
            ? 1
            : r <= 0x7ff
            ? 2
            : r <= 0xffff
            ? 3
            : 4;
        if (kept + w > bytes - 3) break;
        shortened.writeCharCode(r);
        kept += w;
      }
      return '$shortened…';
    }
    out.writeCharCode(rune);
    size += width;
  }
  return out.toString();
}

bool _repositoryEscape(int rune) =>
    rune < 32 ||
    (rune >= 0x7f && rune <= 0x9f) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    rune == 60 ||
    rune == 62;

bool _lineBoundary(int rune) =>
    rune == 10 ||
    rune == 13 ||
    rune == 11 ||
    rune == 12 ||
    rune == 0x85 ||
    rune == 0x2028 ||
    rune == 0x2029;

int _repositoryWidth(int rune) {
  if (_repositoryEscape(rune)) {
    return 4 +
        (rune < 16
            ? 1
            : rune < 256
            ? 2
            : rune < 4096
            ? 3
            : 4);
  }
  return rune <= 0x7f
      ? 1
      : rune <= 0x7ff
      ? 2
      : rune <= 0xffff
      ? 3
      : 4;
}

String _repositoryText(String value, int limit, {bool firstLine = false}) {
  var bytes = 0;
  var end = 0;
  var escaped = false;
  var truncated = false;
  for (final rune in value.runes) {
    if (firstLine && _lineBoundary(rune)) break;
    final width = _repositoryWidth(rune);
    if (bytes + width > limit) {
      truncated = true;
      break;
    }
    bytes += width;
    end += rune > 0xffff ? 2 : 1;
    escaped |= _repositoryEscape(rune);
  }
  if (!truncated && !escaped) {
    return end == value.length ? value : value.substring(0, end);
  }
  // A second bounded scan avoids per-character strings and rollback buffers.
  final budget = truncated ? limit - 5 - value.length.toString().length : limit;
  final out = StringBuffer();
  var consumed = 0;
  bytes = 0;
  for (final rune in value.runes) {
    if (firstLine && _lineBoundary(rune)) break;
    final width = _repositoryWidth(rune);
    if (bytes + width > budget) break;
    if (_repositoryEscape(rune)) {
      out.write('\\u{${rune.toRadixString(16).toUpperCase()}}');
    } else {
      out.writeCharCode(rune);
    }
    consumed += rune > 0xffff ? 2 : 1;
    bytes += width;
  }
  if (truncated) out.write('… +${value.length - consumed}');
  return out.toString();
}

(String, String) _changesSection(SensoriumChanges changes, int cap) {
  final full = _Preview(12);
  final folded = _Preview(12);
  for (final change in changes.rows) {
    final path = _repositoryText(change.path, 45);
    final counts = change.binary
        ? 'binary'
        : '+${_number(change.added)} -${_number(change.removed)}';
    full.add('$path $counts by: ${change.by.name}');
    folded.add('$path by: ${change.by.name}');
  }
  final total = changes.totalPaths;
  if (total != null && total > full.count) full.count = total;
  folded.count = full.count;
  final detail =
      'since_turn: ${_number(changes.sinceTurn)}${changes.partial ? ' partial' : ''}';
  if (changes.partial && full.count == 0) {
    final text = 'changes_since_last_turn: $detail';
    return (text, text);
  }
  return (
    _rows('changes_since_last_turn', full, cap, detail: detail),
    _rows('changes_since_last_turn', folded, cap, detail: detail),
  );
}

String _vcsCounts(SensoriumVcs vcs, int conflicts) {
  final conflictCount = conflicts == 0 && !vcs.partial
      ? 'none'
      : '${vcs.partial ? '≥ ' : ''}${_number(conflicts)}';
  return '${vcs.partial ? '≥ ' : ''}M ${_number(vcs.modified)}  '
      'A ${_number(vcs.added)}  D ${_number(vcs.deleted)}'
      '${vcs.partial ? ' partial' : ''} · conflicts: $conflictCount';
}

(String, String) _vcsSection(SensoriumVcs vcs, int cap) {
  final paths = _Preview(12);
  for (final path in vcs.paths) {
    paths.add(_repositoryText(path, 48));
  }
  paths.count = vcs.totalPaths ?? paths.count;
  final conflicts = _Preview(12);
  for (final path in vcs.conflicts) {
    conflicts.add(_repositoryText(path, 48));
  }
  conflicts.count = vcs.conflictCount ?? conflicts.count;
  final counts = _vcsCounts(vcs, conflicts.count);
  final fixed = [
    'vcs: backend: ${_repositoryText(vcs.backend, 8)}',
    '  branch: ${_repositoryText(vcs.branch, 32)}',
    if (vcs.change != null) '  change: ${_repositoryText(vcs.change!, 32)}',
    if (vcs.description != null && vcs.description!.isNotEmpty)
      '  description: ${_repositoryText(vcs.description!, 64, firstLine: true)}',
    if (vcs.parent != null) '  parent: ${_repositoryText(vcs.parent!, 24)}',
    '  $counts',
    if (vcs.operation != null)
      '  ${vcs.backend == 'jj' ? 'operation' : 'HEAD'}: ${_repositoryText(vcs.operation!, 24)}',
  ];
  var shownPaths = paths.rows.length;
  var shownConflicts = conflicts.rows.length;
  while (true) {
    final text = [
      ...fixed,
      for (var i = 0; i < shownPaths; i++) '  ${paths.rows[i]}',
      if (paths.count > shownPaths)
        '  … +${_number(paths.count - shownPaths)} more',
      for (var i = 0; i < shownConflicts; i++)
        '  conflict: ${conflicts.rows[i]}',
      if (conflicts.count > shownConflicts)
        '  conflicts: … +${_number(conflicts.count - shownConflicts)} more',
    ].join('\n');
    if (estimateText(text) <= cap) return (text, 'vcs: $counts');
    if (shownPaths > 0) {
      shownPaths--;
    } else if (shownConflicts > 0) {
      shownConflicts--;
    } else {
      throw const SensoriumCompositionError(
        code: 'section',
        message: 'VCS summary cannot fit its allocation.',
      );
    }
  }
}

String _chars(String value, int max) {
  final out = <int>[];
  for (final rune in value.runes) {
    if (out.length == max) {
      out[max - 1] = 0x2026;
      return String.fromCharCodes(out);
    }
    out.add(rune);
  }
  return String.fromCharCodes(out);
}

String _turnSection(SensoriumSnapshot snapshot) {
  final time = snapshot.source.time;
  String two(int n) => n.toString().padLeft(2, '0');
  final fixed =
      'turn: ${_number(snapshot.source.turn)} · full · '
      '${two(time.hour)}:${two(time.minute)} · cwd ';
  return fixed +
      _clip(
        snapshot.workspaceName,
        SensoriumAllocations.turn * 3 - utf8.encode(fixed).length,
      );
}

String _budgetSection(SensoriumBudget b) {
  String count(int? value, bool estimated) =>
      value == null ? '?' : '${estimated ? '~' : ''}${formatTokens(value)}';
  final percent = b.window == null || b.window! <= 0 || b.used == null
      ? ''
      : ' (${b.usedEstimated || b.windowEstimated ? '~' : ''}'
            '${_number((b.used! * 100 / b.window!).round())}%)';
  final fixed =
      'budget: ${count(b.used, b.usedEstimated)}/'
      '${count(b.window, b.windowEstimated)} ctx$percent · cost ?'
      '${b.compactionThreshold == null ? '' : ' · at ${formatTokens(b.compactionThreshold!)}'}'
      '${b.turnsSinceCompaction == null ? '' : ' · since ${_number(b.turnsSinceCompaction!)}'}'
      ' · model ';
  return fixed +
      _clip(
        b.model,
        SensoriumAllocations.budget * 3 - utf8.encode(fixed).length,
      );
}

final class _Preview {
  _Preview(this.limit, {this.latest = false});
  final int limit;
  final bool latest;
  var count = 0;
  final rows = <String>[];
  void add(String row) {
    count++;
    if (rows.length < limit) {
      rows.add(row);
    } else if (latest) {
      rows.removeAt(0);
      rows.add(row);
    }
  }
}

// Each stored row is already bounded. Try only bounded preview prefixes and
// always account for a total omission marker before admitting another row.
String _rows(
  String header,
  _Preview preview,
  int cap, {
  int? limit,
  String detail = '',
}) {
  if (preview.count == 0) {
    return '$header: none${detail.isEmpty ? '' : ' ($detail)'}';
  }
  var shown = limit == null || limit > preview.rows.length
      ? preview.rows.length
      : limit;
  final heading = detail.isEmpty ? '$header:' : '$header: $detail';
  while (shown >= 0) {
    final rows = preview.latest
        ? preview.rows.skip(preview.rows.length - shown)
        : preview.rows.take(shown);
    final omitted = preview.count - shown;
    final text =
        '$heading\n${rows.map((row) => '  $row').join('\n')}'
        '${omitted > 0 ? '${shown > 0 ? '\n' : ''}  … +${_number(omitted)} more' : ''}';
    if (estimateText(text) <= cap) return text;
    shown--;
  }
  throw const SensoriumCompositionError(
    code: 'section',
    message: 'Sensorium section count cannot fit its allocation.',
  );
}

final class _Observed {
  const _Observed(this.normal, this.reduced, [this.prefix = '']);
  final String normal;
  final String reduced;
  final String prefix;
  String section(String name, bool fold) {
    final value = fold ? reduced : normal;
    if (value.startsWith('$name:')) {
      return prefix.isEmpty
          ? value
          : '$name: $prefix${value.substring(name.length + 1)}';
    }
    return '$name: $value';
  }
}

String _noticesSection(Set<SensoriumNotice> notices) {
  if (notices.isEmpty) return 'notices: none';
  final text = StringBuffer('notices: ');
  var separator = '';
  for (final notice in SensoriumNotice.values) {
    if (!notices.contains(notice)) continue;
    text
      ..write(separator)
      ..write(notice.code);
    separator = ', ';
  }
  return text.toString();
}

final class _Sections {
  _Sections(this.snapshot) {
    vcs = _observe(snapshot.vcs, SensoriumAllocations.vcs, _vcsSection);
    changes = _observe(
      snapshot.changes,
      SensoriumAllocations.changes,
      _changesSection,
    );
    diagnostics = _observe(
      snapshot.diagnostics,
      SensoriumAllocations.diagnostics,
      (values, cap) {
        final preview = _Preview(10);
        for (final d in values) {
          preview.add(
            '${_clip(d.path, 48)}: ${_clip(_chars(d.message, 120), 360)}',
          );
        }
        return (
          _rows('diagnostics', preview, cap),
          _rows('diagnostics', preview, cap, limit: 3),
        );
      },
    );
    tests = _observe(snapshot.tests, SensoriumAllocations.tests, (v, cap) {
      final preview = _Preview(8);
      for (final name in v.failedNames) {
        preview.add(_clip(name, 42));
      }
      if (v.passed == 0 && preview.count == 0) {
        return ('tests: none', 'tests: none');
      }
      final counts =
          '${_number(v.passed)} passed, ${_number(preview.count)} failed';
      return (
        preview.count == 0
            ? 'tests: $counts'
            : _rows(
                'tests',
                preview,
                cap - estimateText(' $counts'),
              ).replaceFirst('tests:', 'tests: $counts'),
        'tests: $counts',
      );
    });
    plan = _observe(
      snapshot.plan,
      SensoriumAllocations.plan,
      (value, cap) => (
        'plan: ${value.isEmpty ? 'none' : _clip(value, cap * 3 - 6)}',
        'plan: ${value.isEmpty ? 'none' : _clip(value, cap * 3 - 6)}',
      ),
    );
    checkpoints = _observe(
      snapshot.checkpoints,
      SensoriumAllocations.checkpoints,
      (values, cap) {
        final preview = _Preview(5, latest: true);
        for (final c in values) {
          preview.add(_clip(c.name, 24));
        }
        return (
          _rows('checkpoints', preview, cap),
          _rows('checkpoints', preview, cap, limit: 1),
        );
      },
    );
    final jobs = _Preview(5);
    for (final job in snapshot.processes) {
      if (job.state != 'pending' && job.state != 'running') continue;
      jobs.add(
        '${_clip(job.id, 30)} ${_clip(job.kind, 15)} '
        '${_clip(job.command, 65)} ${job.state} '
        '${job.started == null ? 'age ?' : _age(snapshot.source.time.difference(job.started!))}',
      );
    }
    processes = jobs.count == 0
        ? 'processes: none'
        : '${_rows('processes', jobs, 130)}\n  logs unavailable (published at exit)';
    processCounts = jobs.count == 0
        ? 'processes: none'
        : 'processes: ${_number(jobs.count)} live · logs unavailable (published at exit)';
  }
  final SensoriumSnapshot snapshot;
  late final _Observed vcs, changes, diagnostics, tests, plan, checkpoints;
  late final String processes, processCounts;

  _Observed _observe<T>(
    SensoriumObservation<T> observation,
    int cap,
    (String, String) Function(T, int) render,
  ) {
    // Consume each finite source exactly once, retaining only bounded strings.
    switch (observation) {
      case SensoriumUnavailable<T>(:final reason):
        final text = 'unavailable (${_reason(reason)})';
        return _Observed(text, text);
      case SensoriumAvailable<T>(:final value):
        final pair = render(value, cap);
        return _Observed(pair.$1, pair.$2);
      case SensoriumStale<T>(:final value, :final age, :final reason):
        final prefix = 'stale (${_reason(reason)}, ${_age(age)})';
        final pair = render(value, cap - estimateText(' $prefix'));
        return _Observed(pair.$1, pair.$2, prefix);
    }
  }

  List<String> render(List<SensoriumFold> folds) => [
    _turnSection(snapshot),
    _budgetSection(snapshot.budget),
    vcs.section('vcs', folds.contains(SensoriumFold.vcs)),
    changes.section(
      'changes_since_last_turn',
      folds.contains(SensoriumFold.changes),
    ),
    diagnostics.section(
      'diagnostics',
      folds.contains(SensoriumFold.diagnostics),
    ),
    tests.section('tests', folds.contains(SensoriumFold.tests)),
    folds.contains(SensoriumFold.processes) ? processCounts : processes,
    plan.section('plan', false),
    snapshot.scratch.text,
    checkpoints.section(
      'checkpoints',
      folds.contains(SensoriumFold.checkpoints),
    ),
    _noticesSection(snapshot.notices),
  ];
}

/// Estimates the tokens of one conversation item.
typedef ItemEstimator = int Function(ConversationItem item);

/// The estimate of [text]: its UTF-8 bytes over three, rounded up.
int estimateText(String text) => scratchTokens(text);

/// The default [ItemEstimator]; it errs high, like the provider's estimate.
int estimateItem(ConversationItem item) => switch (item) {
  UserMessage(:final text) ||
  AssistantMessage(:final text) => estimateText(text),
  ToolCallItem(:final name, :final argumentsJson) =>
    estimateText(name) + estimateText(argumentsJson),
  ToolOutputItem(:final output) => estimateText(output),
  OpaqueReasoningItem(:final json) => estimateText(jsonEncode(json)),
  OpaqueCompactionItem() => throw UnsupportedError(
    'opaque compaction token accounting is unknown',
  ),
};

/// Renders a token count as `41k` below a million and `1.2M` above.
String formatTokens(int tokens) {
  if (tokens <= -999500 || tokens >= 1000000000) {
    return tokens.toStringAsExponential(0);
  }
  if (tokens >= 999500) {
    final millions = (tokens / 100000).round() / 10;
    return '${millions.toStringAsFixed(1)}M';
  }
  return '${(tokens / 1000).round()}k';
}

/// Builds a full observation when only turn and budget facts are available.
///
/// [now] is the local time shown as `HH:MM`. Uncollected sources are explicit;
/// supported empty scratch, processes and notices are rendered as `none`.
String sensoriumBlock({
  required int turn,
  required DateTime now,
  required String workspaceName,
  required int? used,
  required int? window,
  required String model,
  bool usedEstimated = false,
  bool windowEstimated = false,
}) {
  return composeSensorium(
    SensoriumSnapshot(
      source: SensoriumSource(turn: turn, time: now),
      workspaceName: workspaceName,
      budget: SensoriumBudget(
        model: model,
        used: used,
        window: window,
        usedEstimated: usedEstimated,
        windowEstimated: windowEstimated,
      ),
      scratch: ScratchState.read(null),
    ),
  ).text;
}

/// What a built conversation item is, for context accounting.
enum ItemRole {
  /// The user's prompt that opened an exchange.
  prompt,

  /// Text, reasoning or a call of a step's response.
  response,

  /// A tool output answering a call of a step.
  output,

  /// A derived message added after a step, such as the interrupted note.
  note,
}

/// A conversation item with its provenance.
///
/// [turn] is the journal turn of the step it belongs to, or of the exchange's
/// first turn for a [ItemRole.prompt].
final class BuiltItem {
  /// Creates an item with its provenance.
  const BuiltItem(this.item, this.turn, this.role);

  /// The item as sent to the model.
  final ConversationItem item;

  /// The journal turn it belongs to.
  final int turn;

  /// What kind of item it is.
  final ItemRole role;
}

/// The baseline of context accounting: the last completed step that reported
/// usage.
final class UsageBaseline {
  /// Creates a baseline.
  const UsageBaseline({
    required this.turn,
    required this.tokens,
    required this.block,
  });

  /// The step's journal turn.
  final int turn;

  /// Its reported input plus output tokens.
  final int tokens;

  /// The estimate of the sensorium block that request carried.
  final int block;
}

/// The estimate of the items a baseline does not cover, chosen by provenance.
///
/// Prompts and response items of steps up to the baseline are inside its
/// reported input or output. Outputs answering earlier steps are inside its
/// input; outputs answering the baseline step itself are not, wherever the
/// request places them.
int uncoveredTokens(
  List<BuiltItem> items,
  UsageBaseline baseline,
  ItemEstimator estimate,
) {
  var sum = 0;
  for (final BuiltItem(:item, :turn, :role) in items) {
    final covered = switch (role) {
      ItemRole.prompt || ItemRole.response => turn <= baseline.turn,
      // Sent only by requests after the step at [turn].
      ItemRole.output || ItemRole.note => turn < baseline.turn,
    };
    if (!covered) sum += estimate(item);
  }
  return sum;
}
