import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dmc/dmc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class MutatingSourceStore extends SnapshotStore {
  int reads = 0;
  MutatingSourceStore({required super.database, required super.snapshotsPath});
  @override
  Future<List<int>> readSourceBytes(File source) async {
    reads++;
    final bytes = await super.readSourceBytes(source);
    await source.writeAsString('changed after read');
    return bytes;
  }
}

void main() {
  late Directory root;
  late DmcPaths paths;
  late DmcDatabase db;
  late SnapshotStore store;
  late File source;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dmc_integrity_');
    paths = DmcPaths(basePath: root.path);
    await initDmc(basePath: root.path);
    db = DmcDatabase(paths.dbPath)..initialize();
    store = SnapshotStore(database: db, snapshotsPath: paths.snapshotsPath);
    source = File(p.join(root.path, 'notes.txt'))..writeAsStringSync('before');
  });
  tearDown(() async {
    db.close();
    await root.delete(recursive: true);
  });

  Future<CaptureResult> capture({
    int timestamp = 10,
    int? burstId,
    String? taskName,
  }) => store.captureFile(
    source: source,
    relativePath: 'notes.txt',
    timestamp: timestamp,
    burstId: burstId,
    taskName: taskName,
  );

  test(
    'source mutation after one read cannot change the saved bytes or hash',
    () async {
      final mutating = MutatingSourceStore(
        database: db,
        snapshotsPath: paths.snapshotsPath,
      );
      final result = await mutating.captureFile(
        source: source,
        relativePath: 'notes.txt',
        timestamp: 10,
      );
      expect(result.status, CaptureStatus.captured);
      expect(mutating.reads, 1);
      final row = db.getSnapshotById(result.snapshotId!)!;
      expect(
        utf8.decode(
          SnapshotStore.readVerifiedBytes(
            paths.snapshotsPath,
            row.snapshotPath,
            row.hash,
          ),
        ),
        'before',
      );
      expect(row.hash, sha256.convert(utf8.encode('before')).toString());
      expect(source.readAsStringSync(), 'changed after read');
      expect(
        paths.dmcDirectory.listSync().where(
          (entry) => p.basename(entry.path).startsWith('.capture-'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'same timestamp preserves distinct snapshots and verified deduplication',
    () async {
      final first = await capture();
      expect((await capture()).status, CaptureStatus.unchanged);
      source.writeAsStringSync('after');
      final second = await capture();
      final a = db.getSnapshotById(first.snapshotId!)!;
      final b = db.getSnapshotById(second.snapshotId!)!;
      expect(a.snapshotPath, isNot(b.snapshotPath));
      expect(
        utf8.decode(
          SnapshotStore.readVerifiedBytes(
            paths.snapshotsPath,
            a.snapshotPath,
            a.hash,
          ),
        ),
        'before',
      );
      expect(
        utf8.decode(
          SnapshotStore.readVerifiedBytes(
            paths.snapshotsPath,
            b.snapshotPath,
            b.hash,
          ),
        ),
        'after',
      );
    },
  );

  test(
    'failed metadata insert leaves only a complete unreferenced blob',
    () async {
      db.db.execute(
        "CREATE TRIGGER fail_insert BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      final result = await capture();
      expect(result.hadError, isTrue);
      expect(db.getHistoryCount(), 0);
      final files = Directory(
        paths.snapshotsPath,
      ).listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(files.single.readAsStringSync(), 'before');
    },
  );

  test('failed file publication cannot commit a history row', () async {
    Directory(paths.snapshotsPath).deleteSync();
    File(paths.snapshotsPath).writeAsStringSync('obstruction');
    expect((await capture()).hadError, isTrue);
    expect(db.getHistoryCount(), 0);
    expect(source.readAsStringSync(), 'before');
  });

  for (final damage in ['corrupt', 'missing']) {
    test(
      '$damage snapshot blocks diff, preview, restore and dedup reuse',
      () async {
        final result = await capture();
        final row = db.getSnapshotById(result.snapshotId!)!;
        final blob = File(p.join(paths.snapshotsPath, row.snapshotPath));
        if (damage == 'corrupt') {
          blob.writeAsStringSync('broken');
        } else {
          blob.deleteSync();
        }
        expect((await capture()).hadError, isTrue);
        source.writeAsStringSync('precious working data');
        expect(
          (await buildDiffOutput(
            'notes.txt',
            id: row.id,
            basePath: root.path,
          )).hadError,
          isTrue,
        );
        expect(
          (await restoreFile(
            'notes.txt',
            id: row.id,
            dryRun: true,
            basePath: root.path,
          )).hadError,
          isTrue,
        );
        expect(
          (await restoreFile(
            'notes.txt',
            id: row.id,
            basePath: root.path,
          )).hadError,
          isTrue,
        );
        expect(source.readAsStringSync(), 'precious working data');
        expect(db.getHistoryCount(), 1);
        expect(db.getRecentRestoreEvents(), isEmpty);
      },
    );
  }

  test('failed preimage capture prevents overwriting the working file', () async {
    final first = await capture();
    source.writeAsStringSync('must survive');
    db.db.execute(
      "CREATE TRIGGER fail_insert BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT, 'injected'); END",
    );
    expect(
      (await restoreFile(
        'notes.txt',
        id: first.snapshotId,
        basePath: root.path,
      )).hadError,
      isTrue,
    );
    expect(source.readAsStringSync(), 'must survive');
    expect(db.getRecentRestoreEvents().single.success, isFalse);
  });

  for (final scope in ['burst', 'task']) {
    test(
      '$scope restore verifies every target before writing the first file',
      () async {
        final first = await capture(burstId: 10, taskName: 'job');
        final other = File(p.join(root.path, 'other.txt'))
          ..writeAsStringSync('old other');
        await store.captureFile(
          source: other,
          relativePath: 'other.txt',
          timestamp: 11,
          burstId: 10,
          taskName: 'job',
        );
        final row = db.getSnapshotById(first.snapshotId!)!;
        File(
          p.join(paths.snapshotsPath, row.snapshotPath),
        ).writeAsStringSync('corrupt last target');
        source.writeAsStringSync('keep notes');
        other.writeAsStringSync('keep other');
        final result = await restoreFile(
          '',
          burstId: scope == 'burst' ? 10 : null,
          taskName: scope == 'task' ? 'job' : null,
          basePath: root.path,
        );
        expect(result.hadError, isTrue);
        expect(other.readAsStringSync(), 'keep other');
        expect(source.readAsStringSync(), 'keep notes');
      },
    );
  }

  for (final scope in ['burst', 'task']) {
    test('$scope redo verifies every preimage before changing files', () async {
      await capture(burstId: 7, taskName: 'job');
      final other = File(p.join(root.path, 'other.txt'))
        ..writeAsStringSync('old other');
      await store.captureFile(
        source: other,
        relativePath: 'other.txt',
        timestamp: 11,
        burstId: 7,
        taskName: 'job',
      );
      source.writeAsStringSync('new notes');
      other.writeAsStringSync('new other');
      expect(
        (await restoreFile('', burstId: 7, basePath: root.path)).hadError,
        isFalse,
      );
      final event = db.getLatestRedoSourceEvent('notes.txt')!;
      final row = db.getSnapshotById(event.overwrittenSnapshotId!)!;
      File(
        p.join(paths.snapshotsPath, row.snapshotPath),
      ).writeAsStringSync('corrupt');
      final result = await redoFile(
        '',
        burstId: scope == 'burst' ? 7 : null,
        taskName: scope == 'task' ? 'job' : null,
        basePath: root.path,
      );
      expect(result.hadError, isTrue);
      expect(source.readAsStringSync(), 'before');
      expect(other.readAsStringSync(), 'old other');
    });
  }

  test(
    'doctor reports a missing database without silently creating one',
    () async {
      db.close();
      File(paths.dbPath).deleteSync();
      expect(await runDoctor(basePath: root.path, homePath: root.path), isTrue);
      expect(File(paths.dbPath).existsSync(), isFalse);
    },
  );

  test('marks and restore references survive retention', () async {
    final marked = await capture(burstId: 7);
    db.db.execute('INSERT INTO marks VALUES (?, ?, ?)', ['safe', 7, 10]);
    source.writeAsStringSync('restore source');
    final referenced = await capture(timestamp: 11);
    source.writeAsStringSync('restore preimage');
    final preimage = await capture(timestamp: 12);
    db.insertRestoreEvent(
      timestamp: 13,
      command: 'restore',
      filePath: 'notes.txt',
      snapshotId: referenced.snapshotId!,
      overwrittenSnapshotId: preimage.snapshotId,
      success: true,
    );
    source.writeAsStringSync('expired');
    await capture(timestamp: 14);
    expect(await db.pruneOldSnapshots(const Duration(hours: 1)), 1);
    for (final id in [
      marked.snapshotId,
      referenced.snapshotId,
      preimage.snapshotId,
    ]) {
      final row = db.getSnapshotById(id!)!;
      expect(
        SnapshotStore.readVerifiedBytes(
          paths.snapshotsPath,
          row.snapshotPath,
          row.hash,
        ),
        isNotEmpty,
      );
    }
  });

  test(
    'shared legacy blob survives removal of an expired unpinned row',
    () async {
      final result = await capture();
      final row = db.getSnapshotById(result.snapshotId!)!;
      db.insertSnapshot(
        filePath: 'other.txt',
        snapshotPath: row.snapshotPath,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        hash: row.hash,
      );
      expect(await db.pruneOldSnapshots(const Duration(hours: 1)), 1);
      expect(
        File(p.join(paths.snapshotsPath, row.snapshotPath)).existsSync(),
        isTrue,
      );
      expect(db.getHistoryCount(), 1);
    },
  );

  test(
    'interrupted GC detaches metadata before unlinking and leaves an orphan',
    () async {
      final result = await capture();
      final row = db.getSnapshotById(result.snapshotId!)!;
      await expectLater(
        db.pruneOldSnapshots(
          const Duration(hours: 1),
          deleteFile: (file) {
            final observer = DmcDatabase(paths.dbPath)..initialize();
            try {
              expect(observer.getHistoryCount(), 0);
            } finally {
              observer.close();
            }
            throw StateError('simulated interruption before unlink');
          },
        ),
        throwsStateError,
      );
      expect(db.getHistoryCount(), 0);
      expect(
        File(p.join(paths.snapshotsPath, row.snapshotPath)).existsSync(),
        isTrue,
      );
    },
  );

  test(
    'failed GC metadata transaction leaves both rows and blobs intact',
    () async {
      await capture();
      source.writeAsStringSync('second');
      final second = await capture(timestamp: 11);
      db.db.execute(
        "CREATE TRIGGER fail_delete BEFORE DELETE ON history WHEN OLD.id = ${second.snapshotId} BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      await expectLater(
        db.pruneOldSnapshots(const Duration(hours: 1)),
        throwsA(isA<Exception>()),
      );
      expect(db.getHistoryCount(), 2);
      for (final row in db.getAllSnapshotRecords()) {
        expect(
          File(p.join(paths.snapshotsPath, row.snapshotPath)).existsSync(),
          isTrue,
        );
      }
    },
  );

  test(
    'doctor separates missing, corrupt, dangling, orphan and staging data',
    () async {
      final captured = await capture();
      final row = db.getSnapshotById(captured.snapshotId!)!;
      File(
        p.join(paths.snapshotsPath, row.snapshotPath),
      ).writeAsStringSync('corrupt');
      db.insertSnapshot(
        filePath: 'missing.txt',
        snapshotPath: 'missing.bak',
        timestamp: 10,
        hash: 'missing',
      );
      db.db.execute('INSERT INTO marks VALUES (?, ?, ?)', [
        'dangling',
        999,
        10,
      ]);
      File(
        p.join(paths.snapshotsPath, 'orphan.bak'),
      ).writeAsStringSync('orphan');
      Directory(p.join(paths.dmcPath, '.capture-interrupted')).createSync();
      final output = <String>[];
      final issues = await runZoned(
        () => runDoctor(basePath: root.path, homePath: root.path),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => output.add(line),
        ),
      );
      expect(issues, isTrue);
      expect(
        output,
        containsAll([
          'Missing snapshot files: 1',
          'Corrupt snapshot files: 1',
          'Dangling database references: 1',
          'Orphaned snapshot files: 1',
          'Staging entries (may be active captures): 1',
        ]),
      );
    },
  );

  test('manual snapshot and CLI return failure when a capture fails', () async {
    db.db.execute(
      "CREATE TRIGGER fail_insert BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT, 'injected'); END",
    );
    expect(
      await takeManualSnapshot(basePath: root.path, homePath: root.path),
      1,
    );
    final previous = Directory.current;
    try {
      Directory.current = root;
      expect(await runCli(['snap']), 1);
    } finally {
      Directory.current = previous;
    }
    expect(db.getHistoryCount(), 0);
  });

  test('malformed tombstone does not authorize deletion', () async {
    db.insertSnapshot(
      filePath: 'notes.txt',
      snapshotPath: 'missing.bak',
      timestamp: 10,
      hash: tombstoneHash,
    );
    final id = db.db.lastInsertRowId;
    expect(
      (await restoreFile('notes.txt', id: id, basePath: root.path)).hadError,
      isTrue,
    );
    expect(source.readAsStringSync(), 'before');
  });

  test('vault paths cannot traverse or follow a snapshot symlink', () async {
    expect(
      () => SnapshotStore.readVerifiedBytes(
        paths.snapshotsPath,
        '../notes.txt',
        'hash',
      ),
      throwsA(isA<SnapshotIntegrityException>()),
    );
    if (!Platform.isWindows) {
      Link(p.join(paths.snapshotsPath, 'linked.bak')).createSync(source.path);
      expect(
        () => SnapshotStore.readVerifiedBytes(
          paths.snapshotsPath,
          'linked.bak',
          sha256.convert(utf8.encode('before')).toString(),
        ),
        throwsA(isA<SnapshotIntegrityException>()),
      );
    }
  });
}
