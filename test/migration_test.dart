import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dmc/dmc.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late DmcPaths paths;
  setUp(() {
    root = Directory.systemTemp.createTempSync('dmc_migration_');
    paths = DmcPaths(basePath: root.path);
    Directory(paths.snapshotsPath).createSync(recursive: true);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'legacy history migrates in place, restores, and writes legacy audit columns',
    () async {
      final legacy = sqlite.sqlite3.open(paths.dbPath);
      legacy.execute(
        'CREATE TABLE history (id INTEGER PRIMARY KEY AUTOINCREMENT, file_path TEXT NOT NULL, snapshot_path TEXT NOT NULL, timestamp INTEGER NOT NULL, hash TEXT NOT NULL)',
      );
      legacy.execute(
        'CREATE TABLE restore_events (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER NOT NULL, command_name TEXT NOT NULL, file_path TEXT NOT NULL, snapshot_id INTEGER NOT NULL, success INTEGER NOT NULL, failure_message TEXT)',
      );
      final hash = sha256.convert(utf8.encode('legacy contents')).toString();
      legacy.execute('INSERT INTO history VALUES (?, ?, ?, ?, ?)', [
        42,
        'notes.txt',
        'legacy.bak',
        1,
        hash,
      ]);
      legacy.execute(
        'INSERT INTO restore_events VALUES (?, ?, ?, ?, ?, ?, ?)',
        [9, 2, 'undo', 'notes.txt', 42, 1, null],
      );
      legacy.close();
      File(
        p.join(paths.snapshotsPath, 'legacy.bak'),
      ).writeAsStringSync('legacy contents');
      final target = File(p.join(root.path, 'notes.txt'))
        ..writeAsStringSync('new work');
      final db = DmcDatabase(paths.dbPath)..initialize();
      try {
        expect(db.db.select('PRAGMA user_version').first.values.first, 3);
        expect(db.db.select('PRAGMA foreign_keys').first.values.first, 1);
        expect(db.db.select('PRAGMA synchronous').first.values.first, 2);
        expect(db.getSnapshotById(42)!.hash, hash);
        expect(db.getRecentRestoreEvents().single.command, 'undo');
        db.initialize();
        expect(db.getHistoryCount(), 1);
        expect(
          db.db
              .select(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'checkpoint%' ORDER BY name",
              )
              .map((row) => row['name']),
          containsAll(['checkpoint_files', 'checkpoint_issues', 'checkpoints']),
        );
      } finally {
        db.close();
      }
      expect(
        (await restoreFile('notes.txt', id: 42, basePath: root.path)).hadError,
        isFalse,
      );
      expect(target.readAsStringSync(), 'legacy contents');
      db.initialize();
      try {
        expect(db.getSnapshotById(42)!.snapshotPath, 'legacy.bak');
        expect(db.getRecentRestoreEvents().first.success, isTrue);
        final event = db.db
            .select(
              'SELECT command, command_name FROM restore_events ORDER BY id DESC LIMIT 1',
            )
            .single;
        expect(event['command'], 'restore');
        expect(event['command_name'], 'restore');
      } finally {
        db.close();
      }
      expect(
        (await redoFile('notes.txt', basePath: root.path)).hadError,
        isFalse,
      );
      expect(target.readAsStringSync(), 'new work');
    },
  );

  test('migration failure rolls back schema changes and keeps version zero', () {
    final legacy = sqlite.sqlite3.open(paths.dbPath);
    legacy.execute(
      'CREATE TABLE history (id INTEGER PRIMARY KEY, file_path TEXT, snapshot_path TEXT, timestamp INTEGER, hash TEXT)',
    );
    legacy.execute('CREATE VIEW restore_events AS SELECT 1 AS id');
    legacy.close();
    final db = DmcDatabase(paths.dbPath);
    expect(db.initialize, throwsA(isA<Exception>()));
    expect(db.isInitialized, isFalse);
    final inspection = sqlite.sqlite3.open(paths.dbPath);
    try {
      expect(inspection.select('PRAGMA user_version').first.values.first, 0);
      expect(
        inspection
            .select('PRAGMA table_info(history)')
            .map((row) => row['name']),
        isNot(contains('burst_id')),
      );
      expect(
        inspection.select(
          "SELECT name FROM sqlite_master WHERE name = 'marks'",
        ),
        isEmpty,
      );
    } finally {
      inspection.close();
    }
  });

  test(
    'version 1 vault migrates checkpoint schema without rewriting history',
    () {
      final versionOne = sqlite.sqlite3.open(paths.dbPath);
      versionOne.execute('''
      CREATE TABLE history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_path TEXT NOT NULL,
        snapshot_path TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        hash TEXT NOT NULL,
        burst_id INTEGER,
        task_name TEXT
      )
    ''');
      versionOne.execute(
        "INSERT INTO history (id, file_path, snapshot_path, timestamp, hash) VALUES (7, 'keep.txt', 'keep.bak', 10, 'hash')",
      );
      versionOne.execute('''
      CREATE TABLE marks (
        name TEXT PRIMARY KEY, burst_id INTEGER NOT NULL, created_at INTEGER NOT NULL
      )
    ''');
      versionOne.execute('''
      CREATE TABLE restore_events (
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
      versionOne.execute('PRAGMA user_version = 1');
      versionOne.close();

      final migrated = DmcDatabase(paths.dbPath)..initialize();
      expect(migrated.db.select('PRAGMA user_version').single.values.first, 3);
      expect(migrated.getSnapshotById(7)!.filePath, 'keep.txt');
      expect(
        migrated.db.select(
          "SELECT name FROM sqlite_master WHERE name = 'checkpoints'",
        ),
        isNotEmpty,
      );
      expect(
        migrated.db.select(
          "SELECT name FROM sqlite_master WHERE name = 'checkpoint_operations'",
        ),
        isNotEmpty,
      );
      migrated.close();
    },
  );

  test('version 2 vault adds operation journals without rewriting data', () {
    final initial = DmcDatabase(paths.dbPath)..initialize();
    initial.insertSnapshot(
      filePath: 'keep.txt',
      snapshotPath: 'keep.bak',
      timestamp: 10,
      hash: 'keep-hash',
    );
    initial.close();
    final versionTwo = sqlite.sqlite3.open(paths.dbPath);
    versionTwo.execute('DROP TABLE checkpoint_operation_files');
    versionTwo.execute('DROP TABLE checkpoint_operations');
    versionTwo.execute('ALTER TABLE checkpoint_files DROP COLUMN before_mode');
    versionTwo.execute('ALTER TABLE checkpoint_files DROP COLUMN after_mode');
    versionTwo.execute('PRAGMA user_version = 2');
    versionTwo.close();

    final migrated = DmcDatabase(paths.dbPath)..initialize();
    expect(migrated.db.select('PRAGMA user_version').single.values.first, 3);
    expect(migrated.getHistoryCount(), 1);
    expect(
      migrated.db.select(
        "SELECT name FROM sqlite_master WHERE name IN ('checkpoint_operations', 'checkpoint_operation_files')",
      ),
      hasLength(2),
    );
    migrated.close();
  });

  test('newer schema is rejected without adding or rewriting tables', () {
    final future = sqlite.sqlite3.open(paths.dbPath);
    future.execute('PRAGMA user_version = 999');
    future.execute('CREATE TABLE future_data (value TEXT)');
    future.execute("INSERT INTO future_data VALUES ('keep')");
    future.close();
    final db = DmcDatabase(paths.dbPath);
    expect(db.initialize, throwsStateError);
    final inspection = sqlite.sqlite3.open(paths.dbPath);
    try {
      expect(inspection.select('PRAGMA user_version').first.values.first, 999);
      expect(
        inspection.select('SELECT value FROM future_data').single['value'],
        'keep',
      );
      expect(
        inspection.select(
          "SELECT name FROM sqlite_master WHERE name = 'history'",
        ),
        isEmpty,
      );
    } finally {
      inspection.close();
    }
  });
}
