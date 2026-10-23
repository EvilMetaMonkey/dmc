import 'database.dart';
import 'log.dart';
import 'workspace.dart';

Future<int> createMark(String name, {String? basePath}) async {
  final trimmedName = name.trim();
  if (trimmedName.isEmpty) {
    print('[DMC] Error: Mark name cannot be empty.');
    return 1;
  }

  final paths = DmcPaths(basePath: basePath);
  if (!await paths.dmcDirectory.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return 1;
  }

  final db = DmcDatabase(paths.dbPath);
  db.initialize();
  final burstId = db.getLatestBurstId();
  if (burstId == null) {
    db.close();
    print('[DMC] Error: No burst history found to mark.');
    return 1;
  }

  db.upsertMark(
    name: trimmedName,
    burstId: burstId,
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );
  db.close();
  print('[DMC] Marked "$trimmedName" at burst $burstId');
  return 0;
}

Future<int> showMarks({String? basePath}) async {
  final paths = DmcPaths(basePath: basePath);
  if (!await paths.dmcDirectory.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return 1;
  }

  final db = DmcDatabase(paths.dbPath);
  db.initialize();
  final marks = db.getMarks();
  db.close();

  if (marks.isEmpty) {
    print('[DMC] No marks found.');
    return 0;
  }

  print('Marks:');
  for (final mark in marks) {
    print(
      '${mark.name} -> burst ${mark.burstId} (${formatTimestamp(mark.createdAt)})',
    );
  }
  return 0;
}
