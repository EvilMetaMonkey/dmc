import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;

import 'diff.dart';
import 'database.dart';
import 'history_support.dart';
import 'log.dart';
import 'restore_events.dart';
import 'snapshot_store.dart';
import 'task.dart';
import 'workspace.dart';

class RestorePlan {
  final SnapshotSelection snapshot;
  final String targetFilePath;
  final String? snapshotFilePath;

  const RestorePlan({
    required this.snapshot,
    required this.targetFilePath,
    required this.snapshotFilePath,
  });
}

class RestorePlanResult {
  final String dbPath;
  final RestorePlan? plan;
  final ResolvedFileTarget target;
  final bool hadError;

  const RestorePlanResult._({
    required this.dbPath,
    required this.plan,
    required this.target,
    required this.hadError,
  });

  factory RestorePlanResult.ready({
    required String dbPath,
    required RestorePlan plan,
    required ResolvedFileTarget target,
  }) {
    return RestorePlanResult._(
      dbPath: dbPath,
      plan: plan,
      target: target,
      hadError: false,
    );
  }

  factory RestorePlanResult.notPossible({
    required String dbPath,
    required ResolvedFileTarget target,
  }) {
    return RestorePlanResult._(
      dbPath: dbPath,
      plan: null,
      target: target,
      hadError: false,
    );
  }

  factory RestorePlanResult.error({
    required String dbPath,
    required ResolvedFileTarget target,
  }) {
    return RestorePlanResult._(
      dbPath: dbPath,
      plan: null,
      target: target,
      hadError: true,
    );
  }
}

class RestoreResult {
  final bool hadError;
  final bool restorePossible;

  const RestoreResult._({
    required this.hadError,
    required this.restorePossible,
  });

  factory RestoreResult.success({required bool restorePossible}) {
    return RestoreResult._(hadError: false, restorePossible: restorePossible);
  }

  factory RestoreResult.error() {
    return const RestoreResult._(hadError: true, restorePossible: false);
  }
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
_latestSnapshotsPerFileInBurst(
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
  snapshots,
) {
  final latestByFile =
      <
        String,
        ({
          int id,
          String filePath,
          String snapshotPath,
          int timestamp,
          String hash,
          int? burstId,
          String? taskName,
        })
      >{};

  for (final snapshot in snapshots) {
    latestByFile.putIfAbsent(snapshot.filePath, () => snapshot);
  }

  final latestSnapshots = latestByFile.values.toList();
  latestSnapshots.sort((left, right) {
    final timestampComparison = right.timestamp.compareTo(left.timestamp);
    if (timestampComparison != 0) {
      return timestampComparison;
    }
    return right.id.compareTo(left.id);
  });
  return latestSnapshots;
}

void _warnIfNewerSnapshotExists({
  required DmcDatabase database,
  required String filePath,
  required int targetSnapshotId,
  required int targetTimestamp,
  required String scopeLabel,
}) {
  final latestSnapshot = database.getLatestSnapshot(filePath);
  if (latestSnapshot == null) return;

  if (latestSnapshot.id != targetSnapshotId &&
      latestSnapshot.timestamp > targetTimestamp) {
    print(
      '[DMC] Warning: $filePath has newer history than $scopeLabel. Restoring snapshot ID $targetSnapshotId anyway.',
    );
  }
}

Future<RestoreResult> _restoreBurstSnapshots(
  int burstId, {
  required String commandName,
  String? basePath,
  bool dryRun = false,
}) async {
  final paths = DmcPaths(basePath: basePath);
  final dmcDir = paths.dmcDirectory;
  if (!await dmcDir.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return RestoreResult.error();
  }

  final db = DmcDatabase(paths.dbPath);
  db.initialize();
  final burstSnapshots = db.getSnapshotsForBurst(burstId);
  if (burstSnapshots.isEmpty) {
    db.close();
    print('[DMC] Error: Burst ID $burstId not found.');
    return RestoreResult.error();
  }

  final targets = _latestSnapshotsPerFileInBurst(burstSnapshots);
  for (final target in targets) {
    final check = await planRestore(
      target.filePath,
      id: target.id,
      basePath: basePath,
    );
    if (check.hadError) {
      db.close();
      return RestoreResult.error();
    }
  }
  print(
    '[DMC] ${dryRun ? 'Burst restore preview' : 'Burst restore'} for $burstId (${targets.length} file(s))',
  );

  var hadError = false;
  var restorePossible = false;
  for (final target in targets) {
    _warnIfNewerSnapshotExists(
      database: db,
      filePath: target.filePath,
      targetSnapshotId: target.id,
      targetTimestamp: target.timestamp,
      scopeLabel: 'burst $burstId',
    );
    print('');
    print(
      '[DMC] ${dryRun ? 'Previewing' : 'Restoring'} ${target.filePath} [Burst: $burstId, Snapshot ID: ${target.id}]',
    );
    final result = await restoreFile(
      target.filePath,
      id: target.id,
      basePath: basePath,
      dryRun: dryRun,
      commandName: commandName,
    );
    hadError = hadError || result.hadError;
    restorePossible = restorePossible || result.restorePossible;
  }

  db.close();
  return RestoreResult._(hadError: hadError, restorePossible: restorePossible);
}

Future<RestoreResult> _redoBurstSnapshots(
  int burstId, {
  String? basePath,
  bool dryRun = false,
}) async {
  final paths = DmcPaths(basePath: basePath);
  final dmcDir = paths.dmcDirectory;
  if (!await dmcDir.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return RestoreResult.error();
  }

  final db = DmcDatabase(paths.dbPath);
  db.initialize();
  final burstSnapshots = db.getSnapshotsForBurst(burstId);
  db.close();

  if (burstSnapshots.isEmpty) {
    print('[DMC] Error: Burst ID $burstId not found.');
    return RestoreResult.error();
  }

  final targets = _latestSnapshotsPerFileInBurst(burstSnapshots);
  for (final target in targets) {
    if ((await planRedo(target.filePath, basePath: basePath)).hadError) {
      return RestoreResult.error();
    }
  }
  print(
    '[DMC] ${dryRun ? 'Burst redo preview' : 'Burst redo'} for $burstId (${targets.length} file(s))',
  );

  var hadError = false;
  var restorePossible = false;
  for (final target in targets) {
    print('');
    print(
      '[DMC] ${dryRun ? 'Previewing' : 'Redoing'} ${target.filePath} [Burst: $burstId]',
    );
    final result = await redoFile(
      target.filePath,
      basePath: basePath,
      dryRun: dryRun,
    );
    hadError = hadError || result.hadError;
    restorePossible = restorePossible || result.restorePossible;
  }

  return RestoreResult._(hadError: hadError, restorePossible: restorePossible);
}

Future<RestoreResult> _restoreTaskSnapshots(
  String taskName, {
  required String commandName,
  String? basePath,
  bool dryRun = false,
}) async {
  final paths = DmcPaths(basePath: basePath);
  final dmcDir = paths.dmcDirectory;
  if (!await dmcDir.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return RestoreResult.error();
  }

  final db = DmcDatabase(paths.dbPath);
  db.initialize();
  final taskSnapshots = db.getSnapshotsForTask(taskName);
  if (taskSnapshots.isEmpty) {
    db.close();
    print('[DMC] Error: Task "$taskName" not found.');
    return RestoreResult.error();
  }

  final targets = _latestSnapshotsPerFileInBurst(taskSnapshots);
  for (final target in targets) {
    final check = await planRestore(
      target.filePath,
      id: target.id,
      basePath: basePath,
    );
    if (check.hadError) {
      db.close();
      return RestoreResult.error();
    }
  }
  print(
    '[DMC] ${dryRun ? 'Task restore preview' : 'Task restore'} for "$taskName" (${targets.length} file(s))',
  );

  var hadError = false;
  var restorePossible = false;
  for (final target in targets) {
    _warnIfNewerSnapshotExists(
      database: db,
      filePath: target.filePath,
      targetSnapshotId: target.id,
      targetTimestamp: target.timestamp,
      scopeLabel: 'task "$taskName"',
    );
    print('');
    print(
      '[DMC] ${dryRun ? 'Previewing' : 'Restoring'} ${target.filePath} [Task: $taskName, Snapshot ID: ${target.id}]',
    );
    final result = await restoreFile(
      target.filePath,
      id: target.id,
      basePath: basePath,
      dryRun: dryRun,
      commandName: commandName,
    );
    hadError = hadError || result.hadError;
    restorePossible = restorePossible || result.restorePossible;
  }

  db.close();
  return RestoreResult._(hadError: hadError, restorePossible: restorePossible);
}

Future<RestoreResult> _redoTaskSnapshots(
  String taskName, {
  String? basePath,
  bool dryRun = false,
}) async {
  final paths = DmcPaths(basePath: basePath);
  final dmcDir = paths.dmcDirectory;
  if (!await dmcDir.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return RestoreResult.error();
  }

  final db = DmcDatabase(paths.dbPath);
  db.initialize();
  final taskSnapshots = db.getSnapshotsForTask(taskName);
  db.close();

  if (taskSnapshots.isEmpty) {
    print('[DMC] Error: Task "$taskName" not found.');
    return RestoreResult.error();
  }

  final targets = _latestSnapshotsPerFileInBurst(taskSnapshots);
  for (final target in targets) {
    if ((await planRedo(target.filePath, basePath: basePath)).hadError) {
      return RestoreResult.error();
    }
  }
  print(
    '[DMC] ${dryRun ? 'Task redo preview' : 'Task redo'} for "$taskName" (${targets.length} file(s))',
  );

  var hadError = false;
  var restorePossible = false;
  for (final target in targets) {
    print('');
    print(
      '[DMC] ${dryRun ? 'Previewing' : 'Redoing'} ${target.filePath} [Task: $taskName]',
    );
    final result = await redoFile(
      target.filePath,
      basePath: basePath,
      dryRun: dryRun,
    );
    hadError = hadError || result.hadError;
    restorePossible = restorePossible || result.restorePossible;
  }

  return RestoreResult._(hadError: hadError, restorePossible: restorePossible);
}

Future<RestorePlanResult> planRestore(
  String filePath, {
  int? id,
  String? basePath,
}) async {
  final paths = DmcPaths(basePath: basePath);
  late final ResolvedFileTarget target;
  try {
    target = paths.resolveFile(filePath);
  } on ArgumentError catch (e) {
    print('[DMC] Error: ${e.message}');
    return RestorePlanResult.error(
      dbPath: paths.dbPath,
      target: paths.resolveFileUnchecked(filePath),
    );
  }

  final dmcDir = paths.dmcDirectory;
  if (!await dmcDir.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return RestorePlanResult.error(dbPath: paths.dbPath, target: target);
  }

  final db = DmcDatabase(paths.dbPath);
  db.initialize();

  final selectionResult = await resolveSnapshotSelection(
    database: db,
    target: target,
    id: id,
    requireExistingTarget: false,
  );
  final snapshot = selectionResult.selection;
  db.close();

  if (snapshot == null) {
    if (selectionResult.hadLookupError) {
      return RestorePlanResult.error(dbPath: paths.dbPath, target: target);
    }
    return RestorePlanResult.notPossible(dbPath: paths.dbPath, target: target);
  }

  String? snapshotFilePath;
  if (!snapshot.isTombstone) {
    snapshotFilePath = p.join(paths.snapshotsPath, snapshot.snapshotPath);
    try {
      SnapshotStore.readVerifiedBytes(
        paths.snapshotsPath,
        snapshot.snapshotPath,
        snapshot.hash,
      );
    } catch (e) {
      print('[DMC] Error: $e');
      return RestorePlanResult.error(dbPath: paths.dbPath, target: target);
    }
  }

  return RestorePlanResult.ready(
    dbPath: paths.dbPath,
    plan: RestorePlan(
      snapshot: snapshot,
      targetFilePath: target.workingPath,
      snapshotFilePath: snapshotFilePath,
    ),
    target: target,
  );
}

Future<RestoreResult> _previewRestorePlan(
  RestorePlanResult planningResult,
) async {
  final plan = planningResult.plan;
  print('[DMC] Restore preview');
  print(
    'Target snapshot ID: ${plan == null ? 'none' : plan.snapshot.snapshotId}',
  );
  print('Target file path: ${planningResult.target.workingPath}');
  print('Restore possible: ${plan == null ? 'no' : 'yes'}');

  if (plan == null) {
    if (!planningResult.hadError) {
      print('Reason: No prior snapshot differs from the current contents.');
      return RestoreResult.success(restorePossible: false);
    }

    return RestoreResult.error();
  }

  try {
    final targetFile = File(plan.targetFilePath);
    final currentText = await targetFile.exists()
        ? await targetFile.readAsString()
        : '';
    final restoredText = plan.snapshot.isTombstone
        ? ''
        : utf8.decode(
            SnapshotStore.readVerifiedBytes(
              p.join(p.dirname(planningResult.dbPath), snapshotsDirName),
              plan.snapshot.snapshotPath,
              plan.snapshot.hash,
            ),
          );
    final action = plan.snapshot.isTombstone
        ? 'File will be deleted'
        : await targetFile.exists()
        ? 'File will be restored'
        : 'File will be recreated';
    print('Action: $action');
    print('Diff (current -> restored):');
    print(buildColorizedDiff(currentText, restoredText));
    return RestoreResult.success(restorePossible: true);
  } catch (e) {
    print('[DMC] Error generating restore preview: $e');
    return RestoreResult.error();
  }
}

Future<int?> _captureCurrentSnapshotIdBeforeRestore(
  DmcDatabase db,
  RestorePlan plan,
) async {
  final targetFile = File(plan.targetFilePath);
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final workspaceRoot = p.dirname(p.dirname(db.dbPath));
  final activeTaskName = readActiveTaskSync(basePath: workspaceRoot);
  final snapshotsPath = p.join(p.dirname(db.dbPath), snapshotsDirName);
  final result = await SnapshotStore(database: db, snapshotsPath: snapshotsPath)
      .captureFile(
        source: targetFile,
        relativePath: plan.snapshot.target.relativePath,
        timestamp: timestamp,
        taskName: activeTaskName,
        recordInitialAbsence: true,
        requireStableRead: true,
      );
  if (result.hadError || result.snapshotId == null) {
    throw StateError('Cannot save pre-restore state: ${result.message}');
  }
  return result.snapshotId;
}

Future<RestoreResult> _applyRestorePlan(
  RestorePlanResult planningResult,
  String filePath,
  String commandName,
) async {
  final plan = planningResult.plan;
  if (plan == null) {
    if (!planningResult.hadError) {
      print('[DMC] No history found for $filePath');
      return RestoreResult.success(restorePossible: false);
    }

    return RestoreResult.error();
  }

  final db = DmcDatabase(planningResult.dbPath);
  db.initialize();
  final repository = RestoreEventRepository(db);
  int? overwrittenSnapshotId;

  try {
    // Recheck at application time, and write the same verified bytes. A preview
    // is not a guarantee that the vault remained intact until apply.
    final restoredBytes = plan.snapshot.isTombstone
        ? null
        : SnapshotStore.readVerifiedBytes(
            p.join(p.dirname(planningResult.dbPath), snapshotsDirName),
            plan.snapshot.snapshotPath,
            plan.snapshot.hash,
          );
    overwrittenSnapshotId = await _captureCurrentSnapshotIdBeforeRestore(
      db,
      plan,
    );
    DmcPaths(
      basePath: p.dirname(p.dirname(planningResult.dbPath)),
    ).resolveFile(plan.targetFilePath);
    if (plan.snapshot.isTombstone) {
      final targetFile = File(plan.targetFilePath);
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
    } else {
      final targetFile = File(plan.targetFilePath);
      await targetFile.parent.create(recursive: true);
      await targetFile.writeAsBytes(restoredBytes!, flush: true);
    }
    repository.recordEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      command: commandName,
      filePath: plan.snapshot.target.relativePath,
      snapshotId: plan.snapshot.snapshotId,
      success: true,
      overwrittenSnapshotId: overwrittenSnapshotId,
    );

    final time = formatTimestamp(plan.snapshot.timestamp);
    final action = plan.snapshot.isTombstone ? 'Deleted' : 'Restored';
    print('[DMC] $action $filePath to version from $time');
    return RestoreResult.success(restorePossible: true);
  } catch (e) {
    try {
      repository.recordEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        command: commandName,
        filePath: plan.snapshot.target.relativePath,
        snapshotId: plan.snapshot.snapshotId,
        success: false,
        failureMessage: e.toString(),
        overwrittenSnapshotId: overwrittenSnapshotId,
      );
    } catch (auditError) {
      print('[DMC] Could not record restore failure: $auditError');
    }
    print('[DMC] Error restoring file: $e');
    return RestoreResult.error();
  } finally {
    db.close();
  }
}

Future<RestorePlanResult> planRedo(String filePath, {String? basePath}) async {
  final paths = DmcPaths(basePath: basePath);
  late final ResolvedFileTarget target;
  try {
    target = paths.resolveFile(filePath);
  } on ArgumentError catch (e) {
    print('[DMC] Error: ${e.message}');
    return RestorePlanResult.error(
      dbPath: paths.dbPath,
      target: paths.resolveFileUnchecked(filePath),
    );
  }

  final dmcDir = paths.dmcDirectory;
  if (!await dmcDir.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return RestorePlanResult.error(dbPath: paths.dbPath, target: target);
  }

  final db = DmcDatabase(paths.dbPath);
  db.initialize();
  final event = RestoreEventRepository(
    db,
  ).getLatestRedoSourceEvent(target.relativePath);
  if (event == null || event.overwrittenSnapshotId == null) {
    db.close();
    print('[DMC] No recent undo found to redo for $filePath');
    return RestorePlanResult.error(dbPath: paths.dbPath, target: target);
  }

  final overwrittenSnapshot = db.getSnapshotById(event.overwrittenSnapshotId!);
  db.close();

  if (overwrittenSnapshot == null ||
      overwrittenSnapshot.filePath != target.relativePath) {
    print('[DMC] No recent undo found to redo for $filePath');
    return RestorePlanResult.error(dbPath: paths.dbPath, target: target);
  }

  return planRestore(
    filePath,
    id: event.overwrittenSnapshotId,
    basePath: basePath,
  );
}

/// Restore a file to its previous state.
Future<RestoreResult> restoreFile(
  String filePath, {
  int? id,
  int? burstId,
  String? taskName,
  String? markName,
  String? basePath,
  bool dryRun = false,
  String commandName = 'restore',
}) async {
  final selectedTargets = [
    if (id != null) 'id',
    if (burstId != null) 'burst',
    if (taskName != null) 'task',
    if (markName != null) 'mark',
  ];
  if (selectedTargets.length > 1) {
    print('[DMC] Error: Use only one of --id, --burst, --task, or --mark.');
    return RestoreResult.error();
  }

  if (burstId != null) {
    return _restoreBurstSnapshots(
      burstId,
      commandName: commandName,
      basePath: basePath,
      dryRun: dryRun,
    );
  }

  if (taskName != null) {
    return _restoreTaskSnapshots(
      taskName,
      commandName: commandName,
      basePath: basePath,
      dryRun: dryRun,
    );
  }

  if (markName != null) {
    final paths = DmcPaths(basePath: basePath);
    final dmcDir = paths.dmcDirectory;
    if (!await dmcDir.exists()) {
      print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
      return RestoreResult.error();
    }

    final db = DmcDatabase(paths.dbPath);
    db.initialize();
    final mark = db.getMarkByName(markName);
    db.close();

    if (mark == null) {
      print('[DMC] Error: Mark "$markName" not found.');
      return RestoreResult.error();
    }

    return _restoreBurstSnapshots(
      mark.burstId,
      commandName: commandName,
      basePath: basePath,
      dryRun: dryRun,
    );
  }

  final planningResult = await planRestore(
    filePath,
    id: id,
    basePath: basePath,
  );
  if (dryRun) {
    return _previewRestorePlan(planningResult);
  }

  return _applyRestorePlan(planningResult, filePath, commandName);
}

/// Backwards-compatible alias for the existing restore behavior.
Future<RestoreResult> undoFile(
  String filePath, {
  int? id,
  int? burstId,
  String? taskName,
  String? markName,
  String? basePath,
  bool dryRun = false,
}) {
  return restoreFile(
    filePath,
    id: id,
    burstId: burstId,
    taskName: taskName,
    markName: markName,
    basePath: basePath,
    dryRun: dryRun,
    commandName: 'undo',
  );
}

Future<RestoreResult> redoFile(
  String filePath, {
  int? burstId,
  String? taskName,
  String? markName,
  String? basePath,
  bool dryRun = false,
}) async {
  final selectedTargets = [
    if (burstId != null) 'burst',
    if (taskName != null) 'task',
    if (markName != null) 'mark',
  ];
  if (selectedTargets.length > 1) {
    print('[DMC] Error: Use only one of --burst, --task, or --mark.');
    return RestoreResult.error();
  }

  if (burstId != null) {
    return _redoBurstSnapshots(burstId, basePath: basePath, dryRun: dryRun);
  }

  if (taskName != null) {
    return _redoTaskSnapshots(taskName, basePath: basePath, dryRun: dryRun);
  }

  if (markName != null) {
    final paths = DmcPaths(basePath: basePath);
    final dmcDir = paths.dmcDirectory;
    if (!await dmcDir.exists()) {
      print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
      return RestoreResult.error();
    }

    final db = DmcDatabase(paths.dbPath);
    db.initialize();
    final mark = db.getMarkByName(markName);
    db.close();

    if (mark == null) {
      print('[DMC] Error: Mark "$markName" not found.');
      return RestoreResult.error();
    }

    return _redoBurstSnapshots(
      mark.burstId,
      basePath: basePath,
      dryRun: dryRun,
    );
  }

  final planningResult = await planRedo(filePath, basePath: basePath);
  if (dryRun) {
    return _previewRestorePlan(planningResult);
  }

  return _applyRestorePlan(planningResult, filePath, 'redo');
}
