/// The credential record, store and cross-process lock (design D5, D6).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'credential_backend.dart';
import 'credential_error.dart';
import 'dpapi_backend.dart';
import 'openai_constants.dart';
import 'posix_file_backend.dart';

/// The lock file name inside the Kehai home.
const String credentialLockFileName = 'auth.lock';

CredentialStoreError _bad(String what) => CredentialStoreError(
  CredentialStoreError.unreadable,
  'the stored record is malformed: $what',
);

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw _bad('"$key" must be a non-empty string');
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is String) return value;
  throw _bad('"$key" must be a string');
}

DateTime _date(Map<String, Object?> json, String key) {
  final text = _string(json, key);
  final parsed = DateTime.tryParse(text);
  if (parsed == null || !parsed.isUtc) {
    throw _bad('"$key" must be an ISO-8601 UTC time');
  }
  return parsed;
}

Map<String, Object?> _object(Object? value, String what) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw _bad('$what must be an object');
}

/// The client registration held in a [CredentialRecord].
final class CredentialRegistration {
  /// Creates a registration.
  const CredentialRegistration({
    required this.issuer,
    required this.clientId,
    required this.subject,
    required this.email,
    required this.planUsageEnabled,
    this.plan,
  });

  /// Decodes a registration from its `registration` JSON object.
  ///
  /// Throws a `CredentialStoreError` with reason `credentials unreadable` when
  /// a field is missing or has the wrong type.
  factory CredentialRegistration.fromJson(Map<String, Object?> json) {
    final usage = json['plan_usage'];
    if (usage != 'enabled' && usage != 'disabled') {
      throw _bad('"plan_usage" must be "enabled" or "disabled"');
    }
    return CredentialRegistration(
      issuer: _string(json, 'issuer'),
      clientId: _string(json, 'client_id'),
      subject: _string(json, 'subject'),
      email: _string(json, 'email'),
      plan: _optionalString(json, 'plan'),
      planUsageEnabled: usage == 'enabled',
    );
  }

  /// The OpenID issuer.
  final String issuer;

  /// The issued client id.
  final String clientId;

  /// The account subject.
  final String subject;

  /// The account email.
  final String email;

  /// The ChatGPT plan name, if known.
  final String? plan;

  /// Whether plan usage is enabled (`plan_usage` is `enabled`).
  final bool planUsageEnabled;

  /// Encodes this registration as JSON.
  Map<String, Object?> toJson() => {
    'issuer': issuer,
    'client_id': clientId,
    'subject': subject,
    'email': email,
    if (plan != null) 'plan': plan,
    'plan_usage': planUsageEnabled ? 'enabled' : 'disabled',
  };

  @override
  bool operator ==(Object other) =>
      other is CredentialRegistration &&
      other.issuer == issuer &&
      other.clientId == clientId &&
      other.subject == subject &&
      other.email == email &&
      other.plan == plan &&
      other.planUsageEnabled == planUsageEnabled;

  @override
  int get hashCode =>
      Object.hash(issuer, clientId, subject, email, plan, planUsageEnabled);
}

/// The token set held in a [CredentialRecord].
final class CredentialTokens {
  /// Creates a token set.
  const CredentialTokens({
    required this.idToken,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.scopes,
    required this.savedAt,
    required this.lastRefresh,
  });

  /// Decodes a token set from its `tokens` JSON object.
  ///
  /// Throws a `CredentialStoreError` with reason `credentials unreadable` when
  /// a field is missing or has the wrong type.
  factory CredentialTokens.fromJson(Map<String, Object?> json) {
    final scopes = json['scopes'];
    if (scopes is! List || scopes.any((s) => s is! String)) {
      throw _bad('"scopes" must be a list of strings');
    }
    return CredentialTokens(
      idToken: _string(json, 'id_token'),
      accessToken: _string(json, 'access_token'),
      refreshToken: _string(json, 'refresh_token'),
      expiresAt: _date(json, 'expires_at'),
      scopes: List.unmodifiable(scopes.cast<String>()),
      savedAt: _date(json, 'saved_at'),
      lastRefresh: _date(json, 'last_refresh'),
    );
  }

  /// The ID token.
  final String idToken;

  /// The access token.
  final String accessToken;

  /// The refresh token.
  final String refreshToken;

  /// When the access token expires, in UTC.
  final DateTime expiresAt;

  /// The granted scopes.
  final List<String> scopes;

  /// When the set was first saved by a login, in UTC.
  final DateTime savedAt;

  /// When the set was last refreshed, in UTC.
  final DateTime lastRefresh;

  /// Encodes this token set as JSON.
  Map<String, Object?> toJson() => {
    'id_token': idToken,
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt.toUtc().toIso8601String(),
    'scopes': scopes,
    'saved_at': savedAt.toUtc().toIso8601String(),
    'last_refresh': lastRefresh.toUtc().toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is CredentialTokens &&
      other.idToken == idToken &&
      other.accessToken == accessToken &&
      other.refreshToken == refreshToken &&
      other.expiresAt == expiresAt &&
      _sameList(other.scopes, scopes) &&
      other.savedAt == savedAt &&
      other.lastRefresh == lastRefresh;

  @override
  int get hashCode => Object.hash(
    idToken,
    accessToken,
    refreshToken,
    expiresAt,
    Object.hashAll(scopes),
    savedAt,
    lastRefresh,
  );

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The stored credential record, format version 1.
final class CredentialRecord {
  /// Creates a record.
  const CredentialRecord({
    required this.hostId,
    required this.generation,
    this.registration,
    this.tokens,
  });

  /// Decodes a record from parsed JSON.
  ///
  /// Throws a `CredentialStoreError` with reason `credentials unreadable` for
  /// an unknown version or provider, a malformed field, or a token set stored
  /// without a registration whose plan usage is enabled.
  factory CredentialRecord.fromJson(Object? json) {
    final map = _object(json, 'the record');
    if (map['version'] != version) {
      throw _bad('unsupported version');
    }
    if (map['provider'] != 'openai') throw _bad('unsupported provider');
    final generation = map['generation'];
    if (generation is! int || generation < 0) {
      throw _bad('"generation" must be a non-negative integer');
    }
    final registrationJson = map['registration'];
    final tokensJson = map['tokens'];
    final registration = registrationJson == null
        ? null
        : CredentialRegistration.fromJson(
            _object(registrationJson, '"registration"'),
          );
    final tokens = tokensJson == null
        ? null
        : CredentialTokens.fromJson(_object(tokensJson, '"tokens"'));
    if (tokens != null && !(registration?.planUsageEnabled ?? false)) {
      throw _bad('tokens are present without plan usage enabled');
    }
    return CredentialRecord(
      hostId: _string(map, 'host_id'),
      generation: generation,
      registration: registration,
      tokens: tokens,
    );
  }

  /// The format version written by this build.
  static const int version = 1;

  /// The persisted host id.
  final String hostId;

  /// The generation, advanced by login, logout and forget but not refresh.
  final int generation;

  /// The client registration, if one is held.
  final CredentialRegistration? registration;

  /// The token set, present only while the user is logged in.
  ///
  /// Present only when [registration] has plan usage enabled.
  final CredentialTokens? tokens;

  /// Encodes this record as JSON.
  Map<String, Object?> toJson() => {
    'version': version,
    'provider': 'openai',
    'host_id': hostId,
    'generation': generation,
    if (registration != null) 'registration': registration!.toJson(),
    if (tokens != null) 'tokens': tokens!.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is CredentialRecord &&
      other.hostId == hostId &&
      other.generation == generation &&
      other.registration == registration &&
      other.tokens == tokens;

  @override
  int get hashCode => Object.hash(hostId, generation, registration, tokens);
}

/// A held `auth.lock`.
final class CredentialLock {
  CredentialLock._(this._file);

  RandomAccessFile? _file;

  /// Releases the lock. Safe to call more than once.
  void release() {
    final file = _file;
    if (file == null) return;
    _file = null;
    try {
      file.unlockSync();
    } finally {
      file.closeSync();
    }
  }
}

bool _lockExclusiveNonBlocking(RandomAccessFile file) {
  try {
    file.lockSync(FileLock.exclusive);
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Loads and replaces the credential record in one Kehai home.
///
/// A caller that reads in order to replace (login, refresh, logout) acquires
/// [acquireLock] first, then calls [load], computes, calls [replace], and
/// releases the lock. A caller that only reads needs no lock, because a
/// replace is atomic.
final class CredentialStore {
  /// Creates a store for [home].
  ///
  /// [backend] defaults to DPAPI on Windows and the private file elsewhere.
  /// [lockPollInterval] and [lockDeadline] default to the design D5 values.
  /// [tryLock] attempts a non-blocking exclusive lock and returns whether it
  /// was taken; tests inject it to simulate a holder in the same process.
  CredentialStore({
    required this.home,
    CredentialBackend? backend,
    this.lockPollInterval = openAiLockPollInterval,
    this.lockDeadline = openAiLockDeadline,
    bool Function(RandomAccessFile file)? tryLock,
  }) : _backend =
           backend ??
           (Platform.isWindows ? DpapiBackend() : PosixFileBackend()),
       _tryLock = tryLock ?? _lockExclusiveNonBlocking;

  /// The Kehai home as configured, before canonicalization.
  final String home;

  /// The interval between lock attempts.
  final Duration lockPollInterval;

  /// How long [acquireLock] waits before failing with `credential lock busy`.
  final Duration lockDeadline;

  final CredentialBackend _backend;
  final bool Function(RandomAccessFile file) _tryLock;

  /// Loads the record, or returns `null` when none is stored.
  ///
  /// Throws a `CredentialStoreError` when the home, the file or its contents
  /// are unsafe or unreadable.
  CredentialRecord? load() {
    final dir = _backend.resolveHome(home, create: false);
    if (dir == null) return null;
    final bytes = _backend.read(dir);
    if (bytes == null) return null;
    try {
      return CredentialRecord.fromJson(jsonDecode(utf8.decode(bytes)));
    } on FormatException {
      throw _bad('the content is not valid JSON');
    }
  }

  /// Atomically replaces the stored record with [record].
  ///
  /// Throws a `CredentialStoreError` when the secure write is unavailable. The
  /// previous record then remains and no file is left behind.
  void replace(CredentialRecord record) {
    final registration = record.registration;
    if (record.tokens != null && !(registration?.planUsageEnabled ?? false)) {
      throw ArgumentError.value(
        record,
        'record',
        'tokens require a registration with plan usage enabled',
      );
    }
    final dir = _backend.resolveHome(home, create: true)!;
    _backend.write(dir, Uint8List.fromList(utf8.encode(jsonEncode(record))));
  }

  /// Acquires the exclusive `auth.lock` in the canonical home.
  ///
  /// The home is validated before the lock file is created. Attempts repeat
  /// every [lockPollInterval] until [lockDeadline], then this throws
  /// `credential lock busy`. [isCancelled], checked before each attempt, ends
  /// the wait with `credential lock cancelled`; it is the hook the
  /// cancellation token is wired to later.
  Future<CredentialLock> acquireLock({bool Function()? isCancelled}) async {
    final dir = _backend.resolveHome(home, create: true)!;
    final file = File(p.join(dir, credentialLockFileName))
        .openSync(mode: FileMode.append);
    final watch = Stopwatch()..start();
    try {
      while (true) {
        if (isCancelled?.call() ?? false) {
          throw const CredentialStoreError(
            CredentialStoreError.cancelled,
            'cancelled while waiting for the credential lock',
          );
        }
        if (_tryLock(file)) return CredentialLock._(file);
        if (watch.elapsed >= lockDeadline) {
          throw CredentialStoreError(
            CredentialStoreError.lockBusy,
            'another Kehai process held the credential lock for '
            '${lockDeadline.inMilliseconds} ms',
          );
        }
        await Future<void>.delayed(lockPollInterval);
      }
    } on Object {
      file.closeSync();
      rethrow;
    }
  }
}
