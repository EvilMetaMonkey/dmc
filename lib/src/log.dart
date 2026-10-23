import 'database.dart';
import 'workspace.dart';

/// Format a Unix timestamp to a human-readable string
String formatTimestamp(int unixTime) {
  final dateTime = DateTime.fromMillisecondsSinceEpoch(unixTime);
  final year = dateTime.year;
  final month = dateTime.month.toString().padLeft(2, '0');
  final day = dateTime.day.toString().padLeft(2, '0');
  final hour = dateTime.hour.toString().padLeft(2, '0');
  final minute = dateTime.minute.toString().padLeft(2, '0');
  final second = dateTime.second.toString().padLeft(2, '0');
  return '$year-$month-$day $hour:$minute:$second';
}

String _formatBurstTimeRange(Iterable<int> timestamps) {
  final sortedTimestamps = timestamps.toList()..sort();
  final start = formatTimestamp(sortedTimestamps.first);
  final end = formatTimestamp(sortedTimestamps.last);
  return start == end ? start : '$start -> $end';
}

void _printBurstLogs(
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
  logs,
) {
  final groupedLogs =
      <
        String,
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
      >{};

  for (final log in logs) {
    final groupKey = log.burstId?.toString() ?? 'legacy-${log.id}';
    groupedLogs.putIfAbsent(groupKey, () => []).add(log);
  }

  print('');
  print('Recent Bursts:');
  print('-' * 60);

  for (final entry in groupedLogs.entries) {
    final burstLogs = entry.value;
    final files = burstLogs.map((log) => log.filePath).toSet().toList();
    final previewPaths = files.take(3).join(', ');
    final remainingCount = files.length - files.take(3).length;
    final extraText = remainingCount > 0 ? ', +$remainingCount more' : '';

    print(
      '[Burst ID: ${entry.key}] ${_formatBurstTimeRange(burstLogs.map((log) => log.timestamp))}',
    );
    print('Files modified: ${files.length}');
    print('Paths: $previewPaths$extraText');
  }

  print('-' * 60);
  print('Total: ${groupedLogs.length} burst(s), ${logs.length} backup(s)');
}

void _printTaskLogs(
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
  logs,
) {
  final groupedLogs =
      <
        String,
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
      >{};

  for (final log in logs) {
    final groupKey = log.taskName ?? 'unassigned';
    groupedLogs.putIfAbsent(groupKey, () => []).add(log);
  }

  print('');
  print('Recent Tasks:');
  print('-' * 60);

  for (final entry in groupedLogs.entries) {
    final taskLogs = entry.value;
    final files = taskLogs.map((log) => log.filePath).toSet().toList();
    final previewPaths = files.take(3).join(', ');
    final remainingCount = files.length - files.take(3).length;
    final extraText = remainingCount > 0 ? ', +$remainingCount more' : '';

    print(
      '[Task: ${entry.key}] ${_formatBurstTimeRange(taskLogs.map((log) => log.timestamp))}',
    );
    print('Files modified: ${files.length}');
    print('Paths: $previewPaths$extraText');
  }

  print('-' * 60);
  print('Total: ${groupedLogs.length} task group(s), ${logs.length} backup(s)');
}

/// Show recent backup logs
Future<int> showLogs({
  int limit = 10,
  String? basePath,
  bool bursts = false,
  bool tasks = false,
}) async {
  final paths = DmcPaths(basePath: basePath);

  final dmcDir = paths.dmcDirectory;
  if (!await dmcDir.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return 1;
  }

  final db = DmcDatabase(paths.dbPath);
  db.initialize();

  final logs = db.getRecentHistory(limit: limit);

  if (logs.isEmpty) {
    print('[DMC] No backup history found.');
    db.close();
    return 0;
  }

  if (bursts) {
    _printBurstLogs(logs);
    db.close();
    return 0;
  }

  if (tasks) {
    _printTaskLogs(logs);
    db.close();
    return 0;
  }

  print('');
  print('Recent Backups:');
  print('-' * 60);

  for (final log in logs) {
    final time = formatTimestamp(log.timestamp);
    print('[ID: ${log.id}] $time - ${log.filePath}');
  }

  print('-' * 60);
  print('Total: ${logs.length} backup(s)');

  db.close();
  return 0;
}
