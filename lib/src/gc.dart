import 'dart:io';

import 'config.dart';
import 'database.dart';
import 'workspace.dart';

Future<int> runGc({
  String? basePath,
  String? homePath,
  bool dryRun = false,
}) async {
  final paths = DmcPaths(basePath: basePath);
  if (!await paths.dmcDirectory.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return 1;
  }

  late final DmcConfig config;
  try {
    config = await loadDmcConfig(basePath: paths.rootPath, homePath: homePath);
  } catch (e) {
    print('[DMC] Error loading config: $e');
    return 1;
  }

  final db = DmcDatabase(paths.dbPath);
  db.initialize();
  final expiredRows = db.getExpiredSnapshotRecords(config.retentionDuration);
  final snapshotDir = Directory(paths.snapshotsPath);

  var bytesToFree = 0;
  for (final row in expiredRows) {
    if (isTombstoneSnapshot(hash: row.hash, snapshotPath: row.snapshotPath)) {
      continue;
    }

    final file = File(
      '${snapshotDir.path}${Platform.pathSeparator}${row.snapshotPath}',
    );
    if (await file.exists()) {
      bytesToFree += await file.length();
    }
  }

  if (dryRun) {
    print(
      '[DMC] GC dry-run: ${expiredRows.length} snapshot(s) would be deleted, freeing $bytesToFree byte(s).',
    );
    db.close();
    return 0;
  }

  final deletedCount = await db.pruneOldSnapshots(config.retentionDuration);
  db.close();
  print('[DMC] GC deleted $deletedCount snapshot(s).');
  return 0;
}
