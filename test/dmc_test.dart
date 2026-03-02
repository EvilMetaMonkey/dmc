import 'dart:io';
import 'package:dmc/dmc.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('DMC Initialization', () {
    late Directory tempDir;

    setUp(() async {
      // Create a temporary directory for each test
      tempDir = await Directory.systemTemp.createTemp('dmc_test_');
    });

    tearDown(() async {
      // Clean up the temporary directory after each test
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

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
}
