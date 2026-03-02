import 'dart:io';
import 'package:path/path.dart' as p;
import 'database.dart';
import 'init.dart';

/// Format a Unix timestamp to a human-readable string
String formatTimestamp(int unixTime) {
  final dateTime = DateTime.fromMillisecondsSinceEpoch(unixTime);
  final year = dateTime.year;
  final month = dateTime.month.toString().padLeft(2, '0');
  final day = dateTime.day.toString().padLeft(2, '0');
  final hour = dateTime.hour.toString().padLeft(2, '0');
  final minute = dateTime.minute.toString().padLeft(2, '0');
  final second = dateTime.second.toString().padLeft(2, '0');
  return '$year-$month-$day $hour:$minute:$second';
}

/// Show recent backup logs
Future<void> showLogs({int limit = 10, String? basePath}) async {
  final cwd = basePath ?? Directory.current.path;
  final dmcPath = p.join(cwd, dmcDirName);
  final dbPath = p.join(dmcPath, dbFileName);

  // Verify DMC is initialized
  final dmcDir = Directory(dmcPath);
  if (!await dmcDir.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return;
  }

  // Open database
  final db = DmcDatabase(dbPath);
  db.initialize();

  final logs = db.getRecentLogs(limit: limit);

  if (logs.isEmpty) {
    print('[DMC] No backup history found.');
    db.close();
    return;
  }

  // Print header
  print('');
  print('Recent Backups:');
  print('-' * 60);

  for (final log in logs) {
    final time = formatTimestamp(log.timestamp);
    final shortHash = log.hash.substring(0, 8);
    print('$time  ${log.filePath.padRight(30)}  $shortHash');
  }

  print('-' * 60);
  print('Total: ${logs.length} backup(s)');

  db.close();
}

/// Restore a file to its previous state
Future<void> undoFile(String filePath, {String? basePath}) async {
  final cwd = basePath ?? Directory.current.path;
  final dmcPath = p.join(cwd, dmcDirName);
  final snapshotsPath = p.join(dmcPath, snapshotsDirName);
  final dbPath = p.join(dmcPath, dbFileName);

  // Verify DMC is initialized
  final dmcDir = Directory(dmcPath);
  if (!await dmcDir.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return;
  }

  // Normalize the file path to be relative
  final absolutePath = p.isAbsolute(filePath) ? filePath : p.join(cwd, filePath);
  final relativePath = p.relative(absolutePath, from: cwd);

  // Open database
  final db = DmcDatabase(dbPath);
  db.initialize();

  // Get latest snapshot for this file
  final snapshot = db.getSnapshotForRestore(relativePath);

  if (snapshot == null) {
    print('[DMC] No history found for $filePath');
    db.close();
    return;
  }

  // Build paths
  final snapshotFilePath = p.join(snapshotsPath, snapshot.snapshotPath);
  final targetFilePath = p.join(cwd, relativePath);

  // Check if snapshot file exists
  final snapshotFile = File(snapshotFilePath);
  if (!await snapshotFile.exists()) {
    print('[DMC] Error: Snapshot file not found: ${snapshot.snapshotPath}');
    db.close();
    return;
  }

  try {
    // Copy snapshot back to original location
    await snapshotFile.copy(targetFilePath);

    final time = formatTimestamp(snapshot.timestamp);
    print('[DMC] Restored $filePath to version from $time');
  } catch (e) {
    print('[DMC] Error restoring file: $e');
  }

  db.close();
}
