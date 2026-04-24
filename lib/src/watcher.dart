import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'config.dart';
import 'database.dart';
import 'ignore.dart';
import 'snapshot_names.dart';
import 'task.dart';
import 'workspace.dart';

/// Debounce delay in milliseconds
const int debounceDelayMs = 500;

/// Snapshots captured within this window share the same burst id.
const Duration burstWindow = Duration(seconds: 3);

const int _binaryProbeBytes = 1024;
const Set<String> _knownBinaryExtensions = {
  '.exe',
  '.dll',
  '.so',
  '.dylib',
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.ico',
  '.pdf',
  '.zip',
  '.tar',
  '.gz',
  '.7z',
  '.mp3',
  '.mp4',
  '.mov',
  '.avi',
  '.woff',
  '.woff2',
  '.ttf',
  '.otf',
  '.sqlite',
  '.db',
};

class BurstAssigner {
  final Duration window;
  int? _activeBurstId;
  int? _lastSnapshotTimestamp;

  BurstAssigner({this.window = burstWindow});

  int assignBurstId(int timestamp) {
    if (_activeBurstId == null ||
        _lastSnapshotTimestamp == null ||
        timestamp - _lastSnapshotTimestamp! > window.inMilliseconds) {
      _activeBurstId = timestamp;
    }

    _lastSnapshotTimestamp = timestamp;
    return _activeBurstId!;
  }
}

/// Watches a directory for file changes and backs up modified files
class DmcWatcher {
  final String targetPath;
  final DmcDatabase database;
  final String snapshotsPath;
  final List<IgnoreRule> ignoreRules;
  final BurstAssigner burstAssigner;
  final int Function() _nowMilliseconds;
  final int maxFileSizeBytes;
  final String? Function() _activeTaskNameProvider;

  final Map<String, Timer> _pendingBackups = {};
  late final String _normalizedTargetPath;
  StreamSubscription<FileSystemEvent>? _watchSubscription;
  bool _isRunning = false;

  DmcWatcher({
    required this.targetPath,
    required this.database,
    required this.snapshotsPath,
    required this.ignoreRules,
    required this.maxFileSizeBytes,
    String? Function()? activeTaskNameProvider,
    BurstAssigner? burstAssigner,
    int Function()? nowMilliseconds,
  }) : burstAssigner = burstAssigner ?? BurstAssigner(),
       _activeTaskNameProvider = activeTaskNameProvider ?? (() => null),
       _nowMilliseconds =
           nowMilliseconds ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _normalizedTargetPath = p.normalize(targetPath);
  }

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

    _watchSubscription = dir
        .watch(recursive: true)
        .listen(
          (event) => _handleFileEvent(event),
          onError: (error) {
            print('[DMC] Watch error: $error');
          },
        );
  }

  /// Capture a file immediately without debounce. Useful for focused tests.
  Future<void> captureFileNow(String filePath) async {
    final normalizedPath = p.normalize(filePath);
    if (_isIgnored(normalizedPath)) {
      return;
    }

    await _performBackup(normalizedPath);
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
    // Only handle modify/delete events
    if (event.type != FileSystemEvent.modify &&
        event.type != FileSystemEvent.delete) {
      return;
    }

    final filePath = p.normalize(event.path);

    if (_isIgnored(filePath)) return;

    // Debounce: cancel existing timer and start new one
    _pendingBackups[filePath]?.cancel();
    _pendingBackups[filePath] = Timer(
      Duration(milliseconds: debounceDelayMs),
      () => _performBackup(filePath),
    );
  }

  bool _isIgnored(String filePath) {
    final relativePath = p.normalize(
      p.relative(filePath, from: _normalizedTargetPath),
    );

    if (relativePath == '..' || relativePath.startsWith('..${p.separator}')) {
      return true;
    }

    for (final rule in ignoreRules) {
      if (rule.matches(relativePath)) {
        return true;
      }
    }

    return false;
  }

  bool shouldTrackFile(String filePath) {
    return !_isIgnored(p.normalize(filePath));
  }

  /// Perform the backup for a file
  Future<void> _performBackup(String filePath) async {
    _pendingBackups.remove(filePath);

    // Calculate relative path from target directory
    final relativePath = p.normalize(
      p.relative(filePath, from: _normalizedTargetPath),
    );

    try {
      final file = File(filePath);
      final timestamp = _nowMilliseconds();
      final burstId = burstAssigner.assignBurstId(timestamp);
      final taskName = _activeTaskNameProvider();

      if (!await file.exists()) {
        final latestSnapshot = database.getLatestSnapshot(relativePath);
        if (latestSnapshot == null ||
            isTombstoneSnapshot(
              hash: latestSnapshot.hash,
              snapshotPath: latestSnapshot.snapshotPath,
            )) {
          return;
        }

        database.insertTombstone(
          filePath: relativePath,
          timestamp: timestamp,
          burstId: burstId,
          taskName: taskName,
        );
        print('[DMC] Captured deletion: $relativePath');
        return;
      }

      // Read file content
      final fileSizeBytes = await file.length();
      if (fileSizeBytes > maxFileSizeBytes) {
        print(
          '[DMC] Skipping $relativePath: file exceeds max size (${maxFileSizeBytes ~/ 1024} KB).',
        );
        return;
      }

      if (await _isProbablyBinaryFile(file)) {
        print('[DMC] Skipping $relativePath: binary files are not tracked.');
        return;
      }

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
      final snapshotFilename = buildSnapshotFilename(
        relativePath: relativePath,
        timestamp: timestamp,
        hash: hash,
      );
      final snapshotPath = p.join(snapshotsPath, snapshotFilename);

      // Copy file to snapshots directory
      await file.copy(snapshotPath);

      // Insert record into database
      database.insertSnapshot(
        filePath: relativePath,
        snapshotPath: snapshotFilename,
        timestamp: timestamp,
        hash: hash,
        burstId: burstId,
        taskName: taskName,
      );

      print('[DMC] Captured change: $relativePath');
    } catch (e) {
      // Gracefully handle file read errors (e.g., locked files)
      print('[DMC] Could not backup $relativePath: $e');
    }
  }
}

/// Start watching the target directory for changes
Future<void> watchDmc({String? basePath, Future<void>? keepAlive}) async {
  final paths = DmcPaths(basePath: basePath);

  // Verify DMC is initialized
  final dmcDir = paths.dmcDirectory;
  if (!await dmcDir.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return;
  }

  // Initialize database
  final db = DmcDatabase(paths.dbPath);
  db.initialize();

  late final DmcConfig config;
  try {
    config = await loadDmcConfig(basePath: paths.rootPath);
  } catch (e) {
    print('[DMC] Error loading config: $e');
    db.close();
    return;
  }

  final prunedCount = await db.pruneOldSnapshots(config.retentionDuration);
  if (prunedCount > 0) {
    print('[DMC] Pruned $prunedCount expired snapshot(s)');
  }

  final ignoreRules = await loadIgnoreRules(paths.rootPath);

  // Create watcher
  final watcher = DmcWatcher(
    targetPath: paths.rootPath,
    database: db,
    snapshotsPath: paths.snapshotsPath,
    ignoreRules: ignoreRules,
    maxFileSizeBytes: config.maxFileSizeBytes,
    activeTaskNameProvider: () => readActiveTaskSync(basePath: paths.rootPath),
  );

  // Handle shutdown signals
  final signalSubscription = ProcessSignal.sigint.watch().listen((signal) {
    print('\n[DMC] Shutting down...');
    watcher.stop();
    db.close();
    exit(0);
  });

  // Start watching
  watcher.start();

  try {
    await (keepAlive ?? Completer<void>().future);
  } finally {
    await signalSubscription.cancel();
    watcher.stop();
    db.close();
  }
}

Future<bool> _isProbablyBinaryFile(File file) async {
  final extension = p.extension(file.path).toLowerCase();
  if (_knownBinaryExtensions.contains(extension)) {
    return true;
  }

  final handle = await file.open();
  try {
    final headerBytes = await handle.read(_binaryProbeBytes);
    return headerBytes.any((byte) => byte == 0);
  } finally {
    await handle.close();
  }
}
