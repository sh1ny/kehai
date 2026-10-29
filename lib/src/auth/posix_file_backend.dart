/// The Linux and macOS credential backend: a private `auth.json` file.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'credential_backend.dart';
import 'credential_error.dart';
import 'home_trust.dart';
import 'posix_ffi.dart';

const int _groupOtherBits = 63; // 0077

int _tempCounter = 0;

String _octal(int mode) => '0${(mode & 4095).toRadixString(8).padLeft(3, '0')}';

CredentialStoreError _unsafe(String detail) =>
    CredentialStoreError(CredentialStoreError.unsafePath, detail);

/// Stores the record as `auth.json` with mode `0600` in a `0700` home.
///
/// The home is validated by [HomeTrust] before anything is read, written or
/// locked. Before every load and store the home and the file are checked
/// again for links, type and group or other permission bits. A write creates
/// a temporary file through libc `open` with `O_CREAT|O_EXCL` and mode
/// `0600`, writes and `fsync`s it, then renames it over `auth.json`.
final class PosixFileBackend implements CredentialBackend {
  /// Creates the backend.
  ///
  /// [trust] defaults to the production libc checker. [createPrivateFile]
  /// replaces the exclusive `0600` file creation and [beforeRename] runs after
  /// the temporary file is complete and before it is renamed; both exist for
  /// fault injection in tests.
  PosixFileBackend({
    HomeTrust? trust,
    void Function(String path, Uint8List bytes)? createPrivateFile,
    this._beforeRename,
  }) : _trust = trust ?? HomeTrust(),
       _createPrivateFile =
           createPrivateFile ?? PosixLibc.instance.createPrivateFile;

  final HomeTrust _trust;
  final void Function(String path, Uint8List bytes) _createPrivateFile;
  final void Function()? _beforeRename;

  @override
  String get fileName => 'auth.json';

  @override
  String? resolveHome(String home, {required bool create}) =>
      _trust.resolve(home, create: create);

  @override
  void checkHome(String dir) => _validateLayout(dir);

  /// Checks the home and the credential file; returns whether the file exists.
  bool _validateLayout(String dir) {
    if (FileSystemEntity.typeSync(dir, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw _unsafe('Kehai home "$dir" is not a real directory');
    }
    final homeMode = FileStat.statSync(dir).mode;
    if ((homeMode & _groupOtherBits) != 0) {
      throw _unsafe(
        'Kehai home "$dir" has mode ${_octal(homeMode)}, which allows group '
        'or other access; run chmod 700',
      );
    }
    final path = p.join(dir, fileName);
    switch (FileSystemEntity.typeSync(path, followLinks: false)) {
      case FileSystemEntityType.notFound:
        return false;
      case FileSystemEntityType.file:
        final mode = FileStat.statSync(path).mode;
        if ((mode & _groupOtherBits) != 0) {
          throw _unsafe(
            '"$path" has mode ${_octal(mode)}, which allows group or other '
            'access; run chmod 600 "$path"',
          );
        }
        return true;
      case FileSystemEntityType.link:
        throw _unsafe('"$path" is a symbolic link');
      default:
        throw _unsafe('"$path" is not a regular file');
    }
  }

  @override
  Uint8List? read(String dir) {
    if (!_validateLayout(dir)) return null;
    try {
      return File(p.join(dir, fileName)).readAsBytesSync();
    } on FileSystemException catch (e) {
      throw CredentialStoreError(
        CredentialStoreError.unreadable,
        'cannot read "${p.join(dir, fileName)}": ${e.osError?.message ?? e.message}',
      );
    }
  }

  @override
  void write(String dir, Uint8List plaintext) {
    _validateLayout(dir);
    final temp = File(p.join(dir, '$fileName.${pid}_${_tempCounter++}.tmp'));
    try {
      _createPrivateFile(temp.path, plaintext);
      _beforeRename?.call();
      temp.renameSync(p.join(dir, fileName));
    } on Object {
      try {
        if (temp.existsSync()) temp.deleteSync();
      } on FileSystemException {
        // Nothing more can be done; the file was created with mode 0600.
      }
      rethrow;
    }
  }
}
