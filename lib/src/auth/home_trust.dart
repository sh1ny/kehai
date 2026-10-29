/// Trusted credential home path (design D6).
///
/// The rule is OpenSSH's `safe_path`: the home is owned by the current user,
/// and every ancestor up to `/` is owned by root or the current user and is
/// not group or other writable, unless it is root-owned with the sticky bit.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'credential_error.dart';
import 'posix_ffi.dart';

const int _groupOtherWrite = 18; // 0022
const int _sticky = 512; // 01000
const int _permMask = 4095; // 07777

/// The injectable operating-system operations the home trust policy uses.
///
/// Tests drive ownership scenarios that need a second Unix user through
/// [stat] and [euid]. The policy itself is pure and runs on every platform.
final class HomeTrustSeams {
  /// Creates seams from explicit functions.
  const HomeTrustSeams({
    required this.stat,
    required this.euid,
    required this.canonicalize,
    required this.isLink,
    required this.exists,
    required this.makeDir,
  });

  /// Production seams backed by libc FFI and `dart:io`. Unix only.
  factory HomeTrustSeams.production() {
    final libc = PosixLibc.instance;
    return HomeTrustSeams(
      stat: libc.stat,
      euid: () => libc.euid,
      canonicalize: (path) => Directory(path).resolveSymbolicLinksSync(),
      isLink: FileSystemEntity.isLinkSync,
      exists: (path) =>
          FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound,
      makeDir: (path) {
        Directory(path).createSync(recursive: true);
        libc.chmod(path, 448); // 0700
      },
    );
  }

  /// Returns the owner and mode of a path, following links.
  final StatInfo Function(String path) stat;

  /// Returns the effective user id.
  final int Function() euid;

  /// Resolves symbolic links to a canonical absolute path.
  final String Function(String path) canonicalize;

  /// Whether the path itself is a symbolic link.
  final bool Function(String path) isLink;

  /// Whether the path exists, following links.
  final bool Function(String path) exists;

  /// Creates a directory and its parents, with mode `0700` on the last one.
  final void Function(String path) makeDir;
}

/// Validates the Kehai home and every ancestor.
///
/// Paths are walked with POSIX semantics because the check applies to Unix
/// only.
final class HomeTrust {
  /// Creates a checker over [seams], or the production seams when omitted.
  HomeTrust([HomeTrustSeams? seams]) : _seams = seams;

  HomeTrustSeams? _seams;

  HomeTrustSeams get _s => _seams ??= HomeTrustSeams.production();

  static final p.Context _posix = p.posix;

  /// Returns the canonical trusted path of [home], or `null` when it does not
  /// exist and [create] is `false`.
  ///
  /// The home's own final component must not be a symbolic link; symlinked
  /// ancestors are allowed and resolved. Nothing is created or touched until
  /// the nearest existing ancestor has passed the ancestor rule. Throws a
  /// [CredentialStoreError] naming the offending component, its owner uid and
  /// its mode.
  String? resolve(String home, {bool create = false}) {
    final s = _s;
    if (s.isLink(home)) {
      throw CredentialStoreError(
        CredentialStoreError.unsafePath,
        'Kehai home "$home" is a symbolic link',
      );
    }
    if (s.exists(home)) return _validateExisting(s.canonicalize(home), s);
    if (!create) return null;

    var anchor = _posix.dirname(home);
    while (!s.exists(anchor) && _posix.dirname(anchor) != anchor) {
      anchor = _posix.dirname(anchor);
    }
    final canonicalAnchor = s.canonicalize(anchor);
    _checkAncestors(canonicalAnchor, s);
    final remainder = _posix.relative(home, from: anchor);
    s.makeDir(_posix.join(canonicalAnchor, remainder));
    return _validateExisting(s.canonicalize(home), s);
  }

  String _validateExisting(String canonical, HomeTrustSeams s) {
    final info = s.stat(canonical);
    if (info.uid != s.euid()) {
      throw CredentialStoreError(
        CredentialStoreError.unsafePath,
        'Kehai home "$canonical" is owned by uid ${info.uid}, not the '
        'current user (uid ${s.euid()}); mode ${_octal(info.mode)}',
      );
    }
    final parent = _posix.dirname(canonical);
    if (parent != canonical) _checkAncestors(parent, s);
    return canonical;
  }

  /// Checks [start] and every directory above it.
  void _checkAncestors(String start, HomeTrustSeams s) {
    final me = s.euid();
    var dir = start;
    while (true) {
      final info = s.stat(dir);
      if (info.uid != 0 && info.uid != me) {
        throw CredentialStoreError(
          CredentialStoreError.unsafePath,
          'ancestor "$dir" of the Kehai home is owned by uid ${info.uid}; '
          'mode ${_octal(info.mode)}. It must be owned by root or the '
          'current user (uid $me)',
        );
      }
      final writable = (info.mode & _groupOtherWrite) != 0;
      final stickyRoot = info.uid == 0 && (info.mode & _sticky) != 0;
      if (writable && !stickyRoot) {
        throw CredentialStoreError(
          CredentialStoreError.unsafePath,
          'ancestor "$dir" of the Kehai home is writable by group or others '
          '(uid ${info.uid}, mode ${_octal(info.mode)}) and is not a '
          'root-owned sticky directory',
        );
      }
      final parent = _posix.dirname(dir);
      if (parent == dir) return;
      dir = parent;
    }
  }

  static String _octal(int mode) =>
      '0${(mode & _permMask).toRadixString(8).padLeft(3, '0')}';
}
