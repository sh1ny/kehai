/// Libc bindings for the Unix credential path: `stat`, `geteuid`, `chmod` and
/// exclusive private file creation.
///
/// Only the ABIs named in design D6 are supported; any other fails closed with
/// `secure credential storage unavailable`.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'credential_error.dart';

/// The owner and permission bits of one file system entry.
final class StatInfo {
  /// Creates a stat result.
  const StatInfo(this.uid, this.mode);

  /// The owning user id (`st_uid`).
  final int uid;

  /// The full `st_mode`, including the file type bits.
  final int mode;
}

/// The byte offsets of `st_mode` and `st_uid` in `struct stat` for one ABI.
final class _StatLayout {
  const _StatLayout({
    required this.symbol,
    required this.modeOffset,
    required this.modeBytes,
    required this.uidOffset,
    required this.xstatVersion,
    required this.oCreat,
    required this.oExcl,
    required this.oCloexec,
  });

  final String symbol;
  final int modeOffset;
  final int modeBytes;
  final int uidOffset;

  /// The `_STAT_VER` for `__xstat`, or -1 when `__xstat` does not apply.
  final int xstatVersion;
  final int oCreat;
  final int oExcl;
  final int oCloexec;
}

const _linuxX64 = _StatLayout(
  symbol: 'stat',
  modeOffset: 24,
  modeBytes: 4,
  uidOffset: 28,
  xstatVersion: 1,
  oCreat: 0x40,
  oExcl: 0x80,
  oCloexec: 0x80000,
);

const _linuxArm64 = _StatLayout(
  symbol: 'stat',
  modeOffset: 16,
  modeBytes: 4,
  uidOffset: 24,
  xstatVersion: 0,
  oCreat: 0x40,
  oExcl: 0x80,
  oCloexec: 0x80000,
);

const _macosX64 = _StatLayout(
  symbol: r'stat$INODE64',
  modeOffset: 4,
  modeBytes: 2,
  uidOffset: 16,
  xstatVersion: -1,
  oCreat: 0x200,
  oExcl: 0x800,
  oCloexec: 0x1000000,
);

const _macosArm64 = _StatLayout(
  symbol: 'stat',
  modeOffset: 4,
  modeBytes: 2,
  uidOffset: 16,
  xstatVersion: -1,
  oCreat: 0x200,
  oExcl: 0x800,
  oCloexec: 0x1000000,
);

const int _oWronly = 1;
const int _statBufferBytes = 512;

typedef _StatC = Int32 Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _StatD = int Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _XStatC = Int32 Function(Int32, Pointer<Utf8>, Pointer<Uint8>);
typedef _XStatD = int Function(int, Pointer<Utf8>, Pointer<Uint8>);
typedef _OpenC = Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Int32,)>);
typedef _OpenD = int Function(Pointer<Utf8>, int, int);
typedef _WriteC = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _WriteD = int Function(int, Pointer<Uint8>, int);
typedef _IntOfIntC = Int32 Function(Int32);
typedef _IntOfIntD = int Function(int);
typedef _KillC = Int32 Function(Int32, Int32);
typedef _KillD = int Function(int, int);
typedef _ChmodC = Int32 Function(Pointer<Utf8>, Uint32);
typedef _ChmodD = int Function(Pointer<Utf8>, int);
typedef _GetEuidC = Uint32 Function();
typedef _GetEuidD = int Function();
typedef _ErrnoC = Pointer<Int32> Function();
typedef _ErrnoD = Pointer<Int32> Function();

/// The libc functions Kehai calls on Linux and macOS.
final class PosixLibc {
  PosixLibc._();

  /// The shared instance.
  static final PosixLibc instance = PosixLibc._();

  _StatLayout? _layout;
  DynamicLibrary? _lib;
  _StatD? _stat;
  _XStatD? _xstat;
  bool _validated = false;
  int? _euid;

  _StatLayout _layoutOrFail() {
    final existing = _layout;
    if (existing != null) return existing;
    final found = switch (Abi.current()) {
      Abi.linuxX64 => _linuxX64,
      Abi.linuxArm64 => _linuxArm64,
      Abi.macosX64 => _macosX64,
      Abi.macosArm64 => _macosArm64,
      _ => null,
    };
    if (found == null) {
      throw CredentialStoreError(
        CredentialStoreError.unavailable,
        'no struct stat layout is known for ${Abi.current()}',
      );
    }
    return _layout = found;
  }

  DynamicLibrary get _library => _lib ??= DynamicLibrary.process();

  /// Returns the `stat` of [path] without the self-validation.
  ///
  /// Throws a [CredentialStoreError] when the ABI is unknown, when no `stat`
  /// symbol exists, or when the call fails.
  StatInfo statUnvalidated(String path) {
    final layout = _layoutOrFail();
    if (_stat == null && _xstat == null) {
      if (_library.providesSymbol(layout.symbol)) {
        _stat = _library.lookupFunction<_StatC, _StatD>(layout.symbol);
      } else if (_library.providesSymbol('__xstat') &&
          layout.xstatVersion >= 0) {
        _xstat = _library.lookupFunction<_XStatC, _XStatD>('__xstat');
      } else {
        throw const CredentialStoreError(
          CredentialStoreError.unavailable,
          'neither stat nor __xstat is available in libc',
        );
      }
    }
    return using((arena) {
      final buffer = arena<Uint8>(_statBufferBytes);
      final cPath = path.toNativeUtf8(allocator: arena);
      final stat = _stat;
      final rc = stat != null
          ? stat(cPath, buffer)
          : _xstat!(layout.xstatVersion, cPath, buffer);
      if (rc != 0) {
        throw CredentialStoreError(
          CredentialStoreError.unsafePath,
          'cannot stat "$path" (errno ${_errno()})',
        );
      }
      final data = ByteData.sublistView(buffer.asTypedList(_statBufferBytes));
      final mode = layout.modeBytes == 2
          ? data.getUint16(layout.modeOffset, Endian.host)
          : data.getUint32(layout.modeOffset, Endian.host);
      return StatInfo(data.getUint32(layout.uidOffset, Endian.host), mode);
    });
  }

  /// Returns the `stat` of [path], after checking once per process that the
  /// permission bits read through FFI equal those `dart:io` reports for the
  /// same path.
  ///
  /// A mismatch means the struct offsets are wrong for this platform, so this
  /// fails closed rather than trust a misread owner.
  StatInfo stat(String path) {
    final info = statUnvalidated(path);
    if (!_validated) {
      final dart = FileStat.statSync(path).mode & 4095;
      if ((info.mode & 4095) != dart) {
        throw CredentialStoreError(
          CredentialStoreError.unavailable,
          'struct stat self-check failed for "$path": FFI mode '
          '${(info.mode & 4095).toRadixString(8)} differs from dart:io mode '
          '${dart.toRadixString(8)}',
        );
      }
      _validated = true;
    }
    return info;
  }

  /// The effective user id of this process.
  int get euid =>
      _euid ??= _library.lookupFunction<_GetEuidC, _GetEuidD>('geteuid')();

  int _errno() {
    try {
      final name = Platform.isMacOS ? '__error' : '__errno_location';
      return _library.lookupFunction<_ErrnoC, _ErrnoD>(name)().value;
    } on Object {
      return -1;
    }
  }

  /// Sends [signal] to process [pid] through libc `kill` and returns 0, or the
  /// `errno` of the failure (`3` is `ESRCH`, no such process).
  ///
  /// A negative [pid] addresses the process group `-pid`, and signal 0 only
  /// probes whether any member exists.
  int kill(int pid, int signal) {
    final fn = _library.lookupFunction<_KillC, _KillD>('kill');
    if (fn(pid, signal) == 0) return 0;
    final errno = _errno();
    return errno > 0 ? errno : -1;
  }

  /// Sets the permission bits of [path] to [mode] through libc `chmod`.
  void chmod(String path, int mode) {
    final rc = using((arena) {
      final fn = _library.lookupFunction<_ChmodC, _ChmodD>('chmod');
      return fn(path.toNativeUtf8(allocator: arena), mode);
    });
    if (rc != 0) {
      throw CredentialStoreError(
        CredentialStoreError.unavailable,
        'chmod ${mode.toRadixString(8)} failed on "$path" (errno ${_errno()})',
      );
    }
  }

  /// Creates [path] with `O_WRONLY|O_CREAT|O_EXCL` and mode `0600`, writes
  /// [bytes], and `fsync`s it.
  ///
  /// The file is never readable by others, not even briefly. On failure the
  /// file may exist, so the caller removes it.
  void createPrivateFile(String path, Uint8List bytes) {
    final layout = _layoutOrFail();
    using((arena) {
      final open = _library.lookupFunction<_OpenC, _OpenD>('open');
      final fd = open(
        path.toNativeUtf8(allocator: arena),
        _oWronly | layout.oCreat | layout.oExcl | layout.oCloexec,
        384, // 0600
      );
      if (fd < 0) {
        throw CredentialStoreError(
          CredentialStoreError.unavailable,
          'open of "$path" with mode 0600 failed (errno ${_errno()})',
        );
      }
      final close = _library.lookupFunction<_IntOfIntC, _IntOfIntD>('close');
      try {
        final write = _library.lookupFunction<_WriteC, _WriteD>('write');
        final buffer = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
        buffer.asTypedList(bytes.length).setAll(0, bytes);
        var offset = 0;
        while (offset < bytes.length) {
          final n = write(fd, buffer + offset, bytes.length - offset);
          if (n <= 0) {
            throw CredentialStoreError(
              CredentialStoreError.unavailable,
              'write to "$path" failed (errno ${_errno()})',
            );
          }
          offset += n;
        }
        final fsync = _library.lookupFunction<_IntOfIntC, _IntOfIntD>('fsync');
        if (fsync(fd) != 0) {
          throw CredentialStoreError(
            CredentialStoreError.unavailable,
            'fsync of "$path" failed (errno ${_errno()})',
          );
        }
      } finally {
        close(fd);
      }
    });
  }
}
