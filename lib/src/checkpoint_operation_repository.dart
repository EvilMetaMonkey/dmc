import 'checkpoint_models.dart';
import 'checkpoint_operation_models.dart';
import 'database.dart';

class CheckpointOperationRepository {
  final DmcDatabase database;

  const CheckpointOperationRepository(this.database);

  void create(
    CheckpointOperationRecord operation,
    List<CheckpointOperationFileRecord> files,
  ) {
    database.transaction(() {
      database.db.execute(
        '''
        INSERT INTO checkpoint_operations
          (id, checkpoint_id, direction, status, created_at, started_at,
           completed_at, failure_message)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          operation.id,
          operation.checkpointId,
          operation.direction.name,
          checkpointOperationStatusText(operation.status),
          operation.createdAt,
          operation.startedAt,
          operation.completedAt,
          operation.failureMessage,
        ],
      );
      for (final file in files) {
        database.db.execute(
          '''
          INSERT INTO checkpoint_operation_files
            (operation_id, sequence, file_path, expected_kind, expected_hash,
             expected_mode, intended_kind, intended_snapshot_id, intended_hash,
             intended_mode, pre_kind, pre_snapshot_id, pre_hash, pre_mode,
             status, error, recovery_name)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            operation.id,
            file.sequence,
            file.filePath,
            file.expectedKind.name,
            file.expectedHash,
            file.expectedMode,
            file.intendedKind.name,
            file.intendedSnapshotId,
            file.intendedHash,
            file.intendedMode,
            file.preKind.name,
            file.preSnapshotId,
            file.preHash,
            file.preMode,
            checkpointOperationFileStatusText(file.status),
            file.error,
            file.recoveryName,
          ],
        );
      }
    });
  }

  CheckpointOperationRecord? get(String id) {
    final rows = database.db.select(
      'SELECT * FROM checkpoint_operations WHERE id = ? LIMIT 1',
      [id],
    );
    return rows.isEmpty ? null : _operation(rows.single);
  }

  CheckpointOperationView? getView(String id) {
    final operation = get(id);
    return operation == null
        ? null
        : CheckpointOperationView(operation, getFiles(id));
  }

  List<CheckpointOperationFileRecord> getFiles(String operationId) => database
      .db
      .select(
        'SELECT * FROM checkpoint_operation_files WHERE operation_id = ? ORDER BY sequence',
        [operationId],
      )
      .map(_file)
      .toList();

  CheckpointOperationRecord? latestCompletedRestore(String checkpointId) {
    final rows = database.db.select(
      '''
      SELECT * FROM checkpoint_operations
      WHERE checkpoint_id = ? AND direction = 'restore' AND status = 'completed'
      ORDER BY completed_at DESC, created_at DESC, id DESC LIMIT 1
      ''',
      [checkpointId],
    );
    return rows.isEmpty ? null : _operation(rows.single);
  }

  List<CheckpointOperationRecord> forCheckpoint(String checkpointId) => database
      .db
      .select(
        'SELECT * FROM checkpoint_operations WHERE checkpoint_id = ? ORDER BY created_at DESC, id DESC',
        [checkpointId],
      )
      .map(_operation)
      .toList();

  List<CheckpointOperationRecord> incomplete() => database.db
      .select(
        "SELECT * FROM checkpoint_operations WHERE status IN ('planned', 'applying', 'failed', 'rolling_back') ORDER BY created_at, id",
      )
      .map(_operation)
      .toList();

  bool hasIncompleteForCheckpoint(String checkpointId) => database.db.select(
    "SELECT 1 FROM checkpoint_operations WHERE checkpoint_id = ? AND status IN ('planned', 'applying', 'failed', 'rolling_back') LIMIT 1",
    [checkpointId],
  ).isNotEmpty;

  void setStatus(
    String id,
    CheckpointOperationStatus status, {
    int? startedAt,
    int? completedAt,
    String? failureMessage,
  }) {
    database.db.execute(
      '''
      UPDATE checkpoint_operations SET status = ?,
        started_at = COALESCE(?, started_at),
        completed_at = ?, failure_message = ? WHERE id = ?
      ''',
      [
        checkpointOperationStatusText(status),
        startedAt,
        completedAt,
        failureMessage,
        id,
      ],
    );
  }

  void setFileStatus(
    String operationId,
    String filePath,
    CheckpointOperationFileStatus status, {
    String? error,
  }) {
    database.db.execute(
      'UPDATE checkpoint_operation_files SET status = ?, error = ? WHERE operation_id = ? AND file_path = ?',
      [checkpointOperationFileStatusText(status), error, operationId, filePath],
    );
  }

  CheckpointOperationRecord _operation(dynamic row) =>
      CheckpointOperationRecord(
        id: row['id'] as String,
        checkpointId: row['checkpoint_id'] as String,
        direction: CheckpointOperationDirection.values.firstWhere(
          (value) => value.name == row['direction'],
        ),
        status: checkpointOperationStatusFromText(row['status'] as String),
        createdAt: row['created_at'] as int,
        startedAt: row['started_at'] as int?,
        completedAt: row['completed_at'] as int?,
        failureMessage: row['failure_message'] as String?,
      );

  CheckpointOperationFileRecord _file(
    dynamic row,
  ) => CheckpointOperationFileRecord(
    operationId: row['operation_id'] as String,
    sequence: row['sequence'] as int,
    filePath: row['file_path'] as String,
    expectedKind: checkpointFileKindFromText(row['expected_kind'] as String),
    expectedHash: row['expected_hash'] as String?,
    expectedMode: row['expected_mode'] as int?,
    intendedKind: checkpointFileKindFromText(row['intended_kind'] as String),
    intendedSnapshotId: row['intended_snapshot_id'] as int?,
    intendedHash: row['intended_hash'] as String?,
    intendedMode: row['intended_mode'] as int?,
    preKind: checkpointFileKindFromText(row['pre_kind'] as String),
    preSnapshotId: row['pre_snapshot_id'] as int?,
    preHash: row['pre_hash'] as String?,
    preMode: row['pre_mode'] as int?,
    status: checkpointOperationFileStatusFromText(row['status'] as String),
    error: row['error'] as String?,
    recoveryName: row['recovery_name'] as String,
  );
}
