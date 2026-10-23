import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'workspace.dart';

String controlPath(DmcPaths paths, String name) =>
    paths.validateInternalPath(p.join(paths.dmcPath, name));

void writeControlJson(DmcPaths paths, String name, Map<String, Object?> value) {
  final file = File(controlPath(paths, name));
  final temporary = File(controlPath(paths, '$name.tmp'));
  temporary.writeAsStringSync(jsonEncode(value), flush: true);
  temporary.renameSync(file.path);
}

Map<String, dynamic>? readControlJson(DmcPaths paths, String name) {
  final file = File(controlPath(paths, name));
  if (!file.existsSync()) return null;
  final value = jsonDecode(file.readAsStringSync());
  if (value is! Map<String, dynamic>) throw FormatException('Invalid $name');
  return value;
}

void checkLegacyWatcher(DmcPaths paths) {
  if (paths.daemonPidFile.existsSync() &&
      readControlJson(paths, 'watcher-control.json') == null) {
    throw StateError(
      'Legacy watcher metadata found. Stop the older watcher from its own terminal; only after verifying it stopped, remove .dmc/daemon.pid and retry. Keep the rest of the vault.',
    );
  }
}

/// A live, token-authenticated loopback endpoint proves watcher ownership.
/// Never infer ownership from a PID or signal a process from editable metadata.
class WatcherControl {
  static final Set<String> _heldRoots = {};
  final DmcPaths paths;
  final RandomAccessFile _lock;
  final HttpServer _server;
  final String _rootKey;
  final String token;
  final Completer<void> stopRequested = Completer<void>();
  bool _closed = false;
  Map<String, Object?> Function() state;

  WatcherControl._(
    this.paths,
    this._lock,
    this._server,
    this._rootKey,
    this.token,
    this.state,
  );

  static Future<WatcherControl> acquire(
    DmcPaths paths, {
    required Map<String, Object?> Function() state,
  }) async {
    checkLegacyWatcher(paths);
    final key = Directory(paths.rootPath).resolveSymbolicLinksSync();
    if (!_heldRoots.add(key)) {
      throw StateError('A watcher already owns this workspace.');
    }
    RandomAccessFile? lock;
    HttpServer? server;
    try {
      lock = File(
        controlPath(paths, 'watcher.lock'),
      ).openSync(mode: FileMode.append);
      lock.lockSync(FileLock.exclusive);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final random = Random.secure();
      final token = List.generate(
        32,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final control = WatcherControl._(paths, lock, server, key, token, state);
      server.listen(control._handle);
      writeControlJson(paths, 'watcher-control.json', {
        'version': 1,
        'pid': pid,
        'port': server.port,
        'token': token,
      });
      return control;
    } catch (_) {
      await server?.close(force: true);
      lock?.closeSync();
      _heldRoots.remove(key);
      rethrow;
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer $token') {
        request.response.statusCode = HttpStatus.forbidden;
      } else if (request.method == 'GET' && request.uri.path == '/state') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'pid': pid, ...state()}));
      } else if (request.method == 'POST' && request.uri.path == '/stop') {
        request.response.statusCode = HttpStatus.accepted;
        if (!stopRequested.isCompleted) stopRequested.complete();
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    } catch (_) {
      // A client can disconnect while a graceful stop is in progress.
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _server.close(force: true);
      final owner = readControlJson(paths, 'watcher-control.json');
      if (owner?['token'] == token) {
        File(controlPath(paths, 'watcher-control.json')).deleteSync();
      }
    } finally {
      _lock.closeSync();
      _heldRoots.remove(_rootKey);
    }
  }
}

Future<Map<String, dynamic>?> queryWatcher(
  DmcPaths paths, {
  bool stop = false,
}) async {
  final metadata = readControlJson(paths, 'watcher-control.json');
  if (metadata == null) return null;
  final port = metadata['port'];
  final token = metadata['token'];
  if (metadata['version'] != 1 ||
      port is! int ||
      port < 1 ||
      port > 65535 ||
      token is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(token)) {
    return null;
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
  client.findProxy = (_) => 'DIRECT';
  try {
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: stop ? '/stop' : '/state',
    );
    final request = await client
        .openUrl(stop ? 'POST' : 'GET', uri)
        .timeout(const Duration(seconds: 1));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close().timeout(const Duration(seconds: 1));
    if (stop) return response.statusCode == 202 ? {'accepted': true} : null;
    if (response.statusCode != 200) return null;
    final body = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 1));
    final value = jsonDecode(body);
    return value is Map<String, dynamic> ? value : null;
  } on IOException {
    return null;
  } on TimeoutException {
    return null;
  } on FormatException {
    return null;
  } finally {
    client.close(force: true);
  }
}
