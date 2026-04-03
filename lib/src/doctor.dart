import 'dart:io';

import 'config.dart';
import 'database.dart';
import 'workspace.dart';

Future<bool> runDoctor({String? basePath, String? homePath}) async {
  final paths = DmcPaths(basePath: basePath);
  final dmcDir = paths.dmcDirectory;
  if (!await dmcDir.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return true;
  }

  try {
    await loadDmcConfig(basePath: paths.rootPath, homePath: homePath);
  } catch (e) {
    print('[DMC] Error loading config: $e');
    return true;
  }

  late final DmcDatabase db;
  try {
    db = DmcDatabase(paths.dbPath);
    db.initialize();
  } catch (e) {
    print('[DMC] Error opening database: $e');
    return true;
  }

  final snapshotRecords = db.getAllSnapshotRecords();
  db.close();

  final missingSnapshotFiles = <String>[];
  final referencedSnapshotPaths = <String>{};
  for (final record in snapshotRecords) {
    if (isTombstoneSnapshot(
      hash: record.hash,
      snapshotPath: record.snapshotPath,
    )) {
      continue;
    }

    referencedSnapshotPaths.add(record.snapshotPath);
    final snapshotFile = File(
      '${paths.snapshotsPath}${Platform.pathSeparator}${record.snapshotPath}',
    );
    if (!await snapshotFile.exists()) {
      missingSnapshotFiles.add(record.snapshotPath);
    }
  }

  final snapshotsDir = Directory(paths.snapshotsPath);
  final orphanedSnapshotFiles = <String>[];
  if (await snapshotsDir.exists()) {
    await for (final entity in snapshotsDir.list()) {
      if (entity is! File) continue;

      final name = entity.uri.pathSegments.isEmpty
          ? ''
          : entity.uri.pathSegments.last;
      if (!referencedSnapshotPaths.contains(name)) {
        orphanedSnapshotFiles.add(name);
      }
    }
  }

  print('[DMC] Doctor');
  print('DB access: ok');
  print('Missing snapshot files: ${missingSnapshotFiles.length}');
  print('Orphaned snapshot files: ${orphanedSnapshotFiles.length}');

  final hasIssues =
      missingSnapshotFiles.isNotEmpty || orphanedSnapshotFiles.isNotEmpty;
  if (hasIssues) {
    if (missingSnapshotFiles.isNotEmpty) {
      print('Missing: ${missingSnapshotFiles.join(', ')}');
    }
    if (orphanedSnapshotFiles.isNotEmpty) {
      print('Orphaned: ${orphanedSnapshotFiles.join(', ')}');
    }
  }

  return hasIssues;
}
