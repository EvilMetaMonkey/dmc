import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const String tombstoneHash = 'TOMBSTONE';
const String tombstoneSnapshotPath = '__TOMBSTONE__';

bool isTombstoneSnapshot({required String hash, required String snapshotPath}) {
  return hash == tombstoneHash || snapshotPath == tombstoneSnapshotPath;
}

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
        hash TEXT NOT NULL,
        burst_id INTEGER,
        task_name TEXT
      )
    ''');

    final historyColumns = _db!.select('PRAGMA table_info(history)');
    final hasBurstIdColumn = historyColumns.any(
      (row) => row['name'] == 'burst_id',
    );
    final hasTaskNameColumn = historyColumns.any(
      (row) => row['name'] == 'task_name',
    );

    if (!hasBurstIdColumn) {
      _db!.execute('ALTER TABLE history ADD COLUMN burst_id INTEGER');
    }
    if (!hasTaskNameColumn) {
      _db!.execute('ALTER TABLE history ADD COLUMN task_name TEXT');
    }

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS marks (
        name TEXT PRIMARY KEY,
        burst_id INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS restore_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp INTEGER NOT NULL,
        command TEXT NOT NULL,
        file_path TEXT NOT NULL,
        snapshot_id INTEGER NOT NULL,
        success INTEGER NOT NULL,
        failure_message TEXT,
        overwritten_snapshot_id INTEGER
      )
    ''');

    final restoreEventColumns = _db!.select(
      'PRAGMA table_info(restore_events)',
    );
    final hasCommandColumn = restoreEventColumns.any(
      (row) => row['name'] == 'command',
    );
    final hasLegacyCommandNameColumn = restoreEventColumns.any(
      (row) => row['name'] == 'command_name',
    );
    final hasOverwrittenSnapshotIdColumn = restoreEventColumns.any(
      (row) => row['name'] == 'overwritten_snapshot_id',
    );

    if (!hasCommandColumn) {
      _db!.execute('ALTER TABLE restore_events ADD COLUMN command TEXT');
    }

    if (hasLegacyCommandNameColumn) {
      _db!.execute(
        'UPDATE restore_events SET command = command_name WHERE command IS NULL',
      );
    }

    if (!hasOverwrittenSnapshotIdColumn) {
      _db!.execute(
        'ALTER TABLE restore_events ADD COLUMN overwritten_snapshot_id INTEGER',
      );
    }
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
  /// Returns snapshot metadata or null if no previous snapshot exists.
  ({int id, String snapshotPath, int timestamp, String hash, int? burstId})?
  getLatestSnapshot(String filePath) {
    if (_db == null) return null;

    final result = _db!.select(
      'SELECT id, snapshot_path, timestamp, hash, burst_id FROM history WHERE file_path = ? ORDER BY timestamp DESC, id DESC LIMIT 1',
      [filePath],
    );

    if (result.isEmpty) return null;

    return (
      id: result.first['id'] as int,
      snapshotPath: result.first['snapshot_path'] as String,
      timestamp: result.first['timestamp'] as int,
      hash: result.first['hash'] as String,
      burstId: result.first['burst_id'] as int?,
    );
  }

  /// Insert a new snapshot record
  void insertSnapshot({
    required String filePath,
    required String snapshotPath,
    required int timestamp,
    required String hash,
    int? burstId,
    String? taskName,
  }) {
    _db!.execute(
      'INSERT INTO history (file_path, snapshot_path, timestamp, hash, burst_id, task_name) VALUES (?, ?, ?, ?, ?, ?)',
      [filePath, snapshotPath, timestamp, hash, burstId, taskName],
    );
  }

  void insertTombstone({
    required String filePath,
    required int timestamp,
    int? burstId,
    String? taskName,
  }) {
    insertSnapshot(
      filePath: filePath,
      snapshotPath: tombstoneSnapshotPath,
      timestamp: timestamp,
      hash: tombstoneHash,
      burstId: burstId,
      taskName: taskName,
    );
  }

  /// Get recent backup history ordered by timestamp descending.
  List<
    ({
      int id,
      String filePath,
      String snapshotPath,
      int timestamp,
      String hash,
      int? burstId,
      String? taskName,
    })
  >
  getRecentHistory({int limit = 10}) {
    if (_db == null) return [];

    final result = _db!.select(
      'SELECT id, file_path, snapshot_path, timestamp, hash, burst_id, task_name FROM history ORDER BY timestamp DESC LIMIT ?',
      [limit],
    );

    return result
        .map(
          (row) => (
            id: row['id'] as int,
            filePath: row['file_path'] as String,
            snapshotPath: row['snapshot_path'] as String,
            timestamp: row['timestamp'] as int,
            hash: row['hash'] as String,
            burstId: row['burst_id'] as int?,
            taskName: row['task_name'] as String?,
          ),
        )
        .toList();
  }

  /// Backwards-compatible alias for recent history retrieval.
  List<
    ({
      int id,
      String filePath,
      String snapshotPath,
      int timestamp,
      String hash,
      int? burstId,
      String? taskName,
    })
  >
  getRecentLogs({int limit = 10}) {
    return getRecentHistory(limit: limit);
  }

  int getHistoryCount() {
    if (_db == null) return 0;

    final result = _db!.select('SELECT COUNT(*) AS count FROM history');
    return result.first['count'] as int;
  }

  List<({String filePath, String snapshotPath, String hash})>
  getAllSnapshotRecords() {
    if (_db == null) return [];

    final result = _db!.select(
      'SELECT file_path, snapshot_path, hash FROM history',
    );

    return result
        .map(
          (row) => (
            filePath: row['file_path'] as String,
            snapshotPath: row['snapshot_path'] as String,
            hash: row['hash'] as String,
          ),
        )
        .toList();
  }

  /// Get all snapshots associated with a specific burst id.
  List<
    ({
      int id,
      String filePath,
      String snapshotPath,
      int timestamp,
      String hash,
      int? burstId,
      String? taskName,
    })
  >
  getSnapshotsForBurst(int burstId) {
    if (_db == null) return [];

    final result = _db!.select(
      '''
      SELECT id, file_path, snapshot_path, timestamp, hash, burst_id, task_name
      FROM history
      WHERE burst_id = ?
      ORDER BY timestamp DESC, id DESC
      ''',
      [burstId],
    );

    return result
        .map(
          (row) => (
            id: row['id'] as int,
            filePath: row['file_path'] as String,
            snapshotPath: row['snapshot_path'] as String,
            timestamp: row['timestamp'] as int,
            hash: row['hash'] as String,
            burstId: row['burst_id'] as int?,
            taskName: row['task_name'] as String?,
          ),
        )
        .toList();
  }

  List<
    ({
      int id,
      String filePath,
      String snapshotPath,
      int timestamp,
      String hash,
      int? burstId,
      String? taskName,
    })
  >
  getSnapshotsForTask(String taskName) {
    if (_db == null) return [];

    final result = _db!.select(
      '''
      SELECT id, file_path, snapshot_path, timestamp, hash, burst_id, task_name
      FROM history
      WHERE task_name = ?
      ORDER BY timestamp DESC, id DESC
      ''',
      [taskName],
    );

    return result
        .map(
          (row) => (
            id: row['id'] as int,
            filePath: row['file_path'] as String,
            snapshotPath: row['snapshot_path'] as String,
            timestamp: row['timestamp'] as int,
            hash: row['hash'] as String,
            burstId: row['burst_id'] as int?,
            taskName: row['task_name'] as String?,
          ),
        )
        .toList();
  }

  /// Get a specific snapshot by database id.
  ({int id, String filePath, String snapshotPath, int timestamp, String hash})?
  getSnapshotById(int id) {
    if (_db == null) return null;

    final result = _db!.select(
      'SELECT id, file_path, snapshot_path, timestamp, hash FROM history WHERE id = ? LIMIT 1',
      [id],
    );

    if (result.isEmpty) return null;

    return (
      id: result.first['id'] as int,
      filePath: result.first['file_path'] as String,
      snapshotPath: result.first['snapshot_path'] as String,
      timestamp: result.first['timestamp'] as int,
      hash: result.first['hash'] as String,
    );
  }

  int? getLatestBurstId() {
    if (_db == null) return null;

    final result = _db!.select(
      'SELECT burst_id FROM history WHERE burst_id IS NOT NULL ORDER BY timestamp DESC, id DESC LIMIT 1',
    );

    if (result.isEmpty) return null;
    return result.first['burst_id'] as int?;
  }

  void upsertMark({
    required String name,
    required int burstId,
    required int createdAt,
  }) {
    _db!.execute(
      '''
      INSERT INTO marks (name, burst_id, created_at)
      VALUES (?, ?, ?)
      ON CONFLICT(name) DO UPDATE SET
        burst_id = excluded.burst_id,
        created_at = excluded.created_at
      ''',
      [name, burstId, createdAt],
    );
  }

  List<({String name, int burstId, int createdAt})> getMarks() {
    if (_db == null) return [];

    final result = _db!.select(
      'SELECT name, burst_id, created_at FROM marks ORDER BY created_at DESC, name ASC',
    );

    return result
        .map(
          (row) => (
            name: row['name'] as String,
            burstId: row['burst_id'] as int,
            createdAt: row['created_at'] as int,
          ),
        )
        .toList();
  }

  ({String name, int burstId, int createdAt})? getMarkByName(String name) {
    if (_db == null) return null;

    final result = _db!.select(
      'SELECT name, burst_id, created_at FROM marks WHERE name = ? LIMIT 1',
      [name],
    );

    if (result.isEmpty) return null;

    return (
      name: result.first['name'] as String,
      burstId: result.first['burst_id'] as int,
      createdAt: result.first['created_at'] as int,
    );
  }

  /// Get the most recent snapshot for a specific file path whose hash differs
  /// from the current working file.
  /// Returns (snapshot_path, timestamp) or null if no previous snapshot exists
  ({int id, String snapshotPath, int timestamp, String hash})?
  getSnapshotForRestore(String filePath, String currentHash) {
    if (_db == null) return null;

    final result = _db!.select(
      'SELECT id, snapshot_path, timestamp, hash FROM history WHERE file_path = ? AND hash != ? ORDER BY timestamp DESC, id DESC LIMIT 1',
      [filePath, currentHash],
    );

    if (result.isEmpty) return null;

    return (
      id: result.first['id'] as int,
      snapshotPath: result.first['snapshot_path'] as String,
      timestamp: result.first['timestamp'] as int,
      hash: result.first['hash'] as String,
    );
  }

  /// Insert a restore event record.
  void insertRestoreEvent({
    required int timestamp,
    required String command,
    required String filePath,
    required int snapshotId,
    required bool success,
    String? failureMessage,
    int? overwrittenSnapshotId,
  }) {
    _db!.execute(
      'INSERT INTO restore_events (timestamp, command, file_path, snapshot_id, success, failure_message, overwritten_snapshot_id) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        timestamp,
        command,
        filePath,
        snapshotId,
        success ? 1 : 0,
        failureMessage,
        overwrittenSnapshotId,
      ],
    );
  }

  /// Get recent restore audit records ordered by timestamp descending.
  List<
    ({
      int id,
      int timestamp,
      String command,
      String filePath,
      int snapshotId,
      bool success,
      String? failureMessage,
      int? overwrittenSnapshotId,
    })
  >
  getRecentRestoreEvents({int limit = 10}) {
    if (_db == null) return [];

    final result = _db!.select(
      'SELECT id, timestamp, command, file_path, snapshot_id, success, failure_message, overwritten_snapshot_id FROM restore_events ORDER BY timestamp DESC LIMIT ?',
      [limit],
    );

    return result
        .map(
          (row) => (
            id: row['id'] as int,
            timestamp: row['timestamp'] as int,
            command: row['command'] as String,
            filePath: row['file_path'] as String,
            snapshotId: row['snapshot_id'] as int,
            success: (row['success'] as int) == 1,
            failureMessage: row['failure_message'] as String?,
            overwrittenSnapshotId: row['overwritten_snapshot_id'] as int?,
          ),
        )
        .toList();
  }

  ({
    int id,
    int timestamp,
    String command,
    String filePath,
    int snapshotId,
    bool success,
    String? failureMessage,
    int? overwrittenSnapshotId,
  })?
  getLatestRedoSourceEvent(String filePath) {
    if (_db == null) return null;

    final result = _db!.select(
      '''
      SELECT id, timestamp, command, file_path, snapshot_id, success,
             failure_message, overwritten_snapshot_id
      FROM restore_events
      WHERE file_path = ?
        AND success = 1
        AND command IN ('undo', 'restore')
      ORDER BY timestamp DESC, id DESC
      LIMIT 1
      ''',
      [filePath],
    );

    if (result.isEmpty) return null;

    return (
      id: result.first['id'] as int,
      timestamp: result.first['timestamp'] as int,
      command: result.first['command'] as String,
      filePath: result.first['file_path'] as String,
      snapshotId: result.first['snapshot_id'] as int,
      success: (result.first['success'] as int) == 1,
      failureMessage: result.first['failure_message'] as String?,
      overwrittenSnapshotId: result.first['overwritten_snapshot_id'] as int?,
    );
  }

  List<({String snapshotPath, String hash})> getExpiredSnapshotRecords(
    Duration maxAge,
  ) {
    if (_db == null) return [];

    final cutoff = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    final result = _db!.select(
      'SELECT snapshot_path, hash FROM history WHERE timestamp < ?',
      [cutoff],
    );

    return result
        .map(
          (row) => (
            snapshotPath: row['snapshot_path'] as String,
            hash: row['hash'] as String,
          ),
        )
        .toList();
  }

  /// Delete snapshots and history rows older than [maxAge].
  Future<int> pruneOldSnapshots(Duration maxAge) async {
    if (_db == null) return 0;

    final cutoff = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    final expiredRows = getExpiredSnapshotRecords(maxAge);

    if (expiredRows.isEmpty) return 0;

    final snapshotsPath = p.join(p.dirname(dbPath), 'snapshots');

    for (final row in expiredRows) {
      final snapshotPath = row.snapshotPath;
      if (isTombstoneSnapshot(hash: row.hash, snapshotPath: snapshotPath)) {
        continue;
      }

      final snapshotFile = File(p.join(snapshotsPath, snapshotPath));

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
