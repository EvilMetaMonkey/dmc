import 'dart:convert';
import 'package:diff_match_patch/diff_match_patch.dart';
import 'database.dart';
import 'history_support.dart';
import 'snapshot_store.dart';
import 'workspace.dart';

const String _ansiRed = '\x1B[31m';
const String _ansiGreen = '\x1B[32m';
const String _ansiReset = '\x1B[0m';

class DiffOutput {
  final bool hadError;
  final String? output;

  const DiffOutput({required this.hadError, required this.output});
}

String buildColorizedDiff(String oldText, String newText) {
  final dmp = DiffMatchPatch();
  final diffs = dmp.diff(oldText, newText, false);
  dmp.diffCleanupSemantic(diffs);

  final buffer = StringBuffer();
  for (final diff in diffs) {
    switch (diff.operation) {
      case DIFF_INSERT:
        buffer.write(_ansiGreen);
        buffer.write(diff.text);
        buffer.write(_ansiReset);
        break;
      case DIFF_DELETE:
        buffer.write(_ansiRed);
        buffer.write(diff.text);
        buffer.write(_ansiReset);
        break;
      default:
        buffer.write(diff.text);
    }
  }

  buffer.write(_ansiReset);
  return buffer.toString();
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

Future<bool> _showBurstDiff(int burstId, {String? basePath}) async {
  final paths = DmcPaths(basePath: basePath);

  final dmcDir = paths.dmcDirectory;
  if (!await dmcDir.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return true;
  }

  final db = DmcDatabase(paths.dbPath);
  db.initialize();
  final burstSnapshots = db.getSnapshotsForBurst(burstId);
  db.close();

  if (burstSnapshots.isEmpty) {
    print('[DMC] Error: Burst ID $burstId not found.');
    return true;
  }

  final targets = _latestSnapshotsPerFileInBurst(burstSnapshots);
  print('[DMC] Burst diff for $burstId (${targets.length} file(s))');

  var hadError = false;
  for (final target in targets) {
    print('');
    print(
      '[DMC] Diff for ${target.filePath} [Burst: $burstId, Snapshot ID: ${target.id}]',
    );
    final diffHadError = await showDiff(
      target.filePath,
      id: target.id,
      basePath: basePath,
    );
    hadError = hadError || diffHadError;
  }

  return hadError;
}

Future<bool> showDiff(
  String filePath, {
  int? id,
  int? burstId,
  String? basePath,
}) async {
  if (id != null && burstId != null) {
    print('[DMC] Error: Use either --id or --burst, not both.');
    return true;
  }

  if (burstId != null) {
    return _showBurstDiff(burstId, basePath: basePath);
  }

  final diffOutput = await buildDiffOutput(
    filePath,
    id: id,
    basePath: basePath,
  );
  if (diffOutput.output != null) {
    print(diffOutput.output);
  }
  return diffOutput.hadError;
}

Future<DiffOutput> buildDiffOutput(
  String filePath, {
  int? id,
  String? basePath,
}) async {
  final paths = DmcPaths(basePath: basePath);

  final dmcDir = paths.dmcDirectory;
  if (!await dmcDir.exists()) {
    return const DiffOutput(
      hadError: true,
      output: '[DMC] Error: DMC not initialized. Run "dmc init" first.',
    );
  }

  late final ResolvedFileTarget target;
  try {
    target = paths.resolveFile(filePath);
  } on ArgumentError catch (e) {
    return DiffOutput(hadError: true, output: '[DMC] Error: ${e.message}');
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

  if (snapshot == null) {
    if (!selectionResult.hadLookupError) {
      db.close();
      return DiffOutput(
        hadError: false,
        output: '[DMC] No history found for $filePath',
      );
    }
    db.close();
    return const DiffOutput(hadError: true, output: null);
  }

  try {
    final currentText = await target.file.exists()
        ? await target.file.readAsString()
        : '';
    if (snapshot.isTombstone) {
      db.close();
      return DiffOutput(
        hadError: false,
        output: buildColorizedDiff(currentText, ''),
      );
    }

    final snapshotText = utf8.decode(
      SnapshotStore.readVerifiedBytes(
        paths.snapshotsPath,
        snapshot.snapshotPath,
        snapshot.hash,
      ),
    );
    if (!await target.file.exists()) {
      db.close();
      return DiffOutput(
        hadError: false,
        output: buildColorizedDiff('', snapshotText),
      );
    }

    db.close();
    return DiffOutput(
      hadError: false,
      output: buildColorizedDiff(snapshotText, currentText),
    );
  } catch (e) {
    db.close();
    return DiffOutput(
      hadError: true,
      output: '[DMC] Error generating diff: $e',
    );
  }
}
