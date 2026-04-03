import 'database.dart';

class RestoreEvent {
  final int id;
  final int timestamp;
  final String command;
  final String filePath;
  final int snapshotId;
  final bool success;
  final String? failureMessage;
  final int? overwrittenSnapshotId;

  const RestoreEvent({
    required this.id,
    required this.timestamp,
    required this.command,
    required this.filePath,
    required this.snapshotId,
    required this.success,
    required this.failureMessage,
    required this.overwrittenSnapshotId,
  });
}

/// Repository for restore audit trail records.
class RestoreEventRepository {
  final DmcDatabase database;

  const RestoreEventRepository(this.database);

  void recordEvent({
    required int timestamp,
    required String command,
    required String filePath,
    required int snapshotId,
    required bool success,
    String? failureMessage,
    int? overwrittenSnapshotId,
  }) {
    database.insertRestoreEvent(
      timestamp: timestamp,
      command: command,
      filePath: filePath,
      snapshotId: snapshotId,
      success: success,
      failureMessage: failureMessage,
      overwrittenSnapshotId: overwrittenSnapshotId,
    );
  }

  List<RestoreEvent> getRecentEvents({int limit = 10}) {
    return database
        .getRecentRestoreEvents(limit: limit)
        .map(
          (event) => RestoreEvent(
            id: event.id,
            timestamp: event.timestamp,
            command: event.command,
            filePath: event.filePath,
            snapshotId: event.snapshotId,
            success: event.success,
            failureMessage: event.failureMessage,
            overwrittenSnapshotId: event.overwrittenSnapshotId,
          ),
        )
        .toList();
  }

  RestoreEvent? getLatestRedoSourceEvent(String filePath) {
    final event = database.getLatestRedoSourceEvent(filePath);
    if (event == null) return null;

    return RestoreEvent(
      id: event.id,
      timestamp: event.timestamp,
      command: event.command,
      filePath: event.filePath,
      snapshotId: event.snapshotId,
      success: event.success,
      failureMessage: event.failureMessage,
      overwrittenSnapshotId: event.overwrittenSnapshotId,
    );
  }
}
