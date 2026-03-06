import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dmc/dmc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<List<String>> capturePrints(Future<void> Function() action) async {
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

String hashText(String text) {
  return sha256.convert(utf8.encode(text)).toString();
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
      final remainingLogs = db.getRecentLogs(limit: 10);

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
      expect(db.getRecentLogs(limit: 10), isEmpty);

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
      db.insertSnapshot(
        filePath: 'notes.txt',
        snapshotPath: 'older_notes.bak',
        timestamp: DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
        hash: hashText('alpha beta'),
      );
      db.insertSnapshot(
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
  });

  group('DMC Restore', () {
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
      db.insertSnapshot(
        filePath: 'notes.txt',
        snapshotPath: 'older_notes.bak',
        timestamp: DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
        hash: hashText('alpha beta'),
      );
      db.insertSnapshot(
        filePath: 'notes.txt',
        snapshotPath: 'newest_notes.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: hashText('alpha gamma'),
      );
      db.close();

      await undoFile('notes.txt', basePath: tempDir.path);

      expect(await currentFile.readAsString(), 'alpha beta');
    });
  });
}
