import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dmc/dmc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<String> createRoundTripCheckpoint(
  Directory root,
  CheckpointService checkpoints,
) async {
  File(p.join(root.path, 'modified.txt')).writeAsStringSync('before modified');
  File(p.join(root.path, 'deleted.txt')).writeAsStringSync('before deleted');
  File(p.join(root.path, 'old-name.txt')).writeAsStringSync('before renamed');
  final begin = await checkpoints.begin(label: 'round trip', source: 'test');
  expect(begin.exitCode, 0, reason: begin.encode());
  final id = (begin.data['checkpoint'] as Map)['id'] as String;

  File(p.join(root.path, 'modified.txt')).writeAsStringSync('after modified');
  File(p.join(root.path, 'deleted.txt')).deleteSync();
  File(
    p.join(root.path, 'old-name.txt'),
  ).renameSync(p.join(root.path, 'new-name.txt'));
  File(p.join(root.path, 'created.txt')).writeAsStringSync('after created');
  final close = await checkpoints.close(id);
  expect(close.exitCode, 0, reason: close.encode());
  return id;
}

Map<String, String?> roundTripState(Directory root) => {
  for (final name in [
    'modified.txt',
    'deleted.txt',
    'old-name.txt',
    'new-name.txt',
    'created.txt',
  ])
    name: File(p.join(root.path, name)).existsSync()
        ? File(p.join(root.path, name)).readAsStringSync()
        : null,
};

Future<String> createModifiedCheckpoint(
  Directory root,
  CheckpointService checkpoints, {
  int count = 3,
}) async {
  for (var i = 0; i < count; i++) {
    File(p.join(root.path, 'file-$i.txt')).writeAsStringSync('before-$i');
  }
  final begin = await checkpoints.begin(source: 'test');
  expect(begin.exitCode, 0, reason: begin.encode());
  final id = (begin.data['checkpoint'] as Map)['id'] as String;
  for (var i = 0; i < count; i++) {
    File(p.join(root.path, 'file-$i.txt')).writeAsStringSync('after-$i');
  }
  final close = await checkpoints.close(id);
  expect(close.exitCode, 0, reason: close.encode());
  return id;
}

Future<List<String>> capturedPrints(Future<void> Function() action) async {
  final output = <String>[];
  await runZoned(
    action,
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, message) => output.add(message),
    ),
  );
  return output;
}

Future<T> inDirectory<T>(String path, Future<T> Function() action) async {
  final previous = Directory.current.path;
  Directory.current = path;
  try {
    return await action();
  } finally {
    Directory.current = previous;
  }
}

void main() {
  late Directory root;
  late DmcPaths paths;
  late CheckpointService checkpoints;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('dmc_checkpoint_restore_');
    paths = DmcPaths(basePath: root.path);
    await initDmc(basePath: root.path);
    checkpoints = CheckpointService(basePath: root.path, homePath: root.path);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test(
    'preview, restore and redo round-trip every checkpoint change',
    () async {
      final id = await createRoundTripCheckpoint(root, checkpoints);
      final after = roundTripState(root);
      final dbBefore = DmcDatabase(paths.dbPath)..initialize();
      final historyBefore = dbBefore.getHistoryCount();
      final operationsBefore = dbBefore.db
          .select('SELECT COUNT(*) AS count FROM checkpoint_operations')
          .single['count'];
      dbBefore.close();

      final service = CheckpointRestoreService(basePath: root.path);
      final preview = await service.restore(id);
      expect(preview.exitCode, 0, reason: preview.encode());
      expect(preview.data['mode'], 'preview');
      expect(preview.data['applied'], isFalse);
      expect(roundTripState(root), after);
      final dbAfterPreview = DmcDatabase(paths.dbPath)..initialize();
      expect(dbAfterPreview.getHistoryCount(), historyBefore);
      expect(
        dbAfterPreview.db
            .select('SELECT COUNT(*) AS count FROM checkpoint_operations')
            .single['count'],
        operationsBefore,
      );
      dbAfterPreview.close();

      final restore = await service.restore(id, apply: true);
      expect(restore.exitCode, 0, reason: restore.encode());
      expect(restore.data['operationId'], isNotNull);
      expect(roundTripState(root), {
        'modified.txt': 'before modified',
        'deleted.txt': 'before deleted',
        'old-name.txt': 'before renamed',
        'new-name.txt': null,
        'created.txt': null,
      });

      final repeated = await service.restore(id, apply: true);
      expect(repeated.exitCode, 4);
      expect(repeated.errors, isNotEmpty);

      final redoPreview = await service.redo(id);
      expect(redoPreview.exitCode, 0, reason: redoPreview.encode());
      expect(roundTripState(root)['modified.txt'], 'before modified');
      final redo = await service.redo(id, apply: true);
      expect(redo.exitCode, 0, reason: redo.encode());
      expect(roundTripState(root), after);
      expect((await service.redo(id, apply: true)).exitCode, 4);
    },
  );

  test('applying an unchanged checkpoint returns an explicit no-op', () async {
    File(p.join(root.path, 'same.txt')).writeAsStringSync('same');
    final begin = await checkpoints.begin(source: 'test');
    final id = (begin.data['checkpoint'] as Map)['id'] as String;
    expect((await checkpoints.close(id)).exitCode, 0);
    final result = await CheckpointRestoreService(
      basePath: root.path,
    ).restore(id, apply: true);
    expect(result.exitCode, 0, reason: result.encode());
    expect(result.data['mode'], 'apply');
    expect(result.data['noOp'], isTrue);
    final db = DmcDatabase(paths.dbPath)..initialize();
    expect(
      db.db
          .select('SELECT COUNT(*) AS count FROM checkpoint_operations')
          .single['count'],
      0,
    );
    db.close();
  });

  test('restore and redo preserve recorded POSIX permissions', () async {
    if (Platform.isWindows) return;
    final file = File(p.join(root.path, 'executable.sh'))
      ..writeAsStringSync('#!/bin/sh\necho phase\n');
    expect(Process.runSync('chmod', ['600', file.path]).exitCode, 0);
    final begin = await checkpoints.begin(source: 'test');
    final id = (begin.data['checkpoint'] as Map)['id'] as String;
    expect(Process.runSync('chmod', ['755', file.path]).exitCode, 0);
    expect((await checkpoints.close(id)).exitCode, 0);

    final service = CheckpointRestoreService(basePath: root.path);
    expect((await service.restore(id, apply: true)).exitCode, 0);
    expect(file.statSync().mode & 0x1ff, int.parse('600', radix: 8));
    expect((await service.redo(id, apply: true)).exitCode, 0);
    expect(file.statSync().mode & 0x1ff, int.parse('755', radix: 8));
  });

  test('corrupt required snapshot blocks the whole restore', () async {
    final id = await createModifiedCheckpoint(root, checkpoints);
    final before = {
      for (var i = 0; i < 3; i++)
        'file-$i.txt': File(
          p.join(root.path, 'file-$i.txt'),
        ).readAsStringSync(),
    };
    final db = DmcDatabase(paths.dbPath)..initialize();
    final manifest = CheckpointRepository(db).getFiles(id);
    final intended = manifest.firstWhere(
      (file) => file.changeKind == CheckpointChangeKind.modified,
    );
    final row = db.getSnapshotById(intended.beforeSnapshotId!)!;
    db.close();
    SnapshotStore.snapshotFile(
      paths.snapshotsPath,
      row.snapshotPath,
    ).writeAsStringSync('corrupt');

    final result = await CheckpointRestoreService(
      basePath: root.path,
    ).restore(id, apply: true);
    expect(result.exitCode, 5, reason: result.encode());
    expect({
      for (var i = 0; i < 3; i++)
        'file-$i.txt': File(
          p.join(root.path, 'file-$i.txt'),
        ).readAsStringSync(),
    }, before);
    final check = DmcDatabase(paths.dbPath)..initialize();
    expect(
      check.db
          .select('SELECT COUNT(*) AS count FROM checkpoint_operations')
          .single['count'],
      0,
    );
    check.close();
  });

  test('missing required snapshot blocks preview without mutations', () async {
    final id = await createModifiedCheckpoint(root, checkpoints, count: 1);
    final file = File(p.join(root.path, 'file-0.txt'));
    final db = DmcDatabase(paths.dbPath)..initialize();
    final manifest = CheckpointRepository(db).getFiles(id).single;
    final row = db.getSnapshotById(manifest.beforeSnapshotId!)!;
    db.close();
    SnapshotStore.snapshotFile(
      paths.snapshotsPath,
      row.snapshotPath,
    ).deleteSync();

    final result = await CheckpointRestoreService(
      basePath: root.path,
    ).restore(id);
    expect(result.exitCode, 5, reason: result.encode());
    expect(file.readAsStringSync(), 'after-0');
    final check = DmcDatabase(paths.dbPath)..initialize();
    expect(
      check.db
          .select('SELECT COUNT(*) AS count FROM checkpoint_operations')
          .single['count'],
      0,
    );
    check.close();
  });

  test('drift in one file prevents every file mutation', () async {
    final id = await createModifiedCheckpoint(root, checkpoints);
    File(p.join(root.path, 'file-1.txt')).writeAsStringSync('external edit');
    final result = await CheckpointRestoreService(
      basePath: root.path,
    ).restore(id, apply: true);
    expect(result.exitCode, 4, reason: result.encode());
    expect(File(p.join(root.path, 'file-0.txt')).readAsStringSync(), 'after-0');
    expect(
      File(p.join(root.path, 'file-1.txt')).readAsStringSync(),
      'external edit',
    );
    expect(File(p.join(root.path, 'file-2.txt')).readAsStringSync(), 'after-2');
  });

  test(
    'live watcher blocks checkpoint apply before workspace mutation',
    () async {
      final id = await createModifiedCheckpoint(root, checkpoints, count: 1);
      final control = await WatcherControl.acquire(
        paths,
        state: () => {'phase': 'ready', 'ready': true},
      );
      try {
        final result = await CheckpointRestoreService(
          basePath: root.path,
        ).restore(id, apply: true);
        expect(result.exitCode, 4, reason: result.encode());
        expect(result.errors.single.code, 'watcher_running');
        expect(
          File(p.join(root.path, 'file-0.txt')).readAsStringSync(),
          'after-0',
        );
      } finally {
        await control.close();
      }
    },
  );

  test('interrupted apply is journaled and resume completes it', () async {
    final id = await createModifiedCheckpoint(root, checkpoints);
    final failing = CheckpointRestoreService(
      basePath: root.path,
      beforeApplyStep: (sequence, _) {
        if (sequence == 1) throw StateError('injected second-step failure');
      },
    );
    final result = await failing.restore(id, apply: true);
    expect(result.exitCode, 6, reason: result.encode());
    final operationId = result.data['operationId'] as String;
    final db = DmcDatabase(paths.dbPath)..initialize();
    final view = CheckpointOperationRepository(db).getView(operationId)!;
    expect(view.operation.status, CheckpointOperationStatus.failed);
    expect(view.files, hasLength(3));
    expect(view.files.first.status, CheckpointOperationFileStatus.applied);
    expect(view.files[1].status, CheckpointOperationFileStatus.pending);
    db.close();

    final resumed = await CheckpointRestoreService(
      basePath: root.path,
    ).recover(operationId, rollback: false);
    expect(resumed.exitCode, 0, reason: resumed.encode());
    for (var i = 0; i < 3; i++) {
      expect(
        File(p.join(root.path, 'file-$i.txt')).readAsStringSync(),
        'before-$i',
      );
    }
    final finished = DmcDatabase(paths.dbPath)..initialize();
    expect(
      CheckpointOperationRepository(finished).get(operationId)!.status,
      CheckpointOperationStatus.completed,
    );
    finished.close();
    expect(
      Directory(p.join(paths.operationsPath, operationId)).existsSync(),
      isFalse,
    );
  });

  test('interrupted apply can roll back to the exact post-state', () async {
    final id = await createModifiedCheckpoint(root, checkpoints);
    final result = await CheckpointRestoreService(
      basePath: root.path,
      beforeApplyStep: (sequence, _) {
        if (sequence == 1) throw StateError('injected failure');
      },
    ).restore(id, apply: true);
    final operationId = result.data['operationId'] as String;
    final rolledBack = await CheckpointRestoreService(
      basePath: root.path,
    ).recover(operationId, rollback: true);
    expect(rolledBack.exitCode, 0, reason: rolledBack.encode());
    for (var i = 0; i < 3; i++) {
      expect(
        File(p.join(root.path, 'file-$i.txt')).readAsStringSync(),
        'after-$i',
      );
    }
  });

  test(
    'interrupted rollback remains detectable and resumes rollback',
    () async {
      final id = await createModifiedCheckpoint(root, checkpoints);
      final interruptedApply = await CheckpointRestoreService(
        basePath: root.path,
        beforeApplyStep: (sequence, _) {
          if (sequence == 2) throw StateError('stop apply');
        },
      ).restore(id, apply: true);
      final operationId = interruptedApply.data['operationId'] as String;
      final interruptedRollback = await CheckpointRestoreService(
        basePath: root.path,
        beforeRollbackStep: (sequence, _) {
          if (sequence == 0) throw StateError('stop rollback');
        },
      ).recover(operationId, rollback: true);
      expect(
        interruptedRollback.exitCode,
        6,
        reason: interruptedRollback.encode(),
      );
      final db = DmcDatabase(paths.dbPath)..initialize();
      expect(
        CheckpointOperationRepository(db).get(operationId)!.status,
        CheckpointOperationStatus.rollingBack,
      );
      db.close();
      expect(
        (await CheckpointRestoreService(
          basePath: root.path,
        ).recover(operationId, rollback: false)).exitCode,
        3,
      );
      final completed = await CheckpointRestoreService(
        basePath: root.path,
      ).recover(operationId, rollback: true);
      expect(completed.exitCode, 0, reason: completed.encode());
      for (var i = 0; i < 3; i++) {
        expect(
          File(p.join(root.path, 'file-$i.txt')).readAsStringSync(),
          'after-$i',
        );
      }
    },
  );

  test('journal and every step exist before the first mutation', () async {
    final id = await createModifiedCheckpoint(root, checkpoints);
    final result = await CheckpointRestoreService(
      basePath: root.path,
      beforeApplyStep: (_, _) => throw StateError('stop before first step'),
    ).restore(id, apply: true);
    expect(result.exitCode, 6);
    for (var i = 0; i < 3; i++) {
      expect(
        File(p.join(root.path, 'file-$i.txt')).readAsStringSync(),
        'after-$i',
      );
    }
    final db = DmcDatabase(paths.dbPath)..initialize();
    final view = CheckpointOperationRepository(
      db,
    ).getView(result.data['operationId'] as String)!;
    expect(view.files, hasLength(3));
    expect(
      view.files.every(
        (file) => file.status == CheckpointOperationFileStatus.pending,
      ),
      isTrue,
    );
    db.close();
  });

  test(
    'resume handles interruption after original moved to recovery storage',
    () async {
      final id = await createModifiedCheckpoint(root, checkpoints, count: 1);
      final interrupted = await CheckpointRestoreService(
        basePath: root.path,
        beforeApplyStep: (_, _) => throw StateError('simulate process exit'),
      ).restore(id, apply: true);
      final operationId = interrupted.data['operationId'] as String;
      final recoveryDirectory = Directory(
        p.join(paths.operationsPath, operationId),
      )..createSync(recursive: true);
      File(
        p.join(root.path, 'file-0.txt'),
      ).renameSync(p.join(recoveryDirectory.path, '000000.original'));

      final resumed = await CheckpointRestoreService(
        basePath: root.path,
      ).recover(operationId, rollback: false);
      expect(resumed.exitCode, 0, reason: resumed.encode());
      expect(
        File(p.join(root.path, 'file-0.txt')).readAsStringSync(),
        'before-0',
      );
    },
  );

  test(
    'incomplete operation blocks release and is visible to diagnostics',
    () async {
      final id = await createModifiedCheckpoint(root, checkpoints, count: 1);
      final interrupted = await CheckpointRestoreService(
        basePath: root.path,
        beforeApplyStep: (_, _) => throw StateError('injected interruption'),
      ).restore(id, apply: true);
      expect(interrupted.exitCode, 6);
      final operationId = interrupted.data['operationId'] as String;

      final release = await checkpoints.release(id);
      expect(release.exitCode, 6, reason: release.encode());
      expect(release.errors.single.code, 'operation_incomplete');
      final status = await capturedPrints(() async {
        expect(await showStatus(basePath: root.path, homePath: root.path), 0);
      });
      expect(status.join('\n'), contains(operationId));
      final doctor = await capturedPrints(() async {
        expect(
          await runDoctor(basePath: root.path, homePath: root.path),
          isTrue,
        );
      });
      expect(
        doctor.join('\n'),
        contains('Incomplete checkpoint operations: 1'),
      );

      expect(
        (await CheckpointRestoreService(
          basePath: root.path,
        ).recover(operationId, rollback: true)).exitCode,
        0,
      );
      expect((await checkpoints.release(id)).exitCode, 0);
      final db = DmcDatabase(paths.dbPath)..initialize();
      final files = CheckpointOperationRepository(db).getFiles(operationId);
      expect(files.single.intendedSnapshotId, isNull);
      expect(files.single.preSnapshotId, isNull);
      db.close();
    },
  );

  test(
    'symlink swap is rejected without touching its outside target',
    () async {
      final id = await createModifiedCheckpoint(root, checkpoints, count: 1);
      final outside = File(
        p.join(root.parent.path, 'dmc-outside-${root.path.hashCode}.txt'),
      )..writeAsStringSync('outside');
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync();
      });
      final target = File(p.join(root.path, 'file-0.txt'))..deleteSync();
      try {
        Link(target.path).createSync(outside.path);
      } on FileSystemException {
        return;
      }
      final result = await CheckpointRestoreService(
        basePath: root.path,
      ).restore(id, apply: true);
      expect(result.exitCode, 4, reason: result.encode());
      expect(outside.readAsStringSync(), 'outside');
    },
  );

  test(
    'non-directory target parent is rejected during whole-plan preflight',
    () async {
      final begin = await checkpoints.begin(source: 'test');
      final id = (begin.data['checkpoint'] as Map)['id'] as String;
      final nested = File(p.join(root.path, 'nested', 'created.txt'));
      nested.parent.createSync();
      nested.writeAsStringSync('created');
      expect((await checkpoints.close(id)).exitCode, 0);
      final service = CheckpointRestoreService(basePath: root.path);
      expect((await service.restore(id, apply: true)).exitCode, 0);
      nested.parent.deleteSync();
      final blockingParent = File(nested.parent.path)
        ..writeAsStringSync('keep');

      final result = await service.redo(id, apply: true);
      expect(result.exitCode, 4, reason: result.encode());
      expect(blockingParent.readAsStringSync(), 'keep');
    },
  );

  test(
    'CLI mode validation and JSON output follow the machine contract',
    () async {
      final id = await createModifiedCheckpoint(root, checkpoints, count: 1);
      late int conflictCode;
      final conflictOutput = await inDirectory(
        root.path,
        () => capturedPrints(() async {
          conflictCode = await runCli([
            'checkpoint',
            'restore',
            id,
            '--apply',
            '--dry-run',
            '--json',
          ]);
        }),
      );
      expect(conflictCode, 2);
      expect(conflictOutput, hasLength(1));
      expect(jsonDecode(conflictOutput.single)['errors'], isNotEmpty);

      late int previewCode;
      final previewOutput = await inDirectory(
        root.path,
        () => capturedPrints(() async {
          previewCode = await runCli(['checkpoint', 'restore', id, '--json']);
        }),
      );
      expect(previewCode, 0);
      expect(previewOutput, hasLength(1));
      final decoded = jsonDecode(previewOutput.single) as Map<String, dynamic>;
      expect(decoded['command'], 'checkpoint.restore');
      expect(decoded['data']['mode'], 'preview');
      expect(decoded['data']['applied'], isFalse);
    },
  );
}
