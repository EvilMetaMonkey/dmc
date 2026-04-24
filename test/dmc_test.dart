import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dmc/dmc.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

Future<List<String>> capturePrints<T>(FutureOr<T> Function() action) async {
  final output = <String>[];

  await runZoned(
    action,
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, String message) {
        output.add(message);
      },
    ),
  );

  return output;
}

Future<T> withCurrentDirectory<T>(
  String path,
  Future<T> Function() action,
) async {
  final originalPath = Directory.current.path;
  Directory.current = path;
  try {
    return await action();
  } finally {
    Directory.current = originalPath;
  }
}

String hashText(String text) {
  return sha256.convert(utf8.encode(text)).toString();
}

int insertSnapshotAndGetId(
  DmcDatabase db, {
  required String filePath,
  required String snapshotPath,
  required int timestamp,
  required String hash,
  int? burstId,
  String? taskName,
}) {
  db.insertSnapshot(
    filePath: filePath,
    snapshotPath: snapshotPath,
    timestamp: timestamp,
    hash: hash,
    burstId: burstId,
    taskName: taskName,
  );
  return db.db.lastInsertRowId;
}

List<RestoreEvent> loadRestoreEvents(String basePath, {int limit = 10}) {
  final db = DmcDatabase(p.join(basePath, '.dmc', 'dmc.db'));
  db.initialize();
  final events = RestoreEventRepository(db).getRecentEvents(limit: limit);
  db.close();
  return events;
}

class FakeDaemonProcessState {
  final Set<int> runningPids = <int>{};
  int nextPid;
  int spawnCount = 0;
  int killCount = 0;

  FakeDaemonProcessState({this.nextPid = 4100});

  DaemonPlatform get platform => DaemonPlatform(
    spawnDetachedProcess:
        (
          String executable,
          List<String> arguments, {
          required String workingDirectory,
        }) async {
          spawnCount++;
          final pid = nextPid++;
          runningPids.add(pid);
          return pid;
        },
    isPidRunning: (int pid) async => runningPids.contains(pid),
    killPid: (int pid) {
      killCount++;
      return runningPids.remove(pid);
    },
  );
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dmc_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('DMC Initialization', () {
    test('initDmc creates .dmc directory', () async {
      final dmcPath = p.join(tempDir.path, '.dmc');

      await initDmc(basePath: tempDir.path);

      final dmcDir = Directory(dmcPath);
      expect(await dmcDir.exists(), isTrue);
    });

    test('initDmc creates snapshots subdirectory', () async {
      final snapshotsPath = p.join(tempDir.path, '.dmc', 'snapshots');

      await initDmc(basePath: tempDir.path);

      final snapshotsDir = Directory(snapshotsPath);
      expect(await snapshotsDir.exists(), isTrue);
    });

    test('initDmc creates SQLite database file', () async {
      final dbPath = p.join(tempDir.path, '.dmc', 'dmc.db');

      await initDmc(basePath: tempDir.path);

      final dbFile = File(dbPath);
      expect(await dbFile.exists(), isTrue);
    });

    test('initDmc creates history table with correct schema', () async {
      final dbPath = p.join(tempDir.path, '.dmc', 'dmc.db');

      await initDmc(basePath: tempDir.path);

      final db = DmcDatabase(dbPath);
      db.initialize();

      expect(db.isInitialized, isTrue);

      db.close();
    });

    test('initialize migrates legacy history rows to include burst_id', () async {
      final dmcPath = p.join(tempDir.path, '.dmc');
      await Directory(dmcPath).create(recursive: true);
      final dbPath = p.join(dmcPath, 'dmc.db');

      final legacyDb = sqlite.sqlite3.open(dbPath);
      legacyDb.execute('''
        CREATE TABLE history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          file_path TEXT NOT NULL,
          snapshot_path TEXT NOT NULL,
          timestamp INTEGER NOT NULL,
          hash TEXT NOT NULL
        )
      ''');
      legacyDb.execute(
        'INSERT INTO history (file_path, snapshot_path, timestamp, hash) VALUES (?, ?, ?, ?)',
        ['notes.txt', 'notes_1.bak', 123, 'hash1'],
      );
      legacyDb.close();

      final db = DmcDatabase(dbPath);
      db.initialize();
      final columns = db.db.select('PRAGMA table_info(history)');
      final columnNames = columns
          .map((column) => column['name'] as String)
          .toList();
      final logs = db.getRecentHistory();

      expect(columnNames, contains('burst_id'));
      expect(logs, hasLength(1));
      expect(logs.first.filePath, 'notes.txt');
      expect(logs.first.burstId, isNull);

      db.close();
    });

    test(
      'initDmc creates restore_events table with requested columns',
      () async {
        final dbPath = p.join(tempDir.path, '.dmc', 'dmc.db');

        await initDmc(basePath: tempDir.path);

        final db = DmcDatabase(dbPath);
        db.initialize();
        final columns = db.db.select('PRAGMA table_info(restore_events)');
        final columnNames = columns
            .map((column) => column['name'] as String)
            .toList();

        expect(
          columnNames,
          containsAll([
            'id',
            'timestamp',
            'command',
            'file_path',
            'snapshot_id',
            'success',
            'failure_message',
            'overwritten_snapshot_id',
          ]),
        );

        db.close();
      },
    );

    test('initialize migrates legacy restore_events command_name data', () async {
      final dmcPath = p.join(tempDir.path, '.dmc');
      await Directory(dmcPath).create(recursive: true);
      final dbPath = p.join(dmcPath, 'dmc.db');

      final legacyDb = sqlite.sqlite3.open(dbPath);
      legacyDb.execute('''
        CREATE TABLE restore_events (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp INTEGER NOT NULL,
          command_name TEXT NOT NULL,
          file_path TEXT NOT NULL,
          snapshot_id INTEGER NOT NULL,
          success INTEGER NOT NULL,
          failure_message TEXT
        )
      ''');
      legacyDb.execute(
        'INSERT INTO restore_events (timestamp, command_name, file_path, snapshot_id, success, failure_message) VALUES (?, ?, ?, ?, ?, ?)',
        [123, 'undo', 'notes.txt', 7, 1, null],
      );
      legacyDb.close();

      final db = DmcDatabase(dbPath);
      db.initialize();
      final columns = db.db.select('PRAGMA table_info(restore_events)');
      final columnNames = columns
          .map((column) => column['name'] as String)
          .toList();
      final events = RestoreEventRepository(db).getRecentEvents();

      expect(columnNames, contains('command'));
      expect(columnNames, contains('overwritten_snapshot_id'));
      expect(events, hasLength(1));
      expect(events.first.command, 'undo');
      expect(events.first.filePath, 'notes.txt');
      expect(events.first.snapshotId, 7);
      expect(events.first.success, isTrue);
      expect(events.first.overwrittenSnapshotId, isNull);

      db.close();
    });

    test('initialize enables SQLite WAL mode and a busy timeout', () async {
      final dbPath = p.join(tempDir.path, '.dmc', 'dmc.db');

      await initDmc(basePath: tempDir.path);

      final db = DmcDatabase(dbPath);
      db.initialize();
      final journalMode = db.db
          .select('PRAGMA journal_mode')
          .first['journal_mode'];
      final busyTimeout = db.db
          .select('PRAGMA busy_timeout')
          .first['timeout'];

      expect('$journalMode'.toLowerCase(), 'wal');
      expect(busyTimeout, greaterThanOrEqualTo(5000));

      db.close();
    });

    test('initDmc creates all required components', () async {
      await initDmc(basePath: tempDir.path);

      final dmcPath = p.join(tempDir.path, '.dmc');
      final snapshotsPath = p.join(dmcPath, 'snapshots');
      final dbPath = p.join(dmcPath, 'dmc.db');

      expect(await Directory(dmcPath).exists(), isTrue);
      expect(await Directory(snapshotsPath).exists(), isTrue);
      expect(await File(dbPath).exists(), isTrue);
    });
  });

  group('DMC Ignore Rules', () {
    test(
      'loadIgnoreRules combines defaults with .dmcignore patterns',
      () async {
        final ignoreFile = File(p.join(tempDir.path, '.dmcignore'));
        await ignoreFile.writeAsString('''
# Ignore generated files

lib/generated/
logs\\temp.txt
''');

        final rules = await loadIgnoreRules(tempDir.path);

        expect(
          rules.any((rule) => rule.matches(p.join('.git', 'config'))),
          isTrue,
        );
        expect(
          rules.any(
            (rule) => rule.matches(p.join('lib', 'generated', 'model.dart')),
          ),
          isTrue,
        );
        expect(
          rules.any((rule) => rule.matches(p.join('logs', 'temp.txt'))),
          isTrue,
        );
        expect(rules.any((rule) => rule.matches('README.md')), isFalse);
      },
    );

    test('loadIgnoreRules merges .gitignore rules when present', () async {
      final gitIgnoreFile = File(p.join(tempDir.path, '.gitignore'));
      await gitIgnoreFile.writeAsString('''
dist/
*.log
''');

      final rules = await loadIgnoreRules(tempDir.path);

      expect(
        rules.any((rule) => rule.matches(p.join('dist', 'bundle.js'))),
        isTrue,
      );
      expect(rules.any((rule) => rule.matches('server.log')), isTrue);
    });
  });

  group('DMC Config', () {
    test('loadDmcConfig merges global config with local overrides', () async {
      await initDmc(basePath: tempDir.path);

      final homeDir = await Directory.systemTemp.createTemp('dmc_home_');
      addTearDown(() async {
        if (await homeDir.exists()) {
          await homeDir.delete(recursive: true);
        }
      });

      await File(p.join(homeDir.path, globalConfigFileName)).writeAsString('''
{"retention_hours":72,"max_file_size_kb":512}
''');
      await File(p.join(tempDir.path, '.dmc', 'config.json')).writeAsString('''
{"max_file_size_kb":1024}
''');

      final config = await loadDmcConfig(
        basePath: tempDir.path,
        homePath: homeDir.path,
      );

      expect(config.retentionHours, 72);
      expect(config.maxFileSizeKb, 1024);
      expect(config.hasGlobalConfig, isTrue);
      expect(config.hasLocalConfig, isTrue);
    });

    test('loadDmcConfig rejects unsafe retention and max file size values', () async {
      await initDmc(basePath: tempDir.path);

      final configFile = File(p.join(tempDir.path, '.dmc', 'config.json'));

      await configFile.writeAsString('{"retention_hours":0}');
      expect(
        loadDmcConfig(basePath: tempDir.path, homePath: tempDir.path),
        throwsA(isA<FormatException>()),
      );

      await configFile.writeAsString('{"max_file_size_kb":0}');
      expect(
        loadDmcConfig(basePath: tempDir.path, homePath: tempDir.path),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('DMC Tasks', () {
    test('startTask and endTask control task_name assignment', () async {
      await initDmc(basePath: tempDir.path);

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      final watcher = DmcWatcher(
        targetPath: tempDir.path,
        database: db,
        snapshotsPath: p.join(tempDir.path, '.dmc', 'snapshots'),
        ignoreRules: const [],
        maxFileSizeBytes: defaultMaxFileSizeKb * 1024,
        activeTaskNameProvider: () =>
            readActiveTaskSync(basePath: tempDir.path),
      );

      final file = File(p.join(tempDir.path, 'notes.txt'));
      await file.writeAsString('alpha');

      await startTask('refactor auth', basePath: tempDir.path);
      await watcher.captureFileNow(file.path);

      await endTask(basePath: tempDir.path);
      await file.writeAsString('beta');
      await watcher.captureFileNow(file.path);

      final logs = db.getRecentHistory(limit: 2);

      expect(logs, hasLength(2));
      expect(logs.first.taskName, isNull);
      expect(logs[1].taskName, 'refactor auth');

      db.close();
    });
  });

  group('DMC Burst Grouping', () {
    test('rapid saves share the same burst id', () async {
      await initDmc(basePath: tempDir.path);

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();

      final fileA = File(p.join(tempDir.path, 'alpha.txt'));
      final fileB = File(p.join(tempDir.path, 'beta.txt'));
      await fileA.writeAsString('alpha');
      await fileB.writeAsString('beta');

      final timestamps = [1000, 2500];
      var index = 0;
      final watcher = DmcWatcher(
        targetPath: tempDir.path,
        database: db,
        snapshotsPath: p.join(tempDir.path, '.dmc', 'snapshots'),
        ignoreRules: const [],
        maxFileSizeBytes: defaultMaxFileSizeKb * 1024,
        nowMilliseconds: () => timestamps[index++],
      );

      await watcher.captureFileNow(fileA.path);
      await watcher.captureFileNow(fileB.path);

      final logs = db.getRecentHistory(limit: 10);
      final alphaLog = logs.firstWhere((log) => log.filePath == 'alpha.txt');
      final betaLog = logs.firstWhere((log) => log.filePath == 'beta.txt');

      expect(alphaLog.burstId, isNotNull);
      expect(alphaLog.burstId, betaLog.burstId);

      db.close();
    });

    test('distant saves generate distinct burst ids', () async {
      await initDmc(basePath: tempDir.path);

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();

      final fileA = File(p.join(tempDir.path, 'alpha.txt'));
      final fileB = File(p.join(tempDir.path, 'beta.txt'));
      await fileA.writeAsString('alpha');
      await fileB.writeAsString('beta');

      final timestamps = [1000, 5001];
      var index = 0;
      final watcher = DmcWatcher(
        targetPath: tempDir.path,
        database: db,
        snapshotsPath: p.join(tempDir.path, '.dmc', 'snapshots'),
        ignoreRules: const [],
        maxFileSizeBytes: defaultMaxFileSizeKb * 1024,
        nowMilliseconds: () => timestamps[index++],
      );

      await watcher.captureFileNow(fileA.path);
      await watcher.captureFileNow(fileB.path);

      final logs = db.getRecentHistory(limit: 10);
      final alphaLog = logs.firstWhere((log) => log.filePath == 'alpha.txt');
      final betaLog = logs.firstWhere((log) => log.filePath == 'beta.txt');

      expect(alphaLog.burstId, isNotNull);
      expect(betaLog.burstId, isNotNull);
      expect(alphaLog.burstId, isNot(betaLog.burstId));

      db.close();
    });

    test('same-basename files changed at the same timestamp get unique snapshots', () async {
      await initDmc(basePath: tempDir.path);

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();

      final alphaDir = Directory(p.join(tempDir.path, 'alpha'));
      final betaDir = Directory(p.join(tempDir.path, 'beta'));
      await alphaDir.create();
      await betaDir.create();
      final alphaFile = File(p.join(alphaDir.path, 'index.dart'));
      final betaFile = File(p.join(betaDir.path, 'index.dart'));
      await alphaFile.writeAsString('alpha');
      await betaFile.writeAsString('beta');

      final watcher = DmcWatcher(
        targetPath: tempDir.path,
        database: db,
        snapshotsPath: p.join(tempDir.path, '.dmc', 'snapshots'),
        ignoreRules: const [],
        maxFileSizeBytes: defaultMaxFileSizeKb * 1024,
        nowMilliseconds: () => 1234,
      );

      await watcher.captureFileNow(alphaFile.path);
      await watcher.captureFileNow(betaFile.path);

      final logs = db.getRecentHistory(limit: 10);
      final snapshotPaths = logs.map((log) => log.snapshotPath).toSet();

      expect(logs, hasLength(2));
      expect(snapshotPaths, hasLength(2));
      for (final log in logs) {
        expect(
          await File(
            p.join(tempDir.path, '.dmc', 'snapshots', log.snapshotPath),
          ).exists(),
          isTrue,
        );
      }

      db.close();
    });

    test('deleting a tracked file creates a tombstone record', () async {
      await initDmc(basePath: tempDir.path);

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();

      final file = File(p.join(tempDir.path, 'notes.txt'));
      await file.writeAsString('alpha');

      final timestamps = [1000, 2000];
      var index = 0;
      final watcher = DmcWatcher(
        targetPath: tempDir.path,
        database: db,
        snapshotsPath: p.join(tempDir.path, '.dmc', 'snapshots'),
        ignoreRules: const [],
        maxFileSizeBytes: defaultMaxFileSizeKb * 1024,
        nowMilliseconds: () => timestamps[index++],
      );

      await watcher.captureFileNow(file.path);
      await file.delete();
      await watcher.captureFileNow(file.path);

      final logs = db.getRecentHistory(limit: 10);
      final latestLog = logs.firstWhere((log) => log.filePath == 'notes.txt');

      expect(latestLog.hash, tombstoneHash);
      expect(latestLog.snapshotPath, tombstoneSnapshotPath);
      expect(latestLog.burstId, isNotNull);

      db.close();
    });
  });

  group('DMC File Limits', () {
    test('oversized files are skipped before snapshotting', () async {
      await initDmc(basePath: tempDir.path);

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      final file = File(p.join(tempDir.path, 'large.txt'));
      await file.writeAsString('a' * 2048);

      final watcher = DmcWatcher(
        targetPath: tempDir.path,
        database: db,
        snapshotsPath: p.join(tempDir.path, '.dmc', 'snapshots'),
        ignoreRules: const [],
        maxFileSizeBytes: 1024,
      );

      final output = await capturePrints(
        () => watcher.captureFileNow(file.path),
      );

      expect(db.getRecentHistory(), isEmpty);
      expect(
        output,
        contains('[DMC] Skipping large.txt: file exceeds max size (1 KB).'),
      );

      db.close();
    });

    test('binary files are skipped before snapshotting', () async {
      await initDmc(basePath: tempDir.path);

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      final file = File(p.join(tempDir.path, 'binary.dat'));
      await file.writeAsBytes([65, 0, 66, 67]);

      final watcher = DmcWatcher(
        targetPath: tempDir.path,
        database: db,
        snapshotsPath: p.join(tempDir.path, '.dmc', 'snapshots'),
        ignoreRules: const [],
        maxFileSizeBytes: defaultMaxFileSizeKb * 1024,
      );

      final output = await capturePrints(
        () => watcher.captureFileNow(file.path),
      );

      expect(db.getRecentHistory(), isEmpty);
      expect(
        output,
        contains('[DMC] Skipping binary.dat: binary files are not tracked.'),
      );

      db.close();
    });
  });

  group('DMC Garbage Collection', () {
    test('pruneOldSnapshots removes expired files and rows', () async {
      await initDmc(basePath: tempDir.path);

      final dmcPath = p.join(tempDir.path, '.dmc');
      final snapshotsPath = p.join(dmcPath, 'snapshots');
      final dbPath = p.join(dmcPath, 'dmc.db');
      final oldSnapshotName = 'old_1.dart.bak';
      final freshSnapshotName = 'fresh_1.dart.bak';
      final oldSnapshotPath = p.join(snapshotsPath, oldSnapshotName);
      final freshSnapshotPath = p.join(snapshotsPath, freshSnapshotName);

      await File(oldSnapshotPath).writeAsString('old');
      await File(freshSnapshotPath).writeAsString('fresh');

      final db = DmcDatabase(dbPath);
      db.initialize();
      db.insertSnapshot(
        filePath: 'lib/old.dart',
        snapshotPath: oldSnapshotName,
        timestamp: DateTime.now()
            .subtract(const Duration(hours: 72))
            .millisecondsSinceEpoch,
        hash: 'oldhash',
      );
      db.insertSnapshot(
        filePath: 'lib/fresh.dart',
        snapshotPath: freshSnapshotName,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: 'freshhash',
      );

      final prunedCount = await db.pruneOldSnapshots(const Duration(hours: 48));
      final remainingLogs = db.getRecentHistory(limit: 10);

      expect(prunedCount, 1);
      expect(await File(oldSnapshotPath).exists(), isFalse);
      expect(await File(freshSnapshotPath).exists(), isTrue);
      expect(remainingLogs.length, 1);
      expect(remainingLogs.first.snapshotPath, freshSnapshotName);

      db.close();
    });

    test('pruneOldSnapshots ignores missing snapshot files', () async {
      await initDmc(basePath: tempDir.path);

      final dbPath = p.join(tempDir.path, '.dmc', 'dmc.db');
      final db = DmcDatabase(dbPath);
      db.initialize();
      db.insertSnapshot(
        filePath: 'lib/missing.dart',
        snapshotPath: 'missing.dart.bak',
        timestamp: DateTime.now()
            .subtract(const Duration(hours: 72))
            .millisecondsSinceEpoch,
        hash: 'missinghash',
      );

      final prunedCount = await db.pruneOldSnapshots(const Duration(hours: 48));

      expect(prunedCount, 1);
      expect(db.getRecentHistory(limit: 10), isEmpty);

      db.close();
    });

    test('pruneOldSnapshots keeps history referenced by restore audit events', () async {
      await initDmc(basePath: tempDir.path);

      final snapshotName = 'old_restore_source.bak';
      final snapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        snapshotName,
      );
      await File(snapshotPath).writeAsString('old');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      final snapshotId = insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: snapshotName,
        timestamp: DateTime.now()
            .subtract(const Duration(days: 10))
            .millisecondsSinceEpoch,
        hash: hashText('old'),
      );
      db.insertRestoreEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        command: 'undo',
        filePath: 'notes.txt',
        snapshotId: snapshotId,
        success: true,
      );

      final prunedCount = await db.pruneOldSnapshots(const Duration(hours: 48));

      expect(prunedCount, 0);
      expect(await File(snapshotPath).exists(), isTrue);
      expect(db.getSnapshotById(snapshotId), isNotNull);

      db.close();
    });
  });

  group('DMC Log', () {
    test('showLogs includes snapshot IDs', () async {
      await initDmc(basePath: tempDir.path);

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      final snapshotId = insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'notes_1.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: 'hash1',
      );
      db.close();

      final output = await capturePrints(
        () => showLogs(basePath: tempDir.path),
      );

      expect(output.any((line) => line.contains('[ID: $snapshotId]')), isTrue);
    });

    test('showLogs groups recent history by burst when requested', () async {
      await initDmc(basePath: tempDir.path);

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      db.insertSnapshot(
        filePath: 'lib/alpha.dart',
        snapshotPath: 'alpha_1.bak',
        timestamp: 1000,
        hash: 'hash-a',
        burstId: 100,
      );
      db.insertSnapshot(
        filePath: 'lib/beta.dart',
        snapshotPath: 'beta_1.bak',
        timestamp: 1500,
        hash: 'hash-b',
        burstId: 100,
      );
      db.insertSnapshot(
        filePath: 'lib/gamma.dart',
        snapshotPath: 'gamma_1.bak',
        timestamp: 5000,
        hash: 'hash-c',
        burstId: 200,
      );
      db.close();

      final output = await capturePrints(
        () => showLogs(basePath: tempDir.path, bursts: true),
      );

      expect(output, contains('Recent Bursts:'));
      expect(output, contains('[Burst ID: 200] ${formatTimestamp(5000)}'));
      expect(output, contains('[Burst ID: 100] ${formatTimestamp(1000)}'));
      expect(output, contains('Files modified: 2'));
      expect(
        output.any(
          (line) =>
              line.startsWith('Paths: ') &&
              line.contains('lib/alpha.dart') &&
              line.contains('lib/beta.dart'),
        ),
        isTrue,
      );
      expect(output, contains('Total: 2 burst(s), 3 backup(s)'));
    });

    test('showLogs groups recent history by task when requested', () async {
      await initDmc(basePath: tempDir.path);

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      db.insertSnapshot(
        filePath: 'lib/auth.dart',
        snapshotPath: 'auth_1.bak',
        timestamp: 1000,
        hash: 'hash-a',
        taskName: 'auth',
      );
      db.insertSnapshot(
        filePath: 'lib/login.dart',
        snapshotPath: 'login_1.bak',
        timestamp: 1500,
        hash: 'hash-b',
        taskName: 'auth',
      );
      db.insertSnapshot(
        filePath: 'lib/home.dart',
        snapshotPath: 'home_1.bak',
        timestamp: 5000,
        hash: 'hash-c',
      );
      db.close();

      final output = await capturePrints(
        () => showLogs(basePath: tempDir.path, tasks: true),
      );

      expect(output, contains('Recent Tasks:'));
      expect(output, contains('[Task: auth] ${formatTimestamp(1000)}'));
      expect(output, contains('[Task: unassigned] ${formatTimestamp(5000)}'));
      expect(output, contains('Files modified: 2'));
    });
  });

  group('DMC Health Commands', () {
    test('showStatus reports vault health and active config', () async {
      await initDmc(basePath: tempDir.path);

      final homeDir = await Directory.systemTemp.createTemp('dmc_home_');
      addTearDown(() async {
        if (await homeDir.exists()) {
          await homeDir.delete(recursive: true);
        }
      });

      await File(p.join(homeDir.path, globalConfigFileName)).writeAsString('''
{"retention_hours":48}
''');
      await File(p.join(tempDir.path, '.dmc', 'config.json')).writeAsString('''
{"max_file_size_kb":512}
''');

      final snapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'notes_1.bak',
      );
      await File(snapshotPath).writeAsString('alpha');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'notes_1.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha'),
      );
      db.close();

      final output = await capturePrints(
        () => showStatus(basePath: tempDir.path, homePath: homeDir.path),
      );

      expect(output, contains('[DMC] Status'));
      expect(output, contains('Initialized: yes'));
      expect(output, contains('Total snapshots: 1'));
      expect(output, contains('Retention hours: 48'));
      expect(output, contains('Max file size KB: 512'));
    });

    test('runDoctor reports missing and orphaned snapshot files', () async {
      await initDmc(basePath: tempDir.path);

      final snapshotDir = p.join(tempDir.path, '.dmc', 'snapshots');
      final orphanPath = p.join(snapshotDir, 'orphan.bak');
      await File(orphanPath).writeAsString('orphan');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'missing.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha'),
      );
      db.close();

      var hadIssues = false;
      final output = await capturePrints(() async {
        hadIssues = await runDoctor(basePath: tempDir.path);
      });

      expect(hadIssues, isTrue);
      expect(output, contains('[DMC] Doctor'));
      expect(output, contains('DB access: ok'));
      expect(output, contains('Missing snapshot files: 1'));
      expect(output, contains('Orphaned snapshot files: 1'));
    });
  });

  group('DMC Daemon', () {
    test('writeDaemonPid and readDaemonPid round-trip the pid file', () async {
      await initDmc(basePath: tempDir.path);

      await writeDaemonPid(4242, basePath: tempDir.path);

      expect(await readDaemonPid(basePath: tempDir.path), 4242);
      expect(
        await File(p.join(tempDir.path, '.dmc', 'daemon.pid')).exists(),
        isTrue,
      );
    });

    test('daemon state treats pid files for a different command as stale', () async {
      await initDmc(basePath: tempDir.path);

      final fakeDaemon = FakeDaemonProcessState();
      fakeDaemon.runningPids.add(4242);
      await writeDaemonPid(
        4242,
        basePath: tempDir.path,
        executable: '/usr/bin/other',
        arguments: const ['not-dmc'],
      );

      final state = await getDaemonState(
        basePath: tempDir.path,
        platform: fakeDaemon.platform,
      );

      expect(state.hasPidFile, isTrue);
      expect(state.pid, 4242);
      expect(state.isRunning, isFalse);
    });

    test('showStatus reports watcher running and stopped', () async {
      await initDmc(basePath: tempDir.path);

      final fakeDaemon = FakeDaemonProcessState();
      fakeDaemon.runningPids.add(4242);
      await writeDaemonPid(4242, basePath: tempDir.path);

      final runningOutput = await capturePrints(
        () => showStatus(
          basePath: tempDir.path,
          homePath: tempDir.path,
          daemonPlatform: fakeDaemon.platform,
        ),
      );
      expect(runningOutput, contains('Watcher: Running (PID: 4242)'));

      await clearDaemonPid(basePath: tempDir.path);

      final stoppedOutput = await capturePrints(
        () => showStatus(
          basePath: tempDir.path,
          homePath: tempDir.path,
          daemonPlatform: fakeDaemon.platform,
        ),
      );
      expect(stoppedOutput, contains('Watcher: Stopped'));
    });

    test('startDaemon prevents starting a duplicate watcher', () async {
      await initDmc(basePath: tempDir.path);

      final fakeDaemon = FakeDaemonProcessState(nextPid: 5000);

      final firstCode = await startDaemon(
        basePath: tempDir.path,
        platform: fakeDaemon.platform,
      );
      late int secondCode;
      final output = await capturePrints(() async {
        secondCode = await startDaemon(
          basePath: tempDir.path,
          platform: fakeDaemon.platform,
        );
      });

      expect(firstCode, 0);
      expect(secondCode, 1);
      expect(fakeDaemon.spawnCount, 1);
      expect(await readDaemonPid(basePath: tempDir.path), 5000);
      expect(output, contains('[DMC] Watcher is already running (PID: 5000).'));
    });

    test('stopDaemon kills the watcher and removes the pid file', () async {
      await initDmc(basePath: tempDir.path);

      final fakeDaemon = FakeDaemonProcessState();
      fakeDaemon.runningPids.add(6000);
      await writeDaemonPid(6000, basePath: tempDir.path);

      final output = await capturePrints(
        () => stopDaemon(basePath: tempDir.path, platform: fakeDaemon.platform),
      );

      expect(fakeDaemon.killCount, 1);
      expect(
        await File(p.join(tempDir.path, '.dmc', 'daemon.pid')).exists(),
        isFalse,
      );
      expect(output, contains('[DMC] Stopped watcher (PID: 6000).'));
    });
  });

  group('DMC Maintenance Commands', () {
    test('runGc dry-run reports deletions and leaves files intact', () async {
      await initDmc(basePath: tempDir.path);

      final snapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'old_notes.bak',
      );
      await File(snapshotPath).writeAsString('alpha');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'old_notes.bak',
        timestamp: DateTime.now()
            .subtract(const Duration(days: 10))
            .millisecondsSinceEpoch,
        hash: hashText('alpha'),
      );
      db.close();

      var code = -1;
      final output = await capturePrints(() async {
        code = await runGc(basePath: tempDir.path, dryRun: true);
      });

      expect(code, 0);
      expect(await File(snapshotPath).exists(), isTrue);
      expect(
        output.single,
        contains('[DMC] GC dry-run: 1 snapshot(s) would be deleted'),
      );
    });

    test('takeManualSnapshot captures changed files once', () async {
      await initDmc(basePath: tempDir.path);

      final file = File(p.join(tempDir.path, 'notes.txt'));
      await file.writeAsString('alpha');

      await takeManualSnapshot(basePath: tempDir.path);
      await takeManualSnapshot(basePath: tempDir.path);

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      final logs = db.getRecentHistory(limit: 10);

      expect(logs.where((log) => log.filePath == 'notes.txt'), hasLength(1));

      db.close();
    });
  });

  group('DMC Diff', () {
    test('showDiff reports when no history exists', () async {
      await initDmc(basePath: tempDir.path);

      final currentFile = File(p.join(tempDir.path, 'notes.txt'));
      await currentFile.writeAsString('brand new file');

      final output = await capturePrints(
        () => showDiff('notes.txt', basePath: tempDir.path),
      );

      expect(output, contains('[DMC] No history found for notes.txt'));
    });

    test('showDiff skips the latest identical snapshot', () async {
      await initDmc(basePath: tempDir.path);

      final currentFile = File(p.join(tempDir.path, 'notes.txt'));
      await currentFile.writeAsString('alpha gamma');

      final olderSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'older_notes.bak',
      );
      final newestSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'newest_notes.bak',
      );
      await File(olderSnapshotPath).writeAsString('alpha beta');
      await File(newestSnapshotPath).writeAsString('alpha gamma');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'older_notes.bak',
        timestamp: DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
        hash: hashText('alpha beta'),
      );
      insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'newest_notes.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha gamma'),
      );
      db.close();

      final output = await capturePrints(
        () => showDiff('notes.txt', basePath: tempDir.path),
      );

      expect(output.length, 1);
      expect(output.single, contains('alpha '));
      expect(output.single, contains('\x1B[31m'));
      expect(output.single, contains('\x1B[32m'));
      expect(output.single, endsWith('\x1B[0m'));
    });

    test('showDiff can target a specific snapshot id', () async {
      await initDmc(basePath: tempDir.path);

      final currentFile = File(p.join(tempDir.path, 'notes.txt'));
      await currentFile.writeAsString('alpha gamma');

      final targetedSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'targeted_notes.bak',
      );
      await File(targetedSnapshotPath).writeAsString('alpha beta');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      final snapshotId = insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'targeted_notes.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha beta'),
      );
      db.close();

      final output = await capturePrints(
        () => showDiff('notes.txt', basePath: tempDir.path, id: snapshotId),
      );

      expect(output.length, 1);
      expect(output.single, contains('\x1B[31m'));
      expect(output.single, contains('\x1B[32m'));
    });

    test('showDiff can diff all files in a burst', () async {
      await initDmc(basePath: tempDir.path);

      final alphaFile = File(p.join(tempDir.path, 'alpha.txt'));
      final betaFile = File(p.join(tempDir.path, 'beta.txt'));
      await alphaFile.writeAsString('alpha current');
      await betaFile.writeAsString('beta current');

      final alphaSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'alpha_old.bak',
      );
      final betaSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'beta_old.bak',
      );
      await File(alphaSnapshotPath).writeAsString('alpha old');
      await File(betaSnapshotPath).writeAsString('beta old');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      final burstId = 321;
      final alphaSnapshotId = insertSnapshotAndGetId(
        db,
        filePath: 'alpha.txt',
        snapshotPath: 'alpha_old.bak',
        timestamp: 1000,
        hash: hashText('alpha old'),
        burstId: burstId,
      );
      final betaSnapshotId = insertSnapshotAndGetId(
        db,
        filePath: 'beta.txt',
        snapshotPath: 'beta_old.bak',
        timestamp: 1001,
        hash: hashText('beta old'),
        burstId: burstId,
      );
      db.close();

      final output = await capturePrints(
        () => showDiff('', basePath: tempDir.path, burstId: burstId),
      );

      expect(output, contains('[DMC] Burst diff for $burstId (2 file(s))'));
      expect(
        output,
        contains(
          '[DMC] Diff for alpha.txt [Burst: $burstId, Snapshot ID: $alphaSnapshotId]',
        ),
      );
      expect(
        output,
        contains(
          '[DMC] Diff for beta.txt [Burst: $burstId, Snapshot ID: $betaSnapshotId]',
        ),
      );
      expect(output.any((line) => line.contains('\x1B[31m')), isTrue);
      expect(output.any((line) => line.contains('\x1B[32m')), isTrue);
    });

    test('showDiff treats a missing working file as empty content', () async {
      await initDmc(basePath: tempDir.path);

      final snapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'notes_old.bak',
      );
      await File(snapshotPath).writeAsString('alpha beta');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'notes_old.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha beta'),
      );
      db.insertTombstone(
        filePath: 'notes.txt',
        timestamp: DateTime.now()
            .add(const Duration(seconds: 1))
            .millisecondsSinceEpoch,
      );
      db.close();

      final output = await capturePrints(
        () => showDiff('notes.txt', basePath: tempDir.path),
      );

      expect(output.length, 1);
      expect(output.single, contains('\x1B[32m'));
      expect(output.single, contains('alpha beta'));
    });
  });

  group('DMC Restore', () {
    test('restoreFile skips the latest identical snapshot', () async {
      await initDmc(basePath: tempDir.path);

      final currentFile = File(p.join(tempDir.path, 'notes.txt'));
      await currentFile.writeAsString('alpha gamma');

      final olderSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'older_notes.bak',
      );
      final newestSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'newest_notes.bak',
      );
      await File(olderSnapshotPath).writeAsString('alpha beta');
      await File(newestSnapshotPath).writeAsString('alpha gamma');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'older_notes.bak',
        timestamp: DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
        hash: hashText('alpha beta'),
      );
      insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'newest_notes.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha gamma'),
      );
      db.close();

      await restoreFile('notes.txt', basePath: tempDir.path);

      expect(await currentFile.readAsString(), 'alpha beta');
    });

    test('restoreFile can target a specific snapshot id', () async {
      await initDmc(basePath: tempDir.path);

      final currentFile = File(p.join(tempDir.path, 'notes.txt'));
      await currentFile.writeAsString('alpha gamma');

      final targetedSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'targeted_notes.bak',
      );
      await File(targetedSnapshotPath).writeAsString('alpha beta');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      final snapshotId = insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'targeted_notes.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha beta'),
      );
      db.close();

      await restoreFile('notes.txt', basePath: tempDir.path, id: snapshotId);

      expect(await currentFile.readAsString(), 'alpha beta');
    });

    test('undoFile skips the latest identical snapshot', () async {
      await initDmc(basePath: tempDir.path);

      final currentFile = File(p.join(tempDir.path, 'notes.txt'));
      await currentFile.writeAsString('alpha gamma');

      final olderSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'older_notes.bak',
      );
      final newestSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'newest_notes.bak',
      );
      await File(olderSnapshotPath).writeAsString('alpha beta');
      await File(newestSnapshotPath).writeAsString('alpha gamma');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'older_notes.bak',
        timestamp: DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
        hash: hashText('alpha beta'),
      );
      insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'newest_notes.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha gamma'),
      );
      db.close();

      await undoFile('notes.txt', basePath: tempDir.path);

      expect(await currentFile.readAsString(), 'alpha beta');
    });

    test('undoFile can target a specific snapshot id', () async {
      await initDmc(basePath: tempDir.path);

      final currentFile = File(p.join(tempDir.path, 'notes.txt'));
      await currentFile.writeAsString('alpha gamma');

      final targetedSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'targeted_notes.bak',
      );
      await File(targetedSnapshotPath).writeAsString('alpha beta');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      final snapshotId = insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'targeted_notes.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha beta'),
      );
      db.close();

      await undoFile('notes.txt', basePath: tempDir.path, id: snapshotId);

      expect(await currentFile.readAsString(), 'alpha beta');
    });

    test('restoreFile matches undoFile behavior', () async {
      final restoreDir = await Directory.systemTemp.createTemp('dmc_restore_');
      final undoDir = await Directory.systemTemp.createTemp('dmc_undo_');
      addTearDown(() async {
        if (await restoreDir.exists()) {
          await restoreDir.delete(recursive: true);
        }
        if (await undoDir.exists()) {
          await undoDir.delete(recursive: true);
        }
      });

      const timestamp = 1_700_000_000_000;
      for (final dir in [restoreDir, undoDir]) {
        await initDmc(basePath: dir.path);

        final currentFile = File(p.join(dir.path, 'notes.txt'));
        await currentFile.writeAsString('alpha gamma');

        final snapshotPath = p.join(
          dir.path,
          '.dmc',
          'snapshots',
          'older_notes.bak',
        );
        await File(snapshotPath).writeAsString('alpha beta');

        final db = DmcDatabase(p.join(dir.path, '.dmc', 'dmc.db'));
        db.initialize();
        insertSnapshotAndGetId(
          db,
          filePath: 'notes.txt',
          snapshotPath: 'older_notes.bak',
          timestamp: timestamp,
          hash: hashText('alpha beta'),
        );
        db.close();
      }

      final restoreOutput = await capturePrints(
        () => restoreFile('notes.txt', basePath: restoreDir.path),
      );
      final undoOutput = await capturePrints(
        () => undoFile('notes.txt', basePath: undoDir.path),
      );

      expect(
        await File(p.join(restoreDir.path, 'notes.txt')).readAsString(),
        await File(p.join(undoDir.path, 'notes.txt')).readAsString(),
      );
      expect(restoreOutput, undoOutput);
    });

    test(
      'undoFile recreates a deleted file from the previous snapshot',
      () async {
        await initDmc(basePath: tempDir.path);

        final snapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'notes_old.bak',
        );
        await File(snapshotPath).writeAsString('alpha beta');

        final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
        db.initialize();
        insertSnapshotAndGetId(
          db,
          filePath: 'notes.txt',
          snapshotPath: 'notes_old.bak',
          timestamp: DateTime.now()
              .subtract(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
          hash: hashText('alpha beta'),
        );
        db.insertTombstone(
          filePath: 'notes.txt',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
        db.close();

        final currentFile = File(p.join(tempDir.path, 'notes.txt'));
        expect(await currentFile.exists(), isFalse);

        final output = await capturePrints(
          () => undoFile('notes.txt', basePath: tempDir.path),
        );

        expect(await currentFile.exists(), isTrue);
        expect(await currentFile.readAsString(), 'alpha beta');
        expect(
          output.any(
            (line) => line.contains('Restored notes.txt to version from'),
          ),
          isTrue,
        );
      },
    );

    test(
      'undoFile can restore to a tombstone and delete the working file',
      () async {
        await initDmc(basePath: tempDir.path);

        final currentFile = File(p.join(tempDir.path, 'notes.txt'));
        await currentFile.writeAsString('alpha beta');

        final snapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'notes_created.bak',
        );
        await File(snapshotPath).writeAsString('alpha beta');

        final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
        db.initialize();
        insertSnapshotAndGetId(
          db,
          filePath: 'notes.txt',
          snapshotPath: tombstoneSnapshotPath,
          timestamp: DateTime.now()
              .subtract(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
          hash: tombstoneHash,
        );
        insertSnapshotAndGetId(
          db,
          filePath: 'notes.txt',
          snapshotPath: 'notes_created.bak',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          hash: hashText('alpha beta'),
        );
        db.close();

        final output = await capturePrints(
          () => undoFile('notes.txt', basePath: tempDir.path),
        );

        expect(await currentFile.exists(), isFalse);
        expect(
          output.any(
            (line) => line.contains('Deleted notes.txt to version from'),
          ),
          isTrue,
        );
      },
    );

    test(
      'undoFile restores to a tombstone while preserving the overwritten state for redo',
      () async {
        await initDmc(basePath: tempDir.path);

        final currentFile = File(p.join(tempDir.path, 'notes.txt'));
        await currentFile.writeAsString('alpha beta');

        final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
        db.initialize();
        final tombstoneId = insertSnapshotAndGetId(
          db,
          filePath: 'notes.txt',
          snapshotPath: tombstoneSnapshotPath,
          timestamp: DateTime.now()
              .subtract(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
          hash: tombstoneHash,
        );
        db.close();

        final undoResult = await undoFile(
          'notes.txt',
          basePath: tempDir.path,
          id: tombstoneId,
        );

        expect(undoResult.hadError, isFalse);
        expect(await currentFile.exists(), isFalse);

        final undoEvents = loadRestoreEvents(tempDir.path);
        expect(undoEvents, hasLength(1));
        expect(undoEvents.first.overwrittenSnapshotId, isNotNull);

        final redoResult = await redoFile('notes.txt', basePath: tempDir.path);

        expect(redoResult.hadError, isFalse);
        expect(await currentFile.exists(), isTrue);
        expect(await currentFile.readAsString(), 'alpha beta');
      },
    );

    test('createMark and restoreFile can restore the marked burst', () async {
      await initDmc(basePath: tempDir.path);

      final currentFile = File(p.join(tempDir.path, 'notes.txt'));
      await currentFile.writeAsString('alpha current');

      final snapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'notes_marked.bak',
      );
      await File(snapshotPath).writeAsString('alpha saved');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'notes_marked.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha saved'),
        burstId: 42,
      );
      db.close();

      await createMark('before-refactor', basePath: tempDir.path);

      final result = await restoreFile(
        '',
        basePath: tempDir.path,
        markName: 'before-refactor',
      );

      expect(result.hadError, isFalse);
      expect(result.restorePossible, isTrue);
      expect(await currentFile.readAsString(), 'alpha saved');
    });

    test('mark restore dry-run previews without modifying files', () async {
      await initDmc(basePath: tempDir.path);

      final currentFile = File(p.join(tempDir.path, 'notes.txt'));
      await currentFile.writeAsString('alpha current');

      final snapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'notes_marked_preview.bak',
      );
      await File(snapshotPath).writeAsString('alpha saved');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'notes_marked_preview.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha saved'),
        burstId: 43,
      );
      db.close();

      await createMark('before-preview', basePath: tempDir.path);

      final output = await capturePrints(
        () => restoreFile(
          '',
          basePath: tempDir.path,
          markName: 'before-preview',
          dryRun: true,
        ),
      );

      expect(await currentFile.readAsString(), 'alpha current');
      expect(loadRestoreEvents(tempDir.path), isEmpty);
      expect(
        output,
        contains('[DMC] Burst restore preview for 43 (1 file(s))'),
      );
      expect(
        output,
        contains('[DMC] Previewing notes.txt [Burst: 43, Snapshot ID: 1]'),
      );
    });

    test(
      'task restore dry-run previews all task files without modifying them',
      () async {
        await initDmc(basePath: tempDir.path);

        final alphaFile = File(p.join(tempDir.path, 'alpha.txt'));
        final betaFile = File(p.join(tempDir.path, 'beta.txt'));
        await alphaFile.writeAsString('alpha current');
        await betaFile.writeAsString('beta current');

        final alphaSnapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'alpha_task.bak',
        );
        final betaSnapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'beta_task.bak',
        );
        await File(alphaSnapshotPath).writeAsString('alpha saved');
        await File(betaSnapshotPath).writeAsString('beta saved');

        final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
        db.initialize();
        insertSnapshotAndGetId(
          db,
          filePath: 'alpha.txt',
          snapshotPath: 'alpha_task.bak',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          hash: hashText('alpha saved'),
          taskName: 'refactor auth',
        );
        insertSnapshotAndGetId(
          db,
          filePath: 'beta.txt',
          snapshotPath: 'beta_task.bak',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          hash: hashText('beta saved'),
          taskName: 'refactor auth',
        );
        db.close();

        final output = await capturePrints(
          () => restoreFile(
            '',
            basePath: tempDir.path,
            taskName: 'refactor auth',
            dryRun: true,
          ),
        );

        expect(await alphaFile.readAsString(), 'alpha current');
        expect(await betaFile.readAsString(), 'beta current');
        expect(loadRestoreEvents(tempDir.path), isEmpty);
        expect(
          output,
          contains(
            '[DMC] Task restore preview for "refactor auth" (2 file(s))',
          ),
        );
        expect(output.any((line) => line.contains('alpha.txt')), isTrue);
        expect(output.any((line) => line.contains('beta.txt')), isTrue);
      },
    );

    test('undoFile records a successful restore event', () async {
      await initDmc(basePath: tempDir.path);

      final currentFile = File(p.join(tempDir.path, 'notes.txt'));
      await currentFile.writeAsString('alpha gamma');

      final targetedSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'targeted_notes.bak',
      );
      await File(targetedSnapshotPath).writeAsString('alpha beta');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      final snapshotId = insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'targeted_notes.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha beta'),
      );
      db.close();

      await undoFile('notes.txt', basePath: tempDir.path, id: snapshotId);

      final events = loadRestoreEvents(tempDir.path);

      expect(events, hasLength(1));
      expect(events.first.command, 'undo');
      expect(events.first.filePath, 'notes.txt');
      expect(events.first.snapshotId, snapshotId);
      expect(events.first.success, isTrue);
      expect(events.first.failureMessage, isNull);
      expect(events.first.overwrittenSnapshotId, isNotNull);
      expect(events.first.timestamp, greaterThan(0));
    });

    test('restoreFile records a failed restore event', () async {
      await initDmc(basePath: tempDir.path);

      final blockedParent = File(p.join(tempDir.path, 'blocked'));
      await blockedParent.writeAsString('not a directory');

      final filePath = p.join('blocked', 'notes.txt');
      final targetedSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'targeted_notes.bak',
      );
      await File(targetedSnapshotPath).writeAsString('alpha beta');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      final snapshotId = insertSnapshotAndGetId(
        db,
        filePath: filePath,
        snapshotPath: 'targeted_notes.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha beta'),
      );
      db.close();

      await restoreFile(filePath, basePath: tempDir.path, id: snapshotId);

      final events = loadRestoreEvents(tempDir.path);

      expect(events, hasLength(1));
      expect(events.first.command, 'restore');
      expect(events.first.filePath, filePath);
      expect(events.first.snapshotId, snapshotId);
      expect(events.first.success, isFalse);
      expect(events.first.failureMessage, isNotNull);
      expect(events.first.overwrittenSnapshotId, isNotNull);
    });

    test('dry-run does not create a restore audit event', () async {
      await initDmc(basePath: tempDir.path);

      final currentFile = File(p.join(tempDir.path, 'notes.txt'));
      await currentFile.writeAsString('alpha gamma');

      final targetedSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'targeted_notes.bak',
      );
      await File(targetedSnapshotPath).writeAsString('alpha beta');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      final snapshotId = insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'targeted_notes.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha beta'),
      );
      db.close();

      await restoreFile(
        'notes.txt',
        basePath: tempDir.path,
        id: snapshotId,
        dryRun: true,
      );

      expect(loadRestoreEvents(tempDir.path), isEmpty);
    });

    test('redoFile restores the state that undo overwrote', () async {
      await initDmc(basePath: tempDir.path);

      final currentFile = File(p.join(tempDir.path, 'notes.txt'));
      await currentFile.writeAsString('alpha gamma');

      final olderSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'older_notes.bak',
      );
      final newestSnapshotPath = p.join(
        tempDir.path,
        '.dmc',
        'snapshots',
        'newest_notes.bak',
      );
      await File(olderSnapshotPath).writeAsString('alpha beta');
      await File(newestSnapshotPath).writeAsString('alpha gamma');

      final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
      db.initialize();
      final olderSnapshotId = insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'older_notes.bak',
        timestamp: DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
        hash: hashText('alpha beta'),
      );
      final newestSnapshotId = insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: 'newest_notes.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha gamma'),
      );
      db.close();

      await undoFile('notes.txt', basePath: tempDir.path);
      expect(await currentFile.readAsString(), 'alpha beta');

      final undoEvents = loadRestoreEvents(tempDir.path);
      expect(undoEvents, hasLength(1));
      expect(undoEvents.first.command, 'undo');
      expect(undoEvents.first.snapshotId, olderSnapshotId);
      expect(undoEvents.first.overwrittenSnapshotId, newestSnapshotId);

      final result = await redoFile('notes.txt', basePath: tempDir.path);

      expect(result.hadError, isFalse);
      expect(result.restorePossible, isTrue);
      expect(await currentFile.readAsString(), 'alpha gamma');

      final events = loadRestoreEvents(tempDir.path, limit: 2);
      expect(events, hasLength(2));
      expect(events.first.command, 'redo');
      expect(events.first.filePath, 'notes.txt');
      expect(events.first.snapshotId, newestSnapshotId);
      expect(events.first.success, isTrue);
      expect(events[1].command, 'undo');
    });

    test('redoFile fails gracefully when there is no prior undo', () async {
      await initDmc(basePath: tempDir.path);

      final currentFile = File(p.join(tempDir.path, 'notes.txt'));
      await currentFile.writeAsString('alpha gamma');

      late RestoreResult result;
      final output = await capturePrints(() async {
        result = await redoFile('notes.txt', basePath: tempDir.path);
      });

      expect(result.hadError, isTrue);
      expect(await currentFile.readAsString(), 'alpha gamma');
      expect(
        output,
        contains('[DMC] No recent undo found to redo for notes.txt'),
      );
      expect(loadRestoreEvents(tempDir.path), isEmpty);
    });

    test(
      'redoFile dry-run does not modify the file or record an event',
      () async {
        await initDmc(basePath: tempDir.path);

        final currentFile = File(p.join(tempDir.path, 'notes.txt'));
        await currentFile.writeAsString('alpha gamma');

        final olderSnapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'older_notes.bak',
        );
        final newestSnapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'newest_notes.bak',
        );
        await File(olderSnapshotPath).writeAsString('alpha beta');
        await File(newestSnapshotPath).writeAsString('alpha gamma');

        final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
        db.initialize();
        insertSnapshotAndGetId(
          db,
          filePath: 'notes.txt',
          snapshotPath: 'older_notes.bak',
          timestamp: DateTime.now()
              .subtract(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
          hash: hashText('alpha beta'),
        );
        final newestSnapshotId = insertSnapshotAndGetId(
          db,
          filePath: 'notes.txt',
          snapshotPath: 'newest_notes.bak',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          hash: hashText('alpha gamma'),
        );
        db.close();

        await undoFile('notes.txt', basePath: tempDir.path);
        expect(await currentFile.readAsString(), 'alpha beta');
        expect(loadRestoreEvents(tempDir.path), hasLength(1));

        final output = await capturePrints(
          () => redoFile('notes.txt', basePath: tempDir.path, dryRun: true),
        );

        expect(await currentFile.readAsString(), 'alpha beta');
        expect(loadRestoreEvents(tempDir.path), hasLength(1));
        expect(output, contains('[DMC] Restore preview'));
        expect(output, contains('Target snapshot ID: $newestSnapshotId'));
        expect(output, contains('Restore possible: yes'));
      },
    );

    test(
      'burst undo restores multiple files and burst redo replays them',
      () async {
        await initDmc(basePath: tempDir.path);

        final alphaFile = File(p.join(tempDir.path, 'alpha.txt'));
        final betaFile = File(p.join(tempDir.path, 'beta.txt'));
        await alphaFile.writeAsString('alpha current');
        await betaFile.writeAsString('beta current');

        final alphaOldSnapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'alpha_old.bak',
        );
        final betaOldSnapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'beta_old.bak',
        );
        final alphaCurrentSnapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'alpha_current.bak',
        );
        final betaCurrentSnapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'beta_current.bak',
        );
        await File(alphaOldSnapshotPath).writeAsString('alpha old');
        await File(betaOldSnapshotPath).writeAsString('beta old');
        await File(alphaCurrentSnapshotPath).writeAsString('alpha current');
        await File(betaCurrentSnapshotPath).writeAsString('beta current');

        final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
        db.initialize();
        const burstId = 700;
        final alphaBurstSnapshotId = insertSnapshotAndGetId(
          db,
          filePath: 'alpha.txt',
          snapshotPath: 'alpha_old.bak',
          timestamp: 1000,
          hash: hashText('alpha old'),
          burstId: burstId,
        );
        final betaBurstSnapshotId = insertSnapshotAndGetId(
          db,
          filePath: 'beta.txt',
          snapshotPath: 'beta_old.bak',
          timestamp: 1001,
          hash: hashText('beta old'),
          burstId: burstId,
        );
        final alphaCurrentSnapshotId = insertSnapshotAndGetId(
          db,
          filePath: 'alpha.txt',
          snapshotPath: 'alpha_current.bak',
          timestamp: 2000,
          hash: hashText('alpha current'),
        );
        final betaCurrentSnapshotId = insertSnapshotAndGetId(
          db,
          filePath: 'beta.txt',
          snapshotPath: 'beta_current.bak',
          timestamp: 2001,
          hash: hashText('beta current'),
        );
        db.close();

        final undoOutput = await capturePrints(
          () => undoFile('', basePath: tempDir.path, burstId: burstId),
        );

        expect(await alphaFile.readAsString(), 'alpha old');
        expect(await betaFile.readAsString(), 'beta old');
        expect(
          undoOutput,
          contains(
            '[DMC] Warning: alpha.txt has newer history than burst $burstId. Restoring snapshot ID $alphaBurstSnapshotId anyway.',
          ),
        );
        expect(
          undoOutput,
          contains(
            '[DMC] Warning: beta.txt has newer history than burst $burstId. Restoring snapshot ID $betaBurstSnapshotId anyway.',
          ),
        );

        final undoEvents = loadRestoreEvents(tempDir.path, limit: 4);
        expect(
          undoEvents.where((event) => event.command == 'undo'),
          hasLength(2),
        );
        expect(
          undoEvents
              .where((event) => event.command == 'undo')
              .map((event) => event.filePath)
              .toSet(),
          {'alpha.txt', 'beta.txt'},
        );

        final redoResult = await redoFile(
          '',
          basePath: tempDir.path,
          burstId: burstId,
        );

        expect(redoResult.hadError, isFalse);
        expect(await alphaFile.readAsString(), 'alpha current');
        expect(await betaFile.readAsString(), 'beta current');

        final events = loadRestoreEvents(tempDir.path, limit: 6);
        expect(events.where((event) => event.command == 'redo'), hasLength(2));
        expect(
          events
              .where((event) => event.command == 'redo')
              .map((event) => event.snapshotId)
              .toSet(),
          {alphaCurrentSnapshotId, betaCurrentSnapshotId},
        );
      },
    );

    test(
      'burst restore dry-run previews all files without modifying them',
      () async {
        await initDmc(basePath: tempDir.path);

        final alphaFile = File(p.join(tempDir.path, 'alpha.txt'));
        final betaFile = File(p.join(tempDir.path, 'beta.txt'));
        await alphaFile.writeAsString('alpha current');
        await betaFile.writeAsString('beta current');

        final alphaSnapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'alpha_old.bak',
        );
        final betaSnapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'beta_old.bak',
        );
        await File(alphaSnapshotPath).writeAsString('alpha old');
        await File(betaSnapshotPath).writeAsString('beta old');

        final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
        db.initialize();
        const burstId = 701;
        insertSnapshotAndGetId(
          db,
          filePath: 'alpha.txt',
          snapshotPath: 'alpha_old.bak',
          timestamp: 1000,
          hash: hashText('alpha old'),
          burstId: burstId,
        );
        insertSnapshotAndGetId(
          db,
          filePath: 'beta.txt',
          snapshotPath: 'beta_old.bak',
          timestamp: 1001,
          hash: hashText('beta old'),
          burstId: burstId,
        );
        db.close();

        final output = await capturePrints(
          () => restoreFile(
            '',
            basePath: tempDir.path,
            burstId: burstId,
            dryRun: true,
          ),
        );

        expect(await alphaFile.readAsString(), 'alpha current');
        expect(await betaFile.readAsString(), 'beta current');
        expect(loadRestoreEvents(tempDir.path), isEmpty);
        expect(
          output,
          contains('[DMC] Burst restore preview for $burstId (2 file(s))'),
        );
        expect(
          output,
          contains(
            '[DMC] Previewing alpha.txt [Burst: $burstId, Snapshot ID: 1]',
          ),
        );
        expect(
          output,
          contains(
            '[DMC] Previewing beta.txt [Burst: $burstId, Snapshot ID: 2]',
          ),
        );
        expect(
          output.where((line) => line == '[DMC] Restore preview'),
          hasLength(2),
        );
      },
    );

    test('invalid burst ids fail gracefully', () async {
      await initDmc(basePath: tempDir.path);

      late RestoreResult result;
      final restoreOutput = await capturePrints(() async {
        result = await restoreFile('', basePath: tempDir.path, burstId: 999);
      });

      expect(result.hadError, isTrue);
      expect(restoreOutput, contains('[DMC] Error: Burst ID 999 not found.'));

      final diffOutput = await capturePrints(
        () => showDiff('', basePath: tempDir.path, burstId: 999),
      );
      expect(diffOutput, contains('[DMC] Error: Burst ID 999 not found.'));
    });
  });

  group('DMC CLI', () {
    test('runCli usage lists restore and redo', () async {
      final output = await capturePrints(() => runCli([]));

      expect(
        output,
        contains(
          '  start                Start the watcher as a background daemon',
        ),
      );
      expect(
        output,
        contains('  stop                 Stop the background watcher daemon'),
      );
      expect(
        output,
        contains(
          '  watch                Watch for file changes in the foreground',
        ),
      );
      expect(
        output,
        contains('  status               Show vault health and active config'),
      );
      expect(
        output,
        contains(
          '  doctor               Check DB access and snapshot consistency',
        ),
      );
      expect(
        output,
        contains('  snap                 Capture a manual workspace snapshot'),
      );
      expect(
        output,
        contains(
          '  gc [--dry-run]       Prune expired snapshots using retention config',
        ),
      );
      expect(
        output,
        contains('  task start <name>    Start assigning snapshots to a task'),
      );
      expect(
        output,
        contains('  task end             Stop assigning snapshots to a task'),
      );
      expect(
        output,
        contains('  mark <name>          Save a mark for the latest burst'),
      );
      expect(output, contains('  marks                List saved marks'));
      expect(
        output,
        contains('  log [--bursts|--tasks]       Show recent backup history'),
      );
      expect(
        output,
        contains(
          '  restore [--id <id>|--burst <id>|--task <name>|--mark <name>] [--dry-run]  Alias for undo',
        ),
      );
      expect(
        output,
        contains(
          '  redo [--burst <id>|--task <name>|--mark <name>] [--dry-run]  Restore the last undone state',
        ),
      );
      expect(
        output,
        contains(
          '  diff [--id <id>|--burst <id>]    Show a colored diff against a snapshot',
        ),
      );
    });

    test('runCli prints a graceful error for non-integer --id', () async {
      final output = await capturePrints(
        () => runCli(['undo', '--id', 'abc', 'notes.txt']),
      );

      expect(output, contains('[DMC] Error: --id must be an integer.'));
    });

    test(
      'runCli restore prints a graceful error for non-integer --id',
      () async {
        final output = await capturePrints(
          () => runCli(['restore', '--id', 'abc', 'notes.txt']),
        );

        expect(output, contains('[DMC] Error: --id must be an integer.'));
      },
    );

    test(
      'runCli restore dry-run previews without modifying the file',
      () async {
        await initDmc(basePath: tempDir.path);

        final currentFile = File(p.join(tempDir.path, 'notes.txt'));
        await currentFile.writeAsString('alpha gamma');

        final olderSnapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'older_notes.bak',
        );
        final newestSnapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'newest_notes.bak',
        );
        await File(olderSnapshotPath).writeAsString('alpha beta');
        await File(newestSnapshotPath).writeAsString('alpha gamma');

        final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
        db.initialize();
        final previewSnapshotId = insertSnapshotAndGetId(
          db,
          filePath: 'notes.txt',
          snapshotPath: 'older_notes.bak',
          timestamp: DateTime.now()
              .subtract(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
          hash: hashText('alpha beta'),
        );
        insertSnapshotAndGetId(
          db,
          filePath: 'notes.txt',
          snapshotPath: 'newest_notes.bak',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          hash: hashText('alpha gamma'),
        );
        db.close();

        var code = -1;
        late String expectedTargetPath;
        final output = await capturePrints(
          () => withCurrentDirectory(tempDir.path, () async {
            expectedTargetPath = p.join(Directory.current.path, 'notes.txt');
            code = await runCli(['restore', 'notes.txt', '--dry-run']);
          }),
        );

        expect(await currentFile.readAsString(), 'alpha gamma');
        expect(code, 0);
        expect(output, contains('[DMC] Restore preview'));
        expect(output, contains('Target snapshot ID: $previewSnapshotId'));
        expect(output, contains('Target file path: $expectedTargetPath'));
        expect(output, contains('Restore possible: yes'));
        expect(output.any((line) => line.contains('\x1B[31m')), isTrue);
        expect(output.any((line) => line.contains('\x1B[32m')), isTrue);
      },
    );

    test(
      'runCli undo preview alias succeeds without modifying the file',
      () async {
        await initDmc(basePath: tempDir.path);

        final currentFile = File(p.join(tempDir.path, 'notes.txt'));
        await currentFile.writeAsString('alpha gamma');

        final targetedSnapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'targeted_notes.bak',
        );
        await File(targetedSnapshotPath).writeAsString('alpha beta');

        final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
        db.initialize();
        final snapshotId = insertSnapshotAndGetId(
          db,
          filePath: 'notes.txt',
          snapshotPath: 'targeted_notes.bak',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          hash: hashText('alpha beta'),
        );
        db.close();

        var code = -1;
        final output = await capturePrints(
          () => withCurrentDirectory(tempDir.path, () async {
            code = await runCli([
              'undo',
              'notes.txt',
              '--preview',
              '--id',
              '$snapshotId',
            ]);
          }),
        );

        expect(await currentFile.readAsString(), 'alpha gamma');
        expect(code, 0);
        expect(output, contains('[DMC] Restore preview'));
        expect(output, contains('Target snapshot ID: $snapshotId'));
        expect(output, contains('Restore possible: yes'));
      },
    );

    test(
      'runCli restore dry-run exits non-zero for invalid snapshot ids',
      () async {
        await initDmc(basePath: tempDir.path);

        final currentFile = File(p.join(tempDir.path, 'notes.txt'));
        await currentFile.writeAsString('alpha gamma');

        var code = -1;
        final output = await capturePrints(
          () => withCurrentDirectory(tempDir.path, () async {
            code = await runCli([
              'restore',
              'notes.txt',
              '--dry-run',
              '--id',
              '999',
            ]);
          }),
        );

        expect(await currentFile.readAsString(), 'alpha gamma');
        expect(code, 1);
        expect(output, contains('[DMC] Error: Snapshot ID 999 not found.'));
      },
    );

    test(
      'runCli redo preview alias succeeds without modifying the file',
      () async {
        await initDmc(basePath: tempDir.path);

        final currentFile = File(p.join(tempDir.path, 'notes.txt'));
        await currentFile.writeAsString('alpha gamma');

        final olderSnapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'older_notes.bak',
        );
        final newestSnapshotPath = p.join(
          tempDir.path,
          '.dmc',
          'snapshots',
          'newest_notes.bak',
        );
        await File(olderSnapshotPath).writeAsString('alpha beta');
        await File(newestSnapshotPath).writeAsString('alpha gamma');

        final db = DmcDatabase(p.join(tempDir.path, '.dmc', 'dmc.db'));
        db.initialize();
        insertSnapshotAndGetId(
          db,
          filePath: 'notes.txt',
          snapshotPath: 'older_notes.bak',
          timestamp: DateTime.now()
              .subtract(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
          hash: hashText('alpha beta'),
        );
        final newestSnapshotId = insertSnapshotAndGetId(
          db,
          filePath: 'notes.txt',
          snapshotPath: 'newest_notes.bak',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          hash: hashText('alpha gamma'),
        );
        db.close();

        await undoFile('notes.txt', basePath: tempDir.path);
        expect(await currentFile.readAsString(), 'alpha beta');

        var code = -1;
        final output = await capturePrints(
          () => withCurrentDirectory(tempDir.path, () async {
            code = await runCli(['redo', 'notes.txt', '--preview']);
          }),
        );

        expect(code, 0);
        expect(await currentFile.readAsString(), 'alpha beta');
        expect(loadRestoreEvents(tempDir.path), hasLength(1));
        expect(output, contains('[DMC] Restore preview'));
        expect(output, contains('Target snapshot ID: $newestSnapshotId'));
        expect(output, contains('Restore possible: yes'));
      },
    );
  });
}
