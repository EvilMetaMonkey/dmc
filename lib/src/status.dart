import 'dart:io';

import 'config.dart';
import 'daemon.dart';
import 'database.dart';
import 'workspace.dart';

Future<void> showStatus({
  String? basePath,
  String? homePath,
  DaemonPlatform? daemonPlatform,
}) async {
  final paths = DmcPaths(basePath: basePath);
  final dmcDirExists = await paths.dmcDirectory.exists();
  final daemonState = dmcDirExists
      ? await getDaemonState(basePath: paths.rootPath, platform: daemonPlatform)
      : (hasPidFile: false, pid: null, isRunning: false);

  late final DmcConfig config;
  try {
    config = await loadDmcConfig(basePath: paths.rootPath, homePath: homePath);
  } catch (e) {
    print('[DMC] Error loading config: $e');
    return;
  }

  var dbSizeBytes = 0;
  var totalSnapshots = 0;
  if (dmcDirExists) {
    final dbFile = File(paths.dbPath);
    if (await dbFile.exists()) {
      dbSizeBytes = await dbFile.length();
    }

    final db = DmcDatabase(paths.dbPath);
    db.initialize();
    totalSnapshots = db.getHistoryCount();
    db.close();
  }

  print('[DMC] Status');
  print('Initialized: ${dmcDirExists ? 'yes' : 'no'}');
  print('Vault path: ${paths.dmcPath}');
  print(
    daemonState.isRunning && daemonState.pid != null
        ? 'Watcher: Running (PID: ${daemonState.pid})'
        : 'Watcher: Stopped',
  );
  print('DB size bytes: $dbSizeBytes');
  print('Total snapshots: $totalSnapshots');
  print('Retention hours: ${config.retentionHours}');
  print('Max file size KB: ${config.maxFileSizeKb}');
  print(
    'Global config: ${config.hasGlobalConfig ? config.globalConfigPath : 'not found'}',
  );
  print(
    'Local config: ${config.hasLocalConfig ? config.localConfigPath : 'not found'}',
  );
}
