import 'dart:io';
import 'package:path/path.dart' as p;
import 'database.dart';

/// The name of the DMC directory
const String dmcDirName = '.dmc';

/// The name of the snapshots subdirectory
const String snapshotsDirName = 'snapshots';

/// The name of the database file
const String dbFileName = 'dmc.db';

/// Initialize DMC in the specified directory
///
/// Creates .dmc/ folder, .dmc/snapshots/ subfolder, and .dmc/dmc.db database
/// If [basePath] is not provided, uses the current working directory
Future<void> initDmc({String? basePath}) async {
  final cwd = basePath ?? Directory.current.path;
  final dmcPath = p.join(cwd, dmcDirName);
  final snapshotsPath = p.join(dmcPath, snapshotsDirName);
  final dbPath = p.join(dmcPath, dbFileName);

  // Create .dmc/ directory if it doesn't exist
  final dmcDir = Directory(dmcPath);
  if (!await dmcDir.exists()) {
    await dmcDir.create(recursive: true);
    print('Created $dmcDirName/ directory');
  }

  // Create snapshots/ subdirectory if it doesn't exist
  final snapshotsDir = Directory(snapshotsPath);
  if (!await snapshotsDir.exists()) {
    await snapshotsDir.create(recursive: true);
    print('Created $dmcDirName/$snapshotsDirName/ directory');
  }

  // Initialize SQLite database
  final db = DmcDatabase(dbPath);
  db.initialize();
  print('Initialized database at $dmcDirName/$dbFileName');

  // Verify table was created
  if (db.isInitialized) {
    print('Created history table');
  }

  db.close();
  print('DMC initialized successfully!');
}
