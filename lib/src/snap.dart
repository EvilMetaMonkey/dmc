import 'dart:io';

import 'config.dart';
import 'database.dart';
import 'ignore.dart';
import 'task.dart';
import 'watcher.dart';
import 'workspace.dart';

Future<void> takeManualSnapshot({String? basePath, String? homePath}) async {
  final paths = DmcPaths(basePath: basePath);
  if (!await paths.dmcDirectory.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return;
  }

  late final DmcConfig config;
  try {
    config = await loadDmcConfig(basePath: paths.rootPath, homePath: homePath);
  } catch (e) {
    print('[DMC] Error loading config: $e');
    return;
  }

  final db = DmcDatabase(paths.dbPath);
  db.initialize();
  final ignoreRules = await loadIgnoreRules(paths.rootPath);
  final watcher = DmcWatcher(
    targetPath: paths.rootPath,
    database: db,
    snapshotsPath: paths.snapshotsPath,
    ignoreRules: ignoreRules,
    maxFileSizeBytes: config.maxFileSizeBytes,
    activeTaskNameProvider: () => readActiveTaskSync(basePath: paths.rootPath),
  );

  var processedFiles = 0;
  await for (final entity in Directory(paths.rootPath).list(recursive: true)) {
    if (entity is! File) {
      continue;
    }

    final normalizedPath = entity.path;
    if (!watcher.shouldTrackFile(normalizedPath)) {
      continue;
    }

    processedFiles++;
    await watcher.captureFileNow(normalizedPath);
  }

  db.close();
  print('[DMC] Manual snapshot completed. Checked $processedFiles file(s).');
}
