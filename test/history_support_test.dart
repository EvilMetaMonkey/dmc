import 'dart:async';
import 'dart:io';

import 'package:dmc/dmc.dart';
import 'package:dmc/src/history_support.dart';
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

int insertSnapshotAndGetId(
  DmcDatabase db, {
  required String filePath,
  required String snapshotPath,
  required int timestamp,
  required String hash,
}) {
  db.insertSnapshot(
    filePath: filePath,
    snapshotPath: snapshotPath,
    timestamp: timestamp,
    hash: hash,
  );
  return db.db.lastInsertRowId;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dmc_history_support_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('DmcPaths', () {
    test('resolves relative file targets inside the workspace', () {
      final paths = DmcPaths(basePath: tempDir.path);
      final target = paths.resolveFile(p.join('lib', 'main.dart'));

      expect(target.relativePath, p.join('lib', 'main.dart'));
      expect(target.workingPath, p.join(tempDir.path, 'lib', 'main.dart'));
      expect(target.absolutePath, p.join(tempDir.path, 'lib', 'main.dart'));
    });
  });

  group('Snapshot selection', () {
    test('allows id-based lookup when the working file is missing', () async {
      await initDmc(basePath: tempDir.path);

      final paths = DmcPaths(basePath: tempDir.path);
      final snapshotName = 'notes_1.bak';
      final snapshotFile = File(p.join(paths.snapshotsPath, snapshotName));
      await snapshotFile.writeAsString('snapshot text');

      final db = DmcDatabase(paths.dbPath);
      db.initialize();
      final snapshotId = insertSnapshotAndGetId(
        db,
        filePath: 'notes.txt',
        snapshotPath: snapshotName,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: 'snapshot-hash',
      );

      final result = await resolveSnapshotSelection(
        database: db,
        target: paths.resolveFile('notes.txt'),
        id: snapshotId,
        requireExistingTarget: false,
      );

      expect(result.hadLookupError, isFalse);
      expect(result.selection, isNotNull);
      expect(result.selection!.snapshotPath, snapshotName);

      db.close();
    });

    test('reports lookup errors for mismatched snapshot ids', () async {
      await initDmc(basePath: tempDir.path);

      final paths = DmcPaths(basePath: tempDir.path);
      final db = DmcDatabase(paths.dbPath);
      db.initialize();
      final snapshotId = insertSnapshotAndGetId(
        db,
        filePath: 'other.txt',
        snapshotPath: 'other_1.bak',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: 'snapshot-hash',
      );

      final output = await capturePrints(() async {
        final result = await resolveSnapshotSelection(
          database: db,
          target: paths.resolveFile('notes.txt'),
          id: snapshotId,
          requireExistingTarget: false,
        );

        expect(result.selection, isNull);
        expect(result.hadLookupError, isTrue);
      });

      expect(
        output,
        contains(
          '[DMC] Error: Snapshot ID $snapshotId does not belong to notes.txt.',
        ),
      );

      db.close();
    });

    test(
      'selects the previous snapshot when the working file is deleted',
      () async {
        await initDmc(basePath: tempDir.path);

        final paths = DmcPaths(basePath: tempDir.path);
        final snapshotName = 'notes_1.bak';
        final snapshotFile = File(p.join(paths.snapshotsPath, snapshotName));
        await snapshotFile.writeAsString('snapshot text');

        final db = DmcDatabase(paths.dbPath);
        db.initialize();
        insertSnapshotAndGetId(
          db,
          filePath: 'notes.txt',
          snapshotPath: snapshotName,
          timestamp: DateTime.now()
              .subtract(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
          hash: 'snapshot-hash',
        );
        insertSnapshotAndGetId(
          db,
          filePath: 'notes.txt',
          snapshotPath: tombstoneSnapshotPath,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          hash: tombstoneHash,
        );

        final result = await resolveSnapshotSelection(
          database: db,
          target: paths.resolveFile('notes.txt'),
          requireExistingTarget: false,
        );

        expect(result.hadLookupError, isFalse);
        expect(result.selection, isNotNull);
        expect(result.selection!.snapshotPath, snapshotName);
        expect(result.selection!.isTombstone, isFalse);

        db.close();
      },
    );
  });
}
