import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Database manager for DMC's SQLite storage
class DmcDatabase {
  final String dbPath;
  Database? _db;

  DmcDatabase(this.dbPath);

  /// Get the underlying database instance
  Database get db {
    if (_db == null) {
      throw StateError('Database not initialized. Call initialize() first.');
    }
    return _db!;
  }

  /// Initialize the database and create tables if they don't exist
  void initialize() {
    _db = sqlite3.open(dbPath);

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_path TEXT NOT NULL,
        snapshot_path TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        hash TEXT NOT NULL
      )
    ''');
  }

  /// Close the database connection
  void close() {
    _db?.close();
    _db = null;
  }

  /// Check if the history table exists
  bool get isInitialized {
    if (_db == null) return false;
    try {
      final result = _db!.select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='history'",
      );
      return result.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Get the latest snapshot for a given file path
  /// Returns (snapshot_path, hash) or null if no previous snapshot exists
  ({String snapshotPath, String hash})? getLatestSnapshot(String filePath) {
    if (_db == null) return null;

    final result = _db!.select(
      'SELECT snapshot_path, hash FROM history WHERE file_path = ? ORDER BY timestamp DESC LIMIT 1',
      [filePath],
    );

    if (result.isEmpty) return null;

    return (
      snapshotPath: result.first['snapshot_path'] as String,
      hash: result.first['hash'] as String,
    );
  }

  /// Insert a new snapshot record
  void insertSnapshot({
    required String filePath,
    required String snapshotPath,
    required int timestamp,
    required String hash,
  }) {
    _db!.execute(
      'INSERT INTO history (file_path, snapshot_path, timestamp, hash) VALUES (?, ?, ?, ?)',
      [filePath, snapshotPath, timestamp, hash],
    );
  }

  /// Get recent backup logs
  /// Returns list of (file_path, snapshot_path, timestamp, hash) ordered by timestamp desc
  List<({String filePath, String snapshotPath, int timestamp, String hash})>
  getRecentLogs({int limit = 10}) {
    if (_db == null) return [];

    final result = _db!.select(
      'SELECT file_path, snapshot_path, timestamp, hash FROM history ORDER BY timestamp DESC LIMIT ?',
      [limit],
    );

    return result
        .map(
          (row) => (
            filePath: row['file_path'] as String,
            snapshotPath: row['snapshot_path'] as String,
            timestamp: row['timestamp'] as int,
            hash: row['hash'] as String,
          ),
        )
        .toList();
  }

  /// Get the most recent snapshot for a specific file path whose hash differs
  /// from the current working file.
  /// Returns (snapshot_path, timestamp) or null if no previous snapshot exists
  ({String snapshotPath, int timestamp})? getSnapshotForRestore(
    String filePath,
    String currentHash,
  ) {
    if (_db == null) return null;

    final result = _db!.select(
      'SELECT snapshot_path, timestamp FROM history WHERE file_path = ? AND hash != ? ORDER BY timestamp DESC LIMIT 1',
      [filePath, currentHash],
    );

    if (result.isEmpty) return null;

    return (
      snapshotPath: result.first['snapshot_path'] as String,
      timestamp: result.first['timestamp'] as int,
    );
  }

  /// Delete snapshots and history rows older than [maxAge].
  Future<int> pruneOldSnapshots(Duration maxAge) async {
    if (_db == null) return 0;

    final cutoff = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    final expiredRows = _db!.select(
      'SELECT snapshot_path FROM history WHERE timestamp < ?',
      [cutoff],
    );

    if (expiredRows.isEmpty) return 0;

    final snapshotsPath = p.join(p.dirname(dbPath), 'snapshots');

    for (final row in expiredRows) {
      final snapshotFile = File(
        p.join(snapshotsPath, row['snapshot_path'] as String),
      );

      try {
        await snapshotFile.delete();
      } on FileSystemException {
        // Ignore missing or manually deleted snapshot files.
      }
    }

    _db!.execute('DELETE FROM history WHERE timestamp < ?', [cutoff]);
    return expiredRows.length;
  }
}
