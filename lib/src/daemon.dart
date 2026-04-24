import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'workspace.dart';

typedef DaemonState = ({bool hasPidFile, int? pid, bool isRunning});

typedef DaemonPidMetadata =
    ({int pid, String? executable, List<String> arguments});

typedef SpawnDetachedProcess =
    Future<int> Function(
      String executable,
      List<String> arguments, {
      required String workingDirectory,
    });

typedef CheckPidRunning = Future<bool> Function(int pid);

typedef KillPid = bool Function(int pid);

class DaemonPlatform {
  final SpawnDetachedProcess spawnDetachedProcess;
  final CheckPidRunning isPidRunning;
  final KillPid killPid;

  const DaemonPlatform({
    required this.spawnDetachedProcess,
    required this.isPidRunning,
    required this.killPid,
  });

  static final DaemonPlatform system = DaemonPlatform(
    spawnDetachedProcess: _spawnDetachedProcess,
    isPidRunning: _isPidRunning,
    killPid: _killPid,
  );
}

Future<int?> readDaemonPid({String? basePath}) async {
  final metadata = await readDaemonPidMetadata(basePath: basePath);
  return metadata?.pid;
}

Future<DaemonPidMetadata?> readDaemonPidMetadata({String? basePath}) async {
  final paths = DmcPaths(basePath: basePath);
  if (!await paths.daemonPidFile.exists()) {
    return null;
  }

  final rawValue = (await paths.daemonPidFile.readAsString()).trim();
  final legacyPid = int.tryParse(rawValue);
  if (legacyPid != null) {
    return (pid: legacyPid, executable: null, arguments: const <String>[]);
  }

  try {
    final decoded = jsonDecode(rawValue);
    if (decoded is! Map<String, dynamic>) return null;
    final pid = decoded['pid'];
    if (pid is! int) return null;
    final executable = decoded['executable'];
    final arguments = decoded['arguments'];
    return (
      pid: pid,
      executable: executable is String ? executable : null,
      arguments: arguments is List
          ? arguments.whereType<String>().toList(growable: false)
          : const <String>[],
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
}) {
  final paths = DmcPaths(basePath: basePath);
  if (executable == null && arguments == null) {
    return paths.daemonPidFile.writeAsString('$pid\n');
  }

  return paths.daemonPidFile.writeAsString(
    '${jsonEncode({
      'pid': pid,
      'executable': executable,
      'arguments': arguments ?? const <String>[],
      'started_at': DateTime.now().millisecondsSinceEpoch,
    })}\n',
  );
}

Future<void> clearDaemonPid({String? basePath}) async {
  final paths = DmcPaths(basePath: basePath);
  if (await paths.daemonPidFile.exists()) {
    await paths.daemonPidFile.delete();
  }
}

Future<DaemonState> getDaemonState({
  String? basePath,
  DaemonPlatform? platform,
}) async {
  final resolvedPlatform = platform ?? DaemonPlatform.system;
  final paths = DmcPaths(basePath: basePath);
  final hasPidFile = await paths.daemonPidFile.exists();
  if (!hasPidFile) {
    return (hasPidFile: false, pid: null, isRunning: false);
  }

  final metadata = await readDaemonPidMetadata(basePath: basePath);
  if (metadata == null) {
    return (hasPidFile: true, pid: null, isRunning: false);
  }

  final pidIsRunning = await resolvedPlatform.isPidRunning(metadata.pid);
  final commandMatches = _daemonCommandMatches(metadata);
  return (
    hasPidFile: true,
    pid: metadata.pid,
    isRunning: pidIsRunning && commandMatches,
  );
}

Future<int> startDaemon({String? basePath, DaemonPlatform? platform}) async {
  final resolvedPlatform = platform ?? DaemonPlatform.system;
  final paths = DmcPaths(basePath: basePath);
  if (!await paths.dmcDirectory.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return 1;
  }

  final state = await getDaemonState(
    basePath: paths.rootPath,
    platform: resolvedPlatform,
  );
  if (state.hasPidFile && state.isRunning && state.pid != null) {
    print('[DMC] Watcher is already running (PID: ${state.pid}).');
    return 1;
  }

  if (state.hasPidFile && !state.isRunning) {
    await clearDaemonPid(basePath: paths.rootPath);
    print('[DMC] Removed stale daemon PID file.');
  }

  final launch = _buildWatchLaunchCommand();
  final pid = await resolvedPlatform.spawnDetachedProcess(
    launch.executable,
    launch.arguments,
    workingDirectory: paths.rootPath,
  );

  await writeDaemonPid(
    pid,
    basePath: paths.rootPath,
    executable: launch.executable,
    arguments: launch.arguments,
  );
  print('[DMC] Started watcher in background (PID: $pid).');
  return 0;
}

Future<int> stopDaemon({String? basePath, DaemonPlatform? platform}) async {
  final resolvedPlatform = platform ?? DaemonPlatform.system;
  final paths = DmcPaths(basePath: basePath);
  if (!await paths.dmcDirectory.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return 1;
  }

  final state = await getDaemonState(
    basePath: paths.rootPath,
    platform: resolvedPlatform,
  );
  if (!state.hasPidFile) {
    print('[DMC] Watcher is not running.');
    return 1;
  }

  if (state.pid == null) {
    await clearDaemonPid(basePath: paths.rootPath);
    print('[DMC] Watcher PID file was invalid and has been removed.');
    return 1;
  }

  if (!state.isRunning) {
    await clearDaemonPid(basePath: paths.rootPath);
    print('[DMC] Watcher is already stopped. Removed stale PID file.');
    return 1;
  }

  final killed = resolvedPlatform.killPid(state.pid!);
  if (!killed) {
    print('[DMC] Error: Failed to stop watcher process ${state.pid}.');
    return 1;
  }

  await clearDaemonPid(basePath: paths.rootPath);
  print('[DMC] Stopped watcher (PID: ${state.pid}).');
  return 0;
}

({String executable, List<String> arguments}) _buildWatchLaunchCommand() {
  final executable = Platform.resolvedExecutable;
  final scriptPath = Platform.script.toFilePath();
  final scriptExtension = p.extension(scriptPath).toLowerCase();

  if (scriptExtension == '.dart') {
    return (executable: executable, arguments: [scriptPath, 'watch']);
  }

  return (executable: executable, arguments: ['watch']);
}

bool _daemonCommandMatches(DaemonPidMetadata metadata) {
  if (metadata.executable == null) {
    return true;
  }

  final launch = _buildWatchLaunchCommand();
  return p.normalize(metadata.executable!) == p.normalize(launch.executable) &&
      _listEquals(metadata.arguments, launch.arguments);
}

bool _listEquals(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

Future<int> _spawnDetachedProcess(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.detached,
  );
  return process.pid;
}

Future<bool> _isPidRunning(int pid) async {
  if (Platform.isWindows) {
    final result = await Process.run('tasklist', [
      '/FI',
      'PID eq $pid',
      '/NH',
      '/FO',
      'CSV',
    ]);
    if (result.exitCode != 0) {
      return false;
    }

    final output = (result.stdout as String).trim();
    return output.isNotEmpty &&
        !output.startsWith('INFO:') &&
        output.contains('"$pid"');
  }

  final result = await Process.run('ps', ['-p', '$pid', '-o', 'pid=']);
  if (result.exitCode != 0) {
    return false;
  }

  return (result.stdout as String).trim() == '$pid';
}

bool _killPid(int pid) {
  return Process.killPid(pid);
}
