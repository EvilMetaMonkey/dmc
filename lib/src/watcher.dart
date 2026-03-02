import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'database.dart';
import 'init.dart';

/// Directories to ignore when watching for file changes
const List<String> ignoredDirs = [
  '.git',
  '.dmc',
  '.dart_tool',
  'build',
  'node_modules',
];

/// Debounce delay in milliseconds
const int debounceDelayMs = 500;

/// Watches a directory for file changes and backs up modified files
class DmcWatcher {
  final String targetPath;
  final DmcDatabase database;
  final String snapshotsPath;

  final Map<String, Timer> _pendingBackups = {};
  StreamSubscription<FileSystemEvent>? _watchSubscription;
  bool _isRunning = false;

  DmcWatcher({
    required this.targetPath,
    required this.database,
    required this.snapshotsPath,
  });

  /// Start watching for file changes
  void start() {
    if (_isRunning) return;
    _isRunning = true;

    final dir = Directory(targetPath);
    if (!dir.existsSync()) {
      print('[DMC] Error: Target directory does not exist: $targetPath');
      return;
    }

    print('[DMC] Watching: $targetPath');

    _watchSubscription = dir.watch(recursive: true).listen(
      (event) => _handleFileEvent(event),
      onError: (error) {
        print('[DMC] Watch error: $error');
      },
    );
  }

  /// Stop watching for file changes
  void stop() {
    _isRunning = false;
    _watchSubscription?.cancel();
    _watchSubscription = null;

    // Cancel all pending backups
    for (final timer in _pendingBackups.values) {
      timer.cancel();
    }
    _pendingBackups.clear();

    print('[DMC] Stopped watching');
  }

  /// Handle a file system event
  void _handleFileEvent(FileSystemEvent event) {
    // Only handle modify events
    if (event.type != FileSystemEvent.modify) return;

    final filePath = event.path;

    // Check if file is in an ignored directory
    if (_isIgnored(filePath)) return;

    // Only process files (not directories)
    final file = File(filePath);
    if (!file.existsSync()) return;

    // Debounce: cancel existing timer and start new one
    _pendingBackups[filePath]?.cancel();
    _pendingBackups[filePath] = Timer(
      Duration(milliseconds: debounceDelayMs),
      () => _performBackup(filePath),
    );
  }

  /// Check if a file path is in an ignored directory
  bool _isIgnored(String filePath) {
    for (final ignored in ignoredDirs) {
      if (filePath.contains('/$ignored/') ||
          filePath.contains('\\$ignored\\') ||
          filePath.endsWith('/$ignored') ||
          filePath.endsWith('\\$ignored')) {
        return true;
      }
    }
    return false;
  }

  /// Perform the backup for a file
  Future<void> _performBackup(String filePath) async {
    _pendingBackups.remove(filePath);

    // Calculate relative path from target directory
    final relativePath = p.relative(filePath, from: targetPath);

    try {
      // Read file content
      final file = File(filePath);
      final content = await file.readAsBytes();

      // Calculate SHA-256 hash
      final hash = sha256.convert(content).toString();

      // Check if this file has changed since last backup
      final latestSnapshot = database.getLatestSnapshot(relativePath);

      if (latestSnapshot != null && latestSnapshot.hash == hash) {
        // No actual change, skip backup
        return;
      }

      // Generate snapshot filename
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filename = p.basenameWithoutExtension(filePath);
      final extension = p.extension(filePath);
      final snapshotFilename = '${filename}_$timestamp$extension.bak';
      final snapshotPath = p.join(snapshotsPath, snapshotFilename);

      // Copy file to snapshots directory
      await file.copy(snapshotPath);

      // Insert record into database
      database.insertSnapshot(
        filePath: relativePath,
        snapshotPath: snapshotFilename,
        timestamp: timestamp,
        hash: hash,
      );

      print('[DMC] Captured change: $relativePath');
    } catch (e) {
      // Gracefully handle file read errors (e.g., locked files)
      print('[DMC] Could not backup $relativePath: $e');
    }
  }
}

/// Start watching the target directory for changes
Future<void> watchDmc({String? basePath}) async {
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

  // Initialize database
  final db = DmcDatabase(dbPath);
  db.initialize();

  // Create watcher
  final watcher = DmcWatcher(
    targetPath: cwd,
    database: db,
    snapshotsPath: snapshotsPath,
  );

  // Handle shutdown signals
  ProcessSignal.sigint.watch().listen((signal) {
    print('\n[DMC] Shutting down...');
    watcher.stop();
    db.close();
    exit(0);
  });

  // Start watching
  watcher.start();

  // Keep the process running
  await Future<void>.delayed(Duration(days: 1));
}
