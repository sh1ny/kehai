/// Shared helpers of the login and logout tests: record builders, an output
/// sink that tests can wait on, a temporary Kehai home, and a tiny HTTP
/// client that plays the browser.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kehai/src/auth/credential_backend.dart';
import 'package:kehai/src/auth/credential_store.dart';
import 'package:kehai/src/auth/dpapi_backend.dart';
import 'package:kehai/src/auth/openai_constants.dart';
import 'package:kehai/src/auth/posix_file_backend.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The host id of seeded records.
const String seededHostId = 'urn:uuid:11111111-2222-3333-4444-555555555555';

/// A registration for [subject] and [clientId].
CredentialRegistration registrationFor({
  String clientId = 'oaiapp_fake',
  String subject = 'user-123',
  bool planUsage = true,
  String issuer = 'https://auth.openai.com',
}) => CredentialRegistration(
  issuer: issuer,
  clientId: clientId,
  subject: subject,
  email: '$subject@example.com',
  plan: 'plus',
  planUsageEnabled: planUsage,
);

/// A record of a logged-in user.
CredentialRecord loggedInRecord({
  int generation = 3,
  String accessToken = 'stored-access-token',
  String refreshToken = 'stored-refresh-token',
  String idToken = 'stored-id-token',
  String clientId = 'oaiapp_fake',
  String subject = 'user-123',
  Duration expiresIn = const Duration(hours: 1),
}) {
  final now = DateTime.now().toUtc();
  return CredentialRecord(
    hostId: seededHostId,
    generation: generation,
    registration: registrationFor(clientId: clientId, subject: subject),
    tokens: CredentialTokens(
      idToken: idToken,
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: now.add(expiresIn),
      scopes: const ['openid', 'offline_access', openAiPlanUsageScope],
      savedAt: now.subtract(const Duration(days: 1)),
      lastRefresh: now.subtract(const Duration(hours: 1)),
    ),
  );
}

/// A record with a registration and no token set.
CredentialRecord tokenlessRecord({
  int generation = 3,
  bool planUsage = false,
  String clientId = 'oaiapp_fake',
  String subject = 'user-123',
}) => CredentialRecord(
  hostId: seededHostId,
  generation: generation,
  registration: registrationFor(
    clientId: clientId,
    subject: subject,
    planUsage: planUsage,
  ),
);

/// A record holding only the host id.
CredentialRecord hostOnlyRecord({int generation = 0}) =>
    CredentialRecord(hostId: seededHostId, generation: generation);

/// A [StringSink] that records everything and lets a test wait for output.
final class TestSink implements StringSink {
  final StringBuffer _buffer = StringBuffer();

  /// Everything written so far.
  String get text => _buffer.toString();

  /// The lines written so far.
  List<String> get lines => const LineSplitter().convert(text);

  /// Completes when [test] holds for the accumulated text.
  Future<void> until(
    bool Function(String text) test, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!test(text)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for output; got:\n$text');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Waits until a line that is an `http` URL was written and returns it.
  Future<String> authorizeUrl() async {
    await until((text) => lines.any((line) => line.startsWith('http')));
    return lines.firstWhere((line) => line.startsWith('http'));
  }

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);
}

/// A credential backend that reports every write before delegating.
final class HookedBackend implements CredentialBackend {
  /// Wraps the platform backend.
  HookedBackend()
    : _inner = Platform.isWindows ? DpapiBackend() : PosixFileBackend();

  final CredentialBackend _inner;

  /// Called with the plaintext of each write, before it is stored.
  void Function(String plaintext)? onWrite;

  @override
  String get fileName => _inner.fileName;

  @override
  String? resolveHome(String home, {required bool create}) =>
      _inner.resolveHome(home, create: create);

  @override
  Uint8List? read(String dir) => _inner.read(dir);

  @override
  void write(String dir, Uint8List plaintext) {
    onWrite?.call(utf8.decode(plaintext));
    _inner.write(dir, plaintext);
  }
}

/// A Kehai home under a fresh temporary directory, with a store whose lock can
/// be held artificially.
final class TestHome {
  /// Creates the directory and a store over [name] inside it.
  TestHome({String name = 'home', CredentialBackend? backend}) {
    root = Directory.systemTemp.createTempSync('kehai_login_');
    if (!Platform.isWindows) Process.runSync('chmod', ['700', root.path]);
    path = p.join(root.path, name);
    store = CredentialStore(
      home: path,
      backend: backend,
      lockPollInterval: const Duration(milliseconds: 20),
      tryLock: (file) {
        if (lockHeld) return false;
        try {
          file.lockSync(FileLock.exclusive);
          return true;
        } on FileSystemException {
          return false;
        }
      },
    );
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
  }

  /// The temporary directory holding the home.
  late final Directory root;

  /// The Kehai home path.
  late final String path;

  /// The store over [path].
  late final CredentialStore store;

  /// While `true`, every lock attempt fails, as if another process held it.
  bool lockHeld = false;
}

/// Returns a loopback port that was free a moment ago.
Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// Whether [port] can currently be bound on loopback.
Future<bool> portIsFree(int port) async {
  try {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

/// Binds a listening socket that counts connections, to play another process
/// holding a port.
final class PortHolder {
  PortHolder._(this._socket) {
    _socket.listen((connection) {
      connections++;
      connection.destroy();
    });
  }

  /// Holds a fresh ephemeral loopback port.
  static Future<PortHolder> hold() async {
    final holder = PortHolder._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    addTearDown(holder.release);
    return holder;
  }

  final ServerSocket _socket;

  /// How many connections the holder received.
  int connections = 0;

  /// The held port.
  int get port => _socket.port;

  /// Stops holding the port.
  Future<void> release() async {
    try {
      await _socket.close();
    } on Object {
      // Already closed.
    }
  }
}

/// A browser reduced to `GET`: follows redirects and returns the final status
/// and body.
Future<(int, String)> getPage(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    return (response.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

/// Requests the authorize [url] without following the redirect and returns the
/// callback URL the auth server redirected to.
Future<String> callbackUrlFor(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.followRedirects = false;
    final response = await request.close();
    await response.drain<void>();
    final location = response.headers.value('location');
    expect(location, isNotNull, reason: 'the authorize endpoint redirects');
    return location!;
  } finally {
    client.close(force: true);
  }
}
