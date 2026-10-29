/// The Windows credential backend: a DPAPI-protected `auth.dpapi` file.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import 'credential_backend.dart';
import 'credential_error.dart';
import 'openai_constants.dart';

/// `CRYPTPROTECT_UI_FORBIDDEN`: DPAPI must never show a prompt.
const int _cryptProtectUiForbidden = 0x1;

int _tempCounter = 0;

/// Stores the record as `auth.dpapi`, encrypted for the current user.
///
/// The file holds `CryptProtectData` output in current-user scope with
/// `CRYPTPROTECT_UI_FORBIDDEN` and a fixed entropy constant. It is written to
/// a temporary file, flushed, then renamed over `auth.dpapi`. The default home
/// sits under the user profile, so no ACL validation is made (design D6).
final class DpapiBackend implements CredentialBackend {
  /// Creates the backend.
  ///
  /// [entropy] defaults to the design constant; tests pass another to prove a
  /// blob does not decrypt under it. [protect] replaces the encryption call
  /// and [beforeRename] runs after the temporary file is written and before
  /// it is renamed; both exist for fault injection in tests.
  DpapiBackend({
    this._entropy = openAiDpapiEntropy,
    this._protect,
    this._beforeRename,
  });

  final String _entropy;
  final Uint8List Function(Uint8List plaintext)? _protect;
  final void Function()? _beforeRename;

  /// The entropy bytes: the UTF-8 text plus a terminating NUL, which makes the
  /// 15-character design constant 16 bytes.
  static Uint8List _entropyBytes(String entropy) =>
      Uint8List.fromList([...utf8.encode(entropy), 0]);

  /// Encrypts [plaintext] for the current user under [entropy].
  ///
  /// Throws a `CredentialStoreError` (`secure credential storage
  /// unavailable`) when `CryptProtectData` fails.
  static Uint8List protectBytes(Uint8List plaintext, String entropy) {
    return using((arena) {
      final input = _blob(arena, plaintext);
      final entropyBlob = _blob(arena, _entropyBytes(entropy));
      final output = arena<CRYPT_INTEGER_BLOB>();
      final result = CryptProtectData(
        input,
        null,
        entropyBlob,
        null,
        _cryptProtectUiForbidden,
        output,
      );
      _wipe(input);
      if (!result.value) {
        throw CredentialStoreError(
          CredentialStoreError.unavailable,
          'CryptProtectData failed (Win32 error ${result.error})',
        );
      }
      return _takeOutput(output);
    });
  }

  /// Decrypts [blob] under [entropy].
  ///
  /// Throws a `CredentialStoreError` (`credentials unreadable`) when
  /// `CryptUnprotectData` fails, for example under another entropy or user.
  static Uint8List unprotectBytes(Uint8List blob, String entropy) {
    return using((arena) {
      final input = _blob(arena, blob);
      final entropyBlob = _blob(arena, _entropyBytes(entropy));
      final output = arena<CRYPT_INTEGER_BLOB>();
      final result = CryptUnprotectData(
        input,
        null,
        entropyBlob,
        null,
        _cryptProtectUiForbidden,
        output,
      );
      if (!result.value) {
        throw CredentialStoreError(
          CredentialStoreError.unreadable,
          'CryptUnprotectData failed (Win32 error ${result.error})',
        );
      }
      return _takeOutput(output);
    });
  }

  static Pointer<CRYPT_INTEGER_BLOB> _blob(Arena arena, Uint8List bytes) {
    final data = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    final blob = arena<CRYPT_INTEGER_BLOB>();
    blob.ref
      ..cbData = bytes.length
      ..pbData = data;
    return blob;
  }

  static void _wipe(Pointer<CRYPT_INTEGER_BLOB> blob) {
    blob.ref.pbData
        .asTypedList(blob.ref.cbData)
        .fillRange(0, blob.ref.cbData, 0);
  }

  /// Copies the system-allocated output out, wipes it, and frees it.
  static Uint8List _takeOutput(Pointer<CRYPT_INTEGER_BLOB> output) {
    final length = output.ref.cbData;
    final data = output.ref.pbData;
    final copy = Uint8List.fromList(data.asTypedList(length));
    data.asTypedList(length).fillRange(0, length, 0);
    LocalFree(HLOCAL(data));
    return copy;
  }

  @override
  String get fileName => 'auth.dpapi';

  @override
  void checkHome(String dir) {}

  @override
  String? resolveHome(String home, {required bool create}) {
    final dir = Directory(home);
    if (!dir.existsSync()) {
      if (!create) return null;
      try {
        dir.createSync(recursive: true);
      } on FileSystemException catch (e) {
        throw CredentialStoreError(
          CredentialStoreError.unavailable,
          'cannot create the Kehai home "$home": ${e.osError?.message ?? e.message}',
        );
      }
    }
    return dir.resolveSymbolicLinksSync();
  }

  @override
  Uint8List? read(String dir) {
    final file = File(p.join(dir, fileName));
    if (!file.existsSync()) return null;
    final Uint8List blob;
    try {
      blob = file.readAsBytesSync();
    } on FileSystemException catch (e) {
      throw CredentialStoreError(
        CredentialStoreError.unreadable,
        'cannot read "${file.path}": ${e.osError?.message ?? e.message}',
      );
    }
    return unprotectBytes(blob, _entropy);
  }

  @override
  void write(String dir, Uint8List plaintext) {
    final protect = _protect;
    final blob = protect != null
        ? protect(plaintext)
        : protectBytes(plaintext, _entropy);
    final temp = File(p.join(dir, '$fileName.${pid}_${_tempCounter++}.tmp'));
    try {
      final out = temp.openSync(mode: FileMode.writeOnly);
      try {
        out.writeFromSync(blob);
        out.flushSync();
      } finally {
        out.closeSync();
      }
      _beforeRename?.call();
      temp.renameSync(p.join(dir, fileName));
    } on Object catch (error) {
      try {
        if (temp.existsSync()) temp.deleteSync();
      } on FileSystemException {
        // The temp file holds only ciphertext; leave it for a later cleanup.
      }
      if (error is FileSystemException) {
        throw CredentialStoreError(
          CredentialStoreError.unavailable,
          'cannot write "${p.join(dir, fileName)}": '
          '${error.osError?.message ?? error.message}',
        );
      }
      rethrow;
    }
  }
}
