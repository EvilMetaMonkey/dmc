import 'dart:io';

import 'database.dart';
import 'workspace.dart';

/// Initialize DMC in the specified directory
///
/// Creates .dmc/ folder, .dmc/snapshots/ subfolder, and .dmc/dmc.db database
/// If [basePath] is not provided, uses the current working directory
Future<void> initDmc({String? basePath}) async {
  final paths = DmcPaths(basePath: basePath);

  // Create .dmc/ directory if it doesn't exist
  final dmcDir = paths.dmcDirectory;
  if (!await dmcDir.exists()) {
    await dmcDir.create(recursive: true);
    print('Created $dmcDirName/ directory');
  }
  // Exclude the entire vault even when the containing project has no ignore file.
  final vaultIgnore = File(
    paths.validateInternalPath(
      '${paths.dmcPath}${Platform.pathSeparator}.gitignore',
    ),
  );
  if (!vaultIgnore.existsSync()) {
    vaultIgnore.writeAsStringSync('*\n', flush: true);
  }

  // Create snapshots/ subdirectory if it doesn't exist
  final snapshotsDir = Directory(paths.snapshotsPath);
  if (!await snapshotsDir.exists()) {
    await snapshotsDir.create(recursive: true);
    print('Created $dmcDirName/$snapshotsDirName/ directory');
  }

  // Initialize SQLite database
  final db = DmcDatabase(paths.dbPath);
  db.initialize();
  print('Initialized database at $dmcDirName/$dbFileName');

  // Verify table was created
  if (db.isInitialized) {
    print('Created history table');
  }

  db.close();
  print('DMC initialized successfully!');
}
