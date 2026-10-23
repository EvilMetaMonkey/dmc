import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'workspace.dart';
import 'watcher_control.dart';

typedef DaemonState = ({bool hasPidFile, int? pid, bool isRunning});
typedef DaemonPidMetadata = ({
  int pid,
  String? executable,
  List<String> arguments,
});
typedef SpawnDetachedProcess =
    Future<int> Function(
      String executable,
      List<String> arguments, {
      required String workingDirectory,
    });
typedef CheckPidRunning = Future<bool> Function(int pid);
typedef KillPid = bool Function(int pid);

/// Spawn injection remains available for command tests. PID liveness/kill
/// callbacks are retained for source compatibility but no longer confer ownership.
class DaemonPlatform {
  final SpawnDetachedProcess spawnDetachedProcess;
  final CheckPidRunning isPidRunning;
  final KillPid killPid;
  const DaemonPlatform({
    required this.spawnDetachedProcess,
    required this.isPidRunning,
    required this.killPid,
  });
  static final system = DaemonPlatform(
    spawnDetachedProcess:
        (executable, arguments, {required workingDirectory}) async =>
            (await Process.start(
              executable,
              arguments,
              workingDirectory: workingDirectory,
              mode: ProcessStartMode.detached,
            )).pid,
    isPidRunning: (_) async => false,
    killPid: (_) => false,
  );
}

Future<int?> readDaemonPid({String? basePath}) async =>
    (await readDaemonPidMetadata(basePath: basePath))?.pid;

Future<DaemonPidMetadata?> readDaemonPidMetadata({String? basePath}) async {
  final file = DmcPaths(basePath: basePath).daemonPidFile;
  if (!file.existsSync()) return null;
  final text = file.readAsStringSync().trim();
  final legacy = int.tryParse(text);
  if (legacy != null) {
    return legacy > 0
        ? (pid: legacy, executable: null, arguments: const <String>[])
        : null;
  }
  try {
    final value = jsonDecode(text);
    if (value is! Map || value['pid'] is! int || (value['pid'] as int) <= 0) {
      return null;
    }
    return (
      pid: value['pid'] as int,
      executable: value['executable'] is String
          ? value['executable'] as String
          : null,
      arguments: value['arguments'] is List
          ? (value['arguments'] as List).whereType<String>().toList()
          : <String>[],
    );
  } on FormatException {
    return null;
  }
}

Future<void> writeDaemonPid(
  int pid, {
  String? basePath,
  String? executable,
  List<String>? arguments,
}) async {
  if (pid <= 0) throw ArgumentError('PID must be positive.');
  writeControlJson(DmcPaths(basePath: basePath), 'daemon.pid', {
    'pid': pid,
    'executable': executable,
    'arguments': arguments ?? [],
  });
}

Future<void> clearDaemonPid({String? basePath}) async {
  final file = DmcPaths(basePath: basePath).daemonPidFile;
  if (file.existsSync()) file.deleteSync();
}

Future<DaemonState> getDaemonState({
  String? basePath,
  DaemonPlatform? platform,
}) async {
  final paths = DmcPaths(basePath: basePath);
  final live = await queryWatcher(paths);
  final savedPid = await readDaemonPid(basePath: basePath);
  return (
    hasPidFile: paths.daemonPidFile.existsSync(),
    pid: live?['pid'] as int? ?? savedPid,
    isRunning: live != null,
  );
}

Future<int> startDaemon({
  String? basePath,
  DaemonPlatform? platform,
  Duration readinessTimeout = const Duration(seconds: 30),
}) async {
  final paths = DmcPaths(basePath: basePath);
  if (!paths.dmcDirectory.existsSync() || !File(paths.dbPath).existsSync()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return 1;
  }
  final existing = await queryWatcher(paths);
  if (existing != null) {
    print('[DMC] Watcher is already running (PID: ${existing['pid']}).');
    return 1;
  }
  checkLegacyWatcher(paths);
  final executable = Platform.resolvedExecutable;
  final script = Platform.script.toFilePath();
  final arguments = p.extension(script).toLowerCase() == '.dart'
      ? [script, 'watch']
      : ['watch'];
  final child = await (platform ?? DaemonPlatform.system).spawnDetachedProcess(
    executable,
    arguments,
    workingDirectory: paths.rootPath,
  );
  final deadline = DateTime.now().add(readinessTimeout);
  while (DateTime.now().isBefore(deadline)) {
    final live = await queryWatcher(paths);
    final lastHealth = readControlJson(paths, 'watcher-health.json');
    if (live == null &&
        lastHealth?['pid'] == child &&
        lastHealth?['phase'] == 'failed') {
      print('[DMC] Watcher startup failed. Run dmc doctor for details.');
      return 1;
    }
    if (live != null) {
      if (live['pid'] != child) {
        print(
          '[DMC] Another watcher owns this workspace; no duplicate started.',
        );
        return 1;
      }
      if (live['ready'] == true) {
        print(
          '[DMC] Ready: background watcher established its baseline (PID: $child).',
        );
        return 0;
      }
      if (live['phase'] == 'failed' || live['phase'] == 'degraded') {
        await queryWatcher(paths, stop: true);
        print('[DMC] Watcher could not establish protection. Run dmc doctor.');
        return 1;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  // A slow baseline may still be running. Do not kill it or report success.
  print(
    '[DMC] Readiness timed out. Run dmc status; use dmc stop to cancel a running baseline.',
  );
  return 1;
}

Future<int> stopDaemon({
  String? basePath,
  DaemonPlatform? platform,
  Duration drainTimeout = const Duration(seconds: 30),
}) async {
  final paths = DmcPaths(basePath: basePath);
  final live = await queryWatcher(paths);
  if (live == null) {
    print(
      '[DMC] No authenticated watcher is running. Legacy/stale PID files are not used to terminate processes.',
    );
    return 1;
  }
  final metadata = readControlJson(paths, 'watcher-control.json');
  if (await queryWatcher(paths, stop: true) == null) {
    print('[DMC] Watcher did not accept the stop request.');
    return 1;
  }
  final deadline = DateTime.now().add(drainTimeout);
  while (DateTime.now().isBefore(deadline)) {
    final current = readControlJson(paths, 'watcher-control.json');
    if (current == null || current['token'] != metadata?['token']) {
      final health = readControlJson(paths, 'watcher-health.json');
      if (health?['phase'] != 'stopped') {
        print('[DMC] Watcher stopped with unresolved errors. Run dmc doctor.');
        return 1;
      }
      print('[DMC] Stopped watcher after pending captures finished.');
      return 0;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  print(
    '[DMC] Stop is still draining or was interrupted; run dmc status and dmc doctor. No process was forcibly killed.',
  );
  return 1;
}
