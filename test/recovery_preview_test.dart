import 'dart:convert';
import 'dart:io';

import 'package:dmc/dmc.dart';
import 'package:dmc/src/workspace_operation_lock.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'checkpoint_restore_test.dart'
    show
        createModifiedCheckpoint,
        createRoundTripCheckpoint,
        capturedPrints,
        inDirectory;

// Include the whole vault, journals, snapshot bytes and lock file, not just
// user-visible targets. Access times are intentionally not part of the contract.
Map<String, Object?> inventory(Directory root) => {
  for (final entry in root.listSync(recursive: true, followLinks: false))
    p.relative(entry.path, from: root.path): entry is File
        ? [
            base64Encode(entry.readAsBytesSync()),
            entry.statSync().modified.toIso8601String(),
            entry.statSync().mode,
          ]
        : entry is Link
        ? entry.targetSync()
        : 'directory',
};

void main() {
  late Directory root;
  late DmcPaths paths;
  late CheckpointService checkpoints;
  late CheckpointRestoreService service;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('dmc_recovery_preview_');
    paths = DmcPaths(basePath: root.path);
    await initDmc(basePath: root.path);
    checkpoints = CheckpointService(basePath: root.path, homePath: root.path);
    service = CheckpointRestoreService(basePath: root.path);
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<String> interrupt({bool redo = false}) async {
    final checkpointId = await createModifiedCheckpoint(root, checkpoints);
    if (redo) {
      expect((await service.restore(checkpointId, apply: true)).exitCode, 0);
    }
    final broken = CheckpointRestoreService(
      basePath: root.path,
      beforeApplyStep: (sequence, _) {
        if (sequence == 1) throw StateError('injected interruption');
      },
    );
    final result = redo
        ? await broken.redo(checkpointId, apply: true)
        : await broken.restore(checkpointId, apply: true);
    expect(result.exitCode, 6);
    return result.data['operationId'] as String;
  }

  for (final redo in [false, true]) {
    test(
      'preview rollback and resume after interrupted ${redo ? 'redo' : 'restore'} is read only',
      () async {
        final operationId = await interrupt(redo: redo);
        final before = inventory(root);
        for (final rollback in [true, false, true]) {
          final result = await service.recover(
            operationId,
            rollback: rollback,
            preview: true,
          );
          expect(result.exitCode, 0, reason: result.encode());
          expect(result.data['canRecover'], true);
          expect(result.data['applied'], false);
          final actions = result.data['actions'] as List;
          expect(actions.length, 3);
          expect(actions.every((a) => a['target']['kind'] == 'file'), true);
          if (rollback) {
            expect(
              actions.every(
                (a) => jsonEncode(a['target']) == jsonEncode(a['pre']),
              ),
              true,
            );
          }
          expect(actions.any((a) => a['noOp'] == true), true);
          expect(actions.any((a) => a['noOp'] == false), true);
          expect(result.encode(), isNot(contains('snapshotId')));
          expect(result.encode(), isNot(contains('recoveryName')));
          expect(inventory(root), before);
        }
        final expected =
            (await service.recover(
                  operationId,
                  rollback: true,
                  preview: true,
                )).data['actions']
                as List;
        expect(
          (await service.recover(operationId, rollback: true)).exitCode,
          0,
        );
        for (final action in expected) {
          expect(
            File(
              p.join(root.path, action['path'] as String),
            ).readAsStringSync(),
            '${redo ? 'before' : 'after'}-${(action['path'] as String).split('-')[1].split('.')[0]}',
          );
        }
        final terminal = inventory(root);
        expect(
          (await service.recover(
            operationId,
            rollback: true,
            preview: true,
          )).exitCode,
          3,
        );
        expect(inventory(root), terminal);
      },
    );
  }

  test('manual drift blocks preview and execution without changes', () async {
    final id = await interrupt();
    File(p.join(root.path, 'file-0.txt')).writeAsStringSync('manual work');
    final before = inventory(root);
    final preview = await service.recover(id, rollback: true, preview: true);
    expect(preview.exitCode, 4);
    expect(preview.data['canRecover'], false);
    expect(inventory(root), before);
    expect((await service.recover(id, rollback: true)).exitCode, 4);
    expect(
      File(p.join(root.path, 'file-0.txt')).readAsStringSync(),
      'manual work',
    );
  });

  test(
    'corrupt saved pre-state blocks preview and rollback before writes',
    () async {
      final id = await interrupt();
      final db = DmcDatabase(paths.dbPath)..initialize();
      final file = CheckpointOperationRepository(db).getView(id)!.files.first;
      db.close();
      File(
        p.join(paths.operationsPath, id, file.recoveryName),
      ).writeAsStringSync('corrupt');
      final before = inventory(root);
      expect(
        (await service.recover(id, rollback: true, preview: true)).exitCode,
        5,
      );
      expect(inventory(root), before);
      expect((await service.recover(id, rollback: true)).exitCode, 5);
      expect(
        File(p.join(root.path, 'file-0.txt')).readAsStringSync(),
        'before-0',
      );
    },
  );

  test('missing snapshot blocks preview without mutation', () async {
    final id = await interrupt();
    final db = DmcDatabase(paths.dbPath)..initialize();
    final file = CheckpointOperationRepository(db).getView(id)!.files.last;
    final snapshot = db.getSnapshotById(file.preSnapshotId!)!;
    db.close();
    File(p.join(paths.snapshotsPath, snapshot.snapshotPath)).deleteSync();
    final before = inventory(root);
    expect(
      (await service.recover(id, rollback: true, preview: true)).exitCode,
      5,
    );
    expect(inventory(root), before);
  });

  test(
    'interrupted rollback previews rollback only and retains journal',
    () async {
      final id = await interrupt();
      expect(
        (await CheckpointRestoreService(
          basePath: root.path,
          beforeRollbackStep: (_, _) => throw StateError('stop'),
        ).recover(id, rollback: true)).exitCode,
        6,
      );
      final before = inventory(root);
      expect(
        (await service.recover(id, rollback: false, preview: true)).exitCode,
        3,
      );
      final result = await service.recover(id, rollback: true, preview: true);
      expect(result.exitCode, 0);
      expect((result.data['operation'] as Map)['status'], 'rolling_back');
      expect(inventory(root), before);
      expect((await service.recover(id, rollback: true)).exitCode, 0);
    },
  );

  test(
    'preview preserves live WAL bytes and reads committed WAL journal',
    () async {
      final id = await interrupt();
      final db = DmcDatabase(paths.dbPath)..initialize();
      try {
        db.db.execute(
          "UPDATE checkpoint_operations SET failure_message = 'WAL evidence' WHERE id = ?",
          [id],
        );
        final before = inventory(root);
        final result = await service.recover(id, rollback: true, preview: true);
        expect(result.exitCode, 0, reason: result.encode());
        expect(
          (result.data['operation'] as Map)['failureMessage'],
          'WAL evidence',
        );
        expect(inventory(root), before);
      } finally {
        db.close();
      }
    },
  );

  test(
    'unsafe linked target is rejected without touching linked content',
    () async {
      final id = await interrupt();
      final target = File(p.join(root.path, 'file-0.txt'));
      target.deleteSync();
      Link(target.path).createSync(p.join(root.path, 'file-2.txt'));
      final before = inventory(root);
      final result = await service.recover(id, rollback: true, preview: true);
      expect(result.exitCode, 4);
      expect(result.data['canRecover'], false);
      expect(inventory(root), before);
    },
    skip: Platform.isWindows
        ? 'Symlink privilege is platform-dependent'
        : false,
  );

  test('missing lock is not recreated by preview', () async {
    final id = await interrupt();
    File(p.join(paths.dmcPath, 'checkpoint.lock')).deleteSync();
    final before = inventory(root);
    expect(
      (await service.recover(id, rollback: true, preview: true)).exitCode,
      1,
    );
    expect(inventory(root), before);
  });

  test('active operation lock blocks preview', () async {
    final id = await interrupt();
    final lock = WorkspaceOperationLock.acquire(paths);
    try {
      final before = inventory(root);
      expect(
        (await service.recover(id, rollback: true, preview: true)).exitCode,
        6,
      );
      expect(inventory(root), before);
    } finally {
      lock.close();
    }
  });

  test('older metadata is rejected without migration', () async {
    final id = await interrupt();
    final db = DmcDatabase(paths.dbPath)..initialize();
    db.db.execute('PRAGMA user_version = 2');
    db.close();
    final before = inventory(root);
    expect(
      (await service.recover(id, rollback: true, preview: true)).exitCode,
      1,
    );
    expect(inventory(root), before);
  });

  test(
    'unreadable target blocks preview and retains bytes and modes',
    () async {
      final id = await interrupt();
      final path = p.join(root.path, 'file-0.txt');
      final before = inventory(root);
      expect(Process.runSync('chmod', ['000', path]).exitCode, 0);
      try {
        final result = await service.recover(id, rollback: true, preview: true);
        expect(result.exitCode, 4);
        expect(result.data['canRecover'], false);
        expect(File(path).statSync().mode & 0x1ff, 0);
      } finally {
        Process.runSync('chmod', ['644', path]);
      }
      // chmod changes mode/ctime but must not change the file's mtime or bytes.
      expect(inventory(root), before);
    },
    skip: Platform.isWindows || Platform.environment['USER'] == 'root'
        ? 'Requires POSIX permissions and an unprivileged process'
        : false,
  );

  test(
    'mixed create/delete targets and planned/applying states are explicit',
    () async {
      final checkpointId = await createRoundTripCheckpoint(root, checkpoints);
      final result = await CheckpointRestoreService(
        basePath: root.path,
        beforeApplyStep: (seq, _) {
          if (seq == 2) throw StateError('stop');
        },
      ).restore(checkpointId, apply: true);
      final id = result.data['operationId'] as String;
      for (final status in ['planned', 'applying']) {
        final db = DmcDatabase(paths.dbPath)..initialize();
        db.db.execute(
          'UPDATE checkpoint_operations SET status = ? WHERE id = ?',
          [status, id],
        );
        db.close();
        final before = inventory(root);
        final preview = await service.recover(
          id,
          rollback: true,
          preview: true,
        );
        expect(preview.exitCode, 0, reason: preview.encode());
        final actions = preview.data['actions'] as List;
        expect(actions.any((a) => a['target']['kind'] == 'absent'), true);
        expect(actions.any((a) => a['target']['kind'] == 'file'), true);
        expect(inventory(root), before);
      }
      final actions =
          (await service.recover(
                id,
                rollback: true,
                preview: true,
              )).data['actions']
              as List;
      expect((await service.recover(id, rollback: true)).exitCode, 0);
      for (final action in actions) {
        expect(
          readWorkspaceState(paths, action['path'] as String).toJson(),
          action['target'],
        );
      }
    },
  );

  test('completed operation preview is rejected without changes', () async {
    final checkpointId = await createModifiedCheckpoint(root, checkpoints);
    final result = await service.restore(checkpointId, apply: true);
    final before = inventory(root);
    expect(
      (await service.recover(
        result.data['operationId'] as String,
        rollback: true,
        preview: true,
      )).exitCode,
      3,
    );
    expect(inventory(root), before);
  });

  test('CLI advertises preview and returns one schema 1 envelope', () async {
    final id = await interrupt();
    final before = inventory(root);
    final lines = await inDirectory(
      root.path,
      () => capturedPrints(() async {
        expect(
          await runCli([
            'checkpoint',
            'recover',
            id,
            '--rollback',
            '--preview',
            '--json',
            '--schema-version',
            '1',
          ]),
          0,
        );
      }),
    );
    expect(lines.length, 1);
    final result = jsonDecode(lines.single) as Map;
    expect(result['command'], 'checkpoint.recover');
    expect(result['data']['preview'], true);
    expect(inventory(root), before);
    final capabilities = await capturedPrints(() async {
      expect(await runCli(['capabilities', '--json']), 0);
    });
    expect(
      jsonDecode(
        capabilities.single,
      )['data']['features']['operationRecoveryPreview'],
      true,
    );
    final invalid = await capturedPrints(() async {
      expect(
        await runCli(['checkpoint', 'recover', id, '--preview', '--json']),
        2,
      );
    });
    expect(invalid.length, 1);
  });
}
