import 'checkpoint_models.dart';

enum CheckpointOperationDirection { restore, redo }

enum CheckpointOperationStatus {
  planned,
  applying,
  completed,
  failed,
  rollingBack,
  rolledBack,
}

enum CheckpointOperationFileStatus { pending, applied, rolledBack }

CheckpointOperationStatus checkpointOperationStatusFromText(String value) =>
    switch (value) {
      'planned' => CheckpointOperationStatus.planned,
      'applying' => CheckpointOperationStatus.applying,
      'completed' => CheckpointOperationStatus.completed,
      'failed' => CheckpointOperationStatus.failed,
      'rolling_back' => CheckpointOperationStatus.rollingBack,
      'rolled_back' => CheckpointOperationStatus.rolledBack,
      _ => throw FormatException('Unknown checkpoint operation status: $value'),
    };

String checkpointOperationStatusText(CheckpointOperationStatus value) =>
    switch (value) {
      CheckpointOperationStatus.rollingBack => 'rolling_back',
      CheckpointOperationStatus.rolledBack => 'rolled_back',
      _ => value.name,
    };

CheckpointOperationFileStatus checkpointOperationFileStatusFromText(
  String value,
) => switch (value) {
  'pending' => CheckpointOperationFileStatus.pending,
  'applied' => CheckpointOperationFileStatus.applied,
  'rolled_back' => CheckpointOperationFileStatus.rolledBack,
  _ => throw FormatException('Unknown operation file status: $value'),
};

String checkpointOperationFileStatusText(CheckpointOperationFileStatus value) =>
    value == CheckpointOperationFileStatus.rolledBack
    ? 'rolled_back'
    : value.name;

class CheckpointOperationRecord {
  final String id;
  final String checkpointId;
  final CheckpointOperationDirection direction;
  final CheckpointOperationStatus status;
  final int createdAt;
  final int? startedAt;
  final int? completedAt;
  final String? failureMessage;

  const CheckpointOperationRecord({
    required this.id,
    required this.checkpointId,
    required this.direction,
    required this.status,
    required this.createdAt,
    required this.startedAt,
    required this.completedAt,
    required this.failureMessage,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'checkpointId': checkpointId,
    'direction': direction.name,
    'status': checkpointOperationStatusText(status),
    'createdAt': createdAt,
    'startedAt': startedAt,
    'completedAt': completedAt,
    'failureMessage': failureMessage,
  };
}

class CheckpointOperationFileRecord {
  final String operationId;
  final int sequence;
  final String filePath;
  final CheckpointFileKind expectedKind;
  final String? expectedHash;
  final int? expectedMode;
  final CheckpointFileKind intendedKind;
  final int? intendedSnapshotId;
  final String? intendedHash;
  final int? intendedMode;
  final CheckpointFileKind preKind;
  final int? preSnapshotId;
  final String? preHash;
  final int? preMode;
  final CheckpointOperationFileStatus status;
  final String? error;
  final String recoveryName;

  const CheckpointOperationFileRecord({
    required this.operationId,
    required this.sequence,
    required this.filePath,
    required this.expectedKind,
    required this.expectedHash,
    required this.expectedMode,
    required this.intendedKind,
    required this.intendedSnapshotId,
    required this.intendedHash,
    required this.intendedMode,
    required this.preKind,
    required this.preSnapshotId,
    required this.preHash,
    required this.preMode,
    required this.status,
    required this.error,
    required this.recoveryName,
  });

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'path': filePath,
    'expected': {
      'kind': expectedKind.name,
      'hash': expectedHash,
      'mode': expectedMode,
    },
    'intended': {
      'kind': intendedKind.name,
      'snapshotId': intendedSnapshotId,
      'hash': intendedHash,
      'mode': intendedMode,
    },
    'pre': {
      'kind': preKind.name,
      'snapshotId': preSnapshotId,
      'hash': preHash,
      'mode': preMode,
    },
    'status': checkpointOperationFileStatusText(status),
    'error': error,
  };
}

class CheckpointOperationView {
  final CheckpointOperationRecord operation;
  final List<CheckpointOperationFileRecord> files;

  const CheckpointOperationView(this.operation, this.files);

  Map<String, Object?> toJson() => {
    'operation': operation.toJson(),
    'files': files.map((file) => file.toJson()).toList(),
  };
}
