/// Single-writer ownership of a session directory.
///
/// Three files serialize and prove ownership: `session.owner` names the
/// writer, `session.gate` serializes every ownership change, and
/// `session.lock` carries an operating system lock used only to learn whether
/// a foreign owner is still alive.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'journal.dart';

/// The file holding the operating system lock that proves a writer is alive.
const String lockFileName = 'session.lock';

/// The file that serializes every ownership change.
const String gateFileName = 'session.gate';

/// How long a claim or release retries a busy gate.
const Duration defaultGateWait = Duration(seconds: 2);

/// A callback that may suspend a claim or release at a named point.
///
/// The points are `gate-busy` (each failed attempt to create the gate),
/// `gate-created` (the gate exists but is still empty), `owner-read` (the
/// owner record was read, the gate is held) and `lock-closed` (a release
/// closed its lock handle and has not yet taken the gate).
typedef OwnershipPause = Future<void> Function(String point);

/// Test hooks that let a caller interleave ownership changes deterministically.
final class OwnershipHooks {
  /// Creates hooks that call [pause] at each named point.
  const OwnershipHooks({this.pause});

  /// Called at each named point; the protocol continues when it completes.
  final OwnershipPause? pause;
}

/// A claim that replaced the owner record of a dead process.
final class Takeover {
  /// Creates a takeover report for the replaced owner.
  const Takeover({
    required this.previousPid,
    this.previousNonce,
    this.previousStartedUtc,
  });

  /// The process id in the replaced record, or `null` if it was unreadable.
  final int? previousPid;

  /// The nonce in the replaced record, if it was readable.
  final String? previousNonce;

  /// The start time in the replaced record, if it was readable.
  final String? previousStartedUtc;

  /// A readable description of the takeover.
  String get message =>
      'replaced the owner record of dead process ${previousPid ?? 'unknown'}'
      '${previousStartedUtc == null ? '' : ' started $previousStartedUtc'}';

  @override
  String toString() => 'Takeover: $message';
}

/// The right to write one session directory, held until [release].
final class Ownership {
  Ownership._(this._dir, this._nonce, this._lock, this._hooks, this.takeover);

  final Directory _dir;
  final String _nonce;
  RandomAccessFile? _lock;
  final OwnershipHooks? _hooks;
  Future<void>? _released;

  /// The takeover this claim performed, or `null` for a clean claim.
  final Takeover? takeover;

  /// Claims the session in [dir] for this writer.
  ///
  /// Throws a [SessionError] with reason `session locked` when another writer
  /// holds the session, or `session gate held by pid <p>` when the gate stays
  /// busy for longer than [gateWait].
  static Future<Ownership> claim(
    Directory dir, {
    OwnershipHooks? hooks,
    Duration gateWait = defaultGateWait,
  }) async {
    final gate = await _Gate.acquire(dir, hooks, gateWait);
    try {
      final owner = _readOwner(dir);
      await hooks?.pause?.call('owner-read');
      final nonce = _newNonce();
      if (owner == null) {
        _writeOwner(dir, nonce);
        final RandomAccessFile handle;
        try {
          handle = _lockLiveness(dir);
        } on FileSystemException {
          _deleteOwnerFile(dir);
          throw _locked(dir, null);
        }
        return Ownership._(dir, nonce, handle, hooks, null);
      }
      if (owner.pid == pid) {
        throw _locked(
          dir,
          owner.pid,
          hint:
              ' (if no kehai is running, remove '
              '${p.join(dir.path, ownerFileName)})',
        );
      }
      final RandomAccessFile handle;
      try {
        handle = _lockLiveness(dir);
      } on FileSystemException {
        throw _locked(dir, owner.pid);
      }
      try {
        _writeOwner(dir, nonce);
      } on Object {
        handle.closeSync();
        rethrow;
      }
      return Ownership._(
        dir,
        nonce,
        handle,
        hooks,
        Takeover(
          previousPid: owner.pid,
          previousNonce: owner.nonce,
          previousStartedUtc: owner.startedUtc,
        ),
      );
    } finally {
      gate.release();
    }
  }

  /// Releases the session: closes the liveness lock, then deletes the owner
  /// record under the gate if it still names this writer.
  ///
  /// Throws a [SessionError] when the gate cannot be acquired; the owner
  /// record then stays in place.
  Future<void> release() => _released ??= _release();

  Future<void> _release() async {
    try {
      _lock?.closeSync();
    } on FileSystemException {
      // The handle is gone either way.
    }
    _lock = null;
    await _hooks?.pause?.call('lock-closed');
    final gate = await _Gate.acquire(_dir, _hooks, defaultGateWait);
    try {
      final owner = _readOwner(_dir);
      if (owner != null && owner.pid == pid && owner.nonce == _nonce) {
        _deleteOwnerFile(_dir);
      }
    } finally {
      gate.release();
    }
  }
}

SessionError _locked(Directory dir, int? holder, {String hint = ''}) =>
    SessionError(
      'session locked',
      'session ${dir.path} is held by pid ${holder ?? 'unknown'}$hint',
    );

String _newNonce() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
}

final class _OwnerRecord {
  const _OwnerRecord(this.pid, this.nonce, this.startedUtc);

  final int? pid;
  final String? nonce;
  final String? startedUtc;
}

/// Reads `session.owner`: `null` when absent, fields `null` when unreadable.
_OwnerRecord? _readOwner(Directory dir) {
  final file = File(p.join(dir.path, ownerFileName));
  final String text;
  try {
    text = file.readAsStringSync();
  } on PathNotFoundException {
    return null;
  } on FileSystemException {
    if (!file.existsSync()) return null;
    return const _OwnerRecord(null, null, null);
  }
  try {
    if (jsonDecode(text)
        case {'pid': final int ownerPid, 'nonce': final String nonce} &&
            final Map<String, Object?> map) {
      // A timestamp of the wrong type is dropped, like any unreadable field.
      final startedUtc = map['startedUtc'];
      return _OwnerRecord(
        ownerPid,
        nonce,
        startedUtc is String ? startedUtc : null,
      );
    }
  } on FormatException {
    // Treated as unreadable below.
  }
  return const _OwnerRecord(null, null, null);
}

/// Writes the owner record as a temp file, flushes it, then renames it.
void _writeOwner(Directory dir, String nonce) {
  final temp = File(p.join(dir.path, '$ownerFileName.tmp'));
  final out = temp.openSync(mode: FileMode.write);
  try {
    out.writeStringSync(
      jsonEncode({
        'pid': pid,
        'nonce': nonce,
        'startedUtc': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    out.flushSync();
  } finally {
    out.closeSync();
  }
  temp.renameSync(p.join(dir.path, ownerFileName));
}

void _deleteOwnerFile(Directory dir) {
  final owner = File(p.join(dir.path, ownerFileName));
  if (owner.existsSync()) owner.deleteSync();
}

/// Opens `session.lock` and takes the exclusive non-blocking lock.
RandomAccessFile _lockLiveness(Directory dir) {
  final handle = File(p.join(dir.path, lockFileName))
      .openSync(mode: FileMode.append);
  try {
    handle.lockSync(FileLock.exclusive);
  } on Object {
    handle.closeSync();
    rethrow;
  }
  return handle;
}

/// The exclusive `session.gate` file, held while ownership changes.
final class _Gate {
  _Gate._(this._file);

  final File _file;

  static Future<_Gate> acquire(
    Directory dir,
    OwnershipHooks? hooks,
    Duration wait,
  ) async {
    final file = File(p.join(dir.path, gateFileName));
    final deadline = DateTime.now().add(wait);
    while (true) {
      try {
        file.createSync(exclusive: true);
        break;
      } on FileSystemException {
        if (!file.existsSync() && !dir.existsSync()) rethrow;
        await hooks?.pause?.call('gate-busy');
        if (DateTime.now().isAfter(deadline)) throw _gateHeld(file);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    final gate = _Gate._(file);
    try {
      await hooks?.pause?.call('gate-created');
      file.writeAsStringSync(
        jsonEncode({
          'pid': pid,
          'nonce': _newNonce(),
          'utc': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    } on Object {
      gate.release();
      rethrow;
    }
    return gate;
  }

  void release() {
    try {
      _file.deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }
}

SessionError _gateHeld(File gate) {
  int? holder;
  String? since;
  try {
    if (jsonDecode(gate.readAsStringSync()) case {
      'pid': final int gatePid,
      'utc': final String utc,
    }) {
      holder = gatePid;
      since = utc;
    }
  } on Object {
    // An empty, partly written or vanished gate has an unknown holder.
  }
  final hint = 'remove ${gate.path} if no kehai is running';
  return holder == null
      ? SessionError('session gate held by pid unknown', hint)
      : SessionError('session gate held by pid $holder', 'since $since; $hint');
}
