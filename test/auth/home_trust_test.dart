import 'dart:io';

import 'package:kehai/src/auth/credential_error.dart';
import 'package:kehai/src/auth/credential_store.dart';
import 'package:kehai/src/auth/home_trust.dart';
import 'package:kehai/src/auth/posix_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const int _me = 1000;
const int _other = 2000;
const int _sticky = 512; // 01000

/// A fake file system tree driven through the injected seams.
final class _Fake {
  _Fake(Map<String, StatInfo> entries) : _entries = Map.of(entries);

  final Map<String, StatInfo> _entries;
  final Set<String> links = {};
  final Map<String, String> canonical = {};
  final List<String> created = [];

  HomeTrustSeams seams({int euid = _me}) => HomeTrustSeams(
    stat: (path) {
      final info = _entries[path];
      if (info == null) {
        throw CredentialStoreError(CredentialStoreError.unsafePath, path);
      }
      return info;
    },
    euid: () => euid,
    canonicalize: (path) => canonical[path] ?? path,
    isLink: links.contains,
    exists: (path) => _entries.containsKey(path),
    makeDir: (path) {
      created.add(path);
      _entries[path] = const StatInfo(_me, 0x4000 | 448);
    },
  );
}

StatInfo _dir(int uid, int perms) => StatInfo(uid, 0x4000 | perms);

Matcher _trustError(String text) => isA<CredentialStoreError>().having(
  (e) => e.message,
  'message',
  contains(text),
);

_Fake _tree({
  int parentUid = _me,
  int parentPerms = 493, // 0755
  int homeUid = _me,
}) => _Fake({
  '/': _dir(0, 493),
  '/srv': _dir(0, 493),
  '/srv/shared': _dir(parentUid, parentPerms),
  '/srv/shared/kehai': _dir(homeUid, 448),
});

void main() {
  const home = '/srv/shared/kehai';

  group('trusted home path', () {
    test(
      'writable non-sticky parent is rejected before any access or lock',
      () {
        final fake = _tree(parentPerms: 511); // 0777
        final trust = HomeTrust(fake.seams());
        expect(
          () => trust.resolve(home, create: true),
          throwsA(_trustError('"/srv/shared"')),
        );
        expect(
          () => trust.resolve(home, create: true),
          throwsA(_trustError('0777')),
        );
        expect(fake.created, isEmpty);
      },
    );

    test('group-writable parent is rejected too', () {
      final fake = _tree(parentPerms: 504); // 0770
      expect(
        () => HomeTrust(fake.seams()).resolve(home),
        throwsA(_trustError('0770')),
      );
    });

    test('root-owned sticky world-writable ancestor is accepted', () {
      final fake = _tree(parentUid: 0, parentPerms: _sticky | 511);
      expect(HomeTrust(fake.seams()).resolve(home), home);
    });

    test('ancestor owned by another user is rejected even at 0755', () {
      final fake = _tree(parentUid: _other);
      expect(
        () => HomeTrust(fake.seams()).resolve(home),
        throwsA(
          isA<CredentialStoreError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"/srv/shared"'), contains('uid $_other')),
          ),
        ),
      );
    });

    test('sticky ancestor owned by another user is rejected', () {
      final fake = _tree(parentUid: _other, parentPerms: _sticky | 511);
      expect(
        () => HomeTrust(fake.seams()).resolve(home),
        throwsA(_trustError('uid $_other')),
      );
    });

    test('home owned by another user is rejected', () {
      final fake = _tree(homeUid: _other);
      expect(
        () => HomeTrust(fake.seams()).resolve(home),
        throwsA(
          isA<CredentialStoreError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"$home"'), contains('uid $_other')),
          ),
        ),
      );
    });

    test('a symlinked home is rejected before canonicalization', () {
      final fake = _tree()..links.add(home);
      expect(
        () => HomeTrust(fake.seams()).resolve(home),
        throwsA(_trustError('symbolic link')),
      );
    });

    test('a missing home is created only beneath a trusted parent', () {
      final fake = _Fake({
        '/': _dir(0, 493),
        '/srv': _dir(0, 493),
        '/srv/shared': _dir(_me, 493),
      });
      expect(HomeTrust(fake.seams()).resolve(home), isNull);
      expect(fake.created, isEmpty);
      expect(HomeTrust(fake.seams()).resolve(home, create: true), home);
      expect(fake.created, [home]);

      final bad = _Fake({
        '/': _dir(0, 493),
        '/srv': _dir(0, 493),
        '/srv/shared': _dir(_me, 511),
      });
      expect(
        () => HomeTrust(bad.seams()).resolve(home, create: true),
        throwsA(_trustError('0777')),
      );
      expect(bad.created, isEmpty);
    });

    test('root may own its own home', () {
      final fake = _tree(parentUid: 0, homeUid: 0);
      expect(HomeTrust(fake.seams(euid: 0)).resolve(home), home);
    });
  });

  group('real libc seam', () {
    final skip = Platform.isWindows ? 'unix only' : false;

    test('[unix] FFI st_mode and st_uid agree with the OS', () {
      final dir = Directory.systemTemp.createTempSync('kehai_stat_');
      addTearDown(() => dir.deleteSync(recursive: true));
      Process.runSync('chmod', ['750', dir.path]);
      final info = PosixLibc.instance.statUnvalidated(dir.path);
      expect(info.mode & 4095, FileStat.statSync(dir.path).mode & 4095);
      expect(info.mode & 4095, 488); // 0750
      final id = Process.runSync('id', ['-u']).stdout.toString().trim();
      expect(info.uid, int.parse(id));
      expect(PosixLibc.instance.euid, int.parse(id));
      expect(PosixLibc.instance.stat(dir.path).mode, info.mode);
    }, skip: skip);

    test(
      '[unix] symlinked ancestor resolves to canonical path used for file and '
      'lock',
      () async {
        final root = Directory.systemTemp.createTempSync('kehai_link_');
        addTearDown(() => root.deleteSync(recursive: true));
        final real = Directory(p.join(root.path, 'real'))..createSync();
        Process.runSync('chmod', ['700', real.path]);
        Link(p.join(root.path, 'link')).createSync(real.path);
        final viaLink = p.join(root.path, 'link', 'home');
        final resolved = HomeTrust(HomeTrustSeams.production())
            .resolve(viaLink, create: true);
        final canonical = p.join(real.resolveSymbolicLinksSync(), 'home');
        expect(resolved, canonical);
        expect(FileStat.statSync(canonical).mode & 4095, 448);

        final store = CredentialStore(home: viaLink);
        store.replace(
          const CredentialRecord(hostId: 'urn:uuid:x', generation: 1),
        );
        final lock = await store.acquireLock();
        lock.release();
        expect(File(p.join(canonical, 'auth.json')).existsSync(), isTrue);
        expect(File(p.join(canonical, 'auth.lock')).existsSync(), isTrue);
        expect(store.load()!.hostId, 'urn:uuid:x');
      },
      skip: skip,
    );
  });
}
