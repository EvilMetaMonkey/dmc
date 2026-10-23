import 'dart:io';

import 'config.dart';
import 'database.dart';
import 'snapshot_store.dart';
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
  try {
    db.initialize();
    final expiredRows = db.getExpiredSnapshotRecords(config.retentionDuration);
    final snapshotDir = Directory(paths.snapshotsPath);

    var bytesToFree = 0;
    final expiredIds = expiredRows.map((row) => row.id).toSet();
    final retainedPaths = db.db
        .select('SELECT id, snapshot_path FROM history')
        .where((row) => !expiredIds.contains(row['id']))
        .map((row) => row['snapshot_path'])
        .toSet();
    final countedPaths = <String>{};
    for (final row in expiredRows) {
      if (isTombstoneSnapshot(hash: row.hash, snapshotPath: row.snapshotPath)) {
        continue;
      }

      if (retainedPaths.contains(row.snapshotPath) ||
          !countedPaths.add(row.snapshotPath)) {
        continue;
      }
      final file = SnapshotStore.snapshotFile(
        snapshotDir.path,
        row.snapshotPath,
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
  } catch (e) {
    print('[DMC] GC failed: $e');
    return 1;
  } finally {
    db.close();
  }
}
