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

/// The name of the optional user ignore file.
const String dmcIgnoreFileName = '.dmcignore';

/// Debounce delay in milliseconds
const int debounceDelayMs = 500;

/// Maximum snapshot retention while the watcher is running.
const Duration snapshotRetention = Duration(hours: 48);

class IgnoreRule {
  final String pattern;
  final bool directoryOnly;
  final bool matchAnywhere;
  final bool hasWildcard;

  const IgnoreRule._({
    required this.pattern,
    required this.directoryOnly,
    required this.matchAnywhere,
    required this.hasWildcard,
  });

  factory IgnoreRule.defaultDirectory(String name) {
    return IgnoreRule._(
      pattern: p.normalize(name),
      directoryOnly: true,
      matchAnywhere: true,
      hasWildcard: false,
    );
  }

  static IgnoreRule? fromPattern(String rawPattern) {
    final trimmed = rawPattern.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) return null;

    final directoryOnly = trimmed.endsWith('/') || trimmed.endsWith('\\');
    var normalized = trimmed
        .replaceAll('/', p.separator)
        .replaceAll('\\', p.separator);

    if (normalized.startsWith('.${p.separator}')) {
      normalized = normalized.substring(2);
    }

    normalized = p.normalize(normalized);
    normalized = _trimTrailingSeparators(normalized);

    if (normalized.isEmpty || normalized == '.') return null;

    return IgnoreRule._(
      pattern: normalized,
      directoryOnly: directoryOnly,
      matchAnywhere: !normalized.contains(p.separator),
      hasWildcard: normalized.contains('*') || normalized.contains('?'),
    );
  }

  bool matches(String relativePath) {
    final normalizedRelativePath = p.normalize(relativePath);
    if (normalizedRelativePath.isEmpty || normalizedRelativePath == '.') {
      return false;
    }

    final segments = p.split(normalizedRelativePath);
    if (matchAnywhere) {
      return _matchesSegments(segments);
    }

    return _matchesPath(normalizedRelativePath);
  }

  bool _matchesSegments(List<String> segments) {
    if (hasWildcard) {
      final regex = _buildRegex(_toPosix(pattern));
      return segments.any((segment) => regex.hasMatch(_toPosix(segment)));
    }

    return segments.any((segment) => _equals(segment, pattern));
  }

  bool _matchesPath(String relativePath) {
    final pathText = _toPosix(relativePath);
    final patternText = _toPosix(pattern);

    if (hasWildcard) {
      final regex = _buildRegex(patternText);
      if (regex.hasMatch(pathText)) return true;
    } else if (_equals(pathText, patternText)) {
      return true;
    }

    return pathText.startsWith('$patternText/');
  }

  static RegExp _buildRegex(String pattern) {
    final buffer = StringBuffer('^');

    for (final rune in pattern.runes) {
      final char = String.fromCharCode(rune);
      switch (char) {
        case '*':
          buffer.write('[^/]*');
          break;
        case '?':
          buffer.write('[^/]');
          break;
        default:
          buffer.write(RegExp.escape(char));
      }
    }

    buffer.write(r'$');
    return RegExp(buffer.toString(), caseSensitive: !Platform.isWindows);
  }

  static String _trimTrailingSeparators(String value) {
    var result = value;
    while (result.endsWith(p.separator)) {
      result = result.substring(0, result.length - p.separator.length);
    }
    return result;
  }

  static String _toPosix(String value) {
    return value.replaceAll('\\', '/');
  }

  static bool _equals(String left, String right) {
    if (Platform.isWindows) {
      return left.toLowerCase() == right.toLowerCase();
    }
    return left == right;
  }
}

Future<List<IgnoreRule>> loadIgnoreRules(String targetPath) async {
  final rules = [
    for (final ignoredDir in ignoredDirs)
      IgnoreRule.defaultDirectory(ignoredDir),
  ];

  final ignoreFile = File(p.join(targetPath, dmcIgnoreFileName));
  if (!await ignoreFile.exists()) return rules;

  var userRuleCount = 0;
  for (final line in await ignoreFile.readAsLines()) {
    final rule = IgnoreRule.fromPattern(line);
    if (rule == null) continue;

    rules.add(rule);
    userRuleCount++;
  }

  if (userRuleCount > 0) {
    print('[DMC] Loaded $userRuleCount ignore rule(s) from $dmcIgnoreFileName');
  }

  return rules;
}

/// Watches a directory for file changes and backs up modified files
class DmcWatcher {
  final String targetPath;
  final DmcDatabase database;
  final String snapshotsPath;
  final List<IgnoreRule> ignoreRules;

  final Map<String, Timer> _pendingBackups = {};
  late final String _normalizedTargetPath;
  StreamSubscription<FileSystemEvent>? _watchSubscription;
  bool _isRunning = false;

  DmcWatcher({
    required this.targetPath,
    required this.database,
    required this.snapshotsPath,
    required this.ignoreRules,
  }) {
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

    final filePath = p.normalize(event.path);

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

  bool _isIgnored(String filePath) {
    final relativePath = p.normalize(
      p.relative(filePath, from: _normalizedTargetPath),
    );

    if (relativePath == '..' || relativePath.startsWith('..${p.separator}')) {
      return false;
    }

    for (final rule in ignoreRules) {
      if (rule.matches(relativePath)) {
        return true;
      }
    }

    return false;
  }

  /// Perform the backup for a file
  Future<void> _performBackup(String filePath) async {
    _pendingBackups.remove(filePath);

    // Calculate relative path from target directory
    final relativePath = p.normalize(
      p.relative(filePath, from: _normalizedTargetPath),
    );

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
  final normalizedCwd = p.normalize(cwd);
  final dmcPath = p.join(normalizedCwd, dmcDirName);
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

  final prunedCount = await db.pruneOldSnapshots(snapshotRetention);
  if (prunedCount > 0) {
    print('[DMC] Pruned $prunedCount expired snapshot(s)');
  }

  final ignoreRules = await loadIgnoreRules(normalizedCwd);

  // Create watcher
  final watcher = DmcWatcher(
    targetPath: normalizedCwd,
    database: db,
    snapshotsPath: snapshotsPath,
    ignoreRules: ignoreRules,
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
