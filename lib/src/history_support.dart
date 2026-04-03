import 'dart:io';

import 'package:crypto/crypto.dart';

import 'database.dart';
import 'workspace.dart';

class SnapshotSelection {
  final int snapshotId;
  final ResolvedFileTarget target;
  final String snapshotPath;
  final int timestamp;
  final String hash;

  const SnapshotSelection({
    required this.snapshotId,
    required this.target,
    required this.snapshotPath,
    required this.timestamp,
    required this.hash,
  });

  bool get isTombstone =>
      isTombstoneSnapshot(hash: hash, snapshotPath: snapshotPath);
}

class SnapshotSelectionResult {
  final SnapshotSelection? selection;
  final bool hadLookupError;

  const SnapshotSelectionResult._({
    required this.selection,
    required this.hadLookupError,
  });

  factory SnapshotSelectionResult.success(SnapshotSelection selection) {
    return SnapshotSelectionResult._(
      selection: selection,
      hadLookupError: false,
    );
  }

  factory SnapshotSelectionResult.notFound() {
    return const SnapshotSelectionResult._(
      selection: null,
      hadLookupError: false,
    );
  }

  factory SnapshotSelectionResult.lookupError() {
    return const SnapshotSelectionResult._(
      selection: null,
      hadLookupError: true,
    );
  }
}

Future<String> computeFileHash(File file) async {
  final content = await file.readAsBytes();
  return sha256.convert(content).toString();
}

Future<SnapshotSelectionResult> resolveSnapshotSelection({
  required DmcDatabase database,
  required ResolvedFileTarget target,
  int? id,
  bool requireExistingTarget = true,
}) async {
  final targetExists = await target.file.exists();
  if (requireExistingTarget && !targetExists) {
    print('[DMC] Error: File not found: ${target.inputPath}');
    return SnapshotSelectionResult.lookupError();
  }

  if (id != null) {
    final targetedSnapshot = database.getSnapshotById(id);
    if (targetedSnapshot == null) {
      print('[DMC] Error: Snapshot ID $id not found.');
      return SnapshotSelectionResult.lookupError();
    }

    if (targetedSnapshot.filePath != target.relativePath) {
      print(
        '[DMC] Error: Snapshot ID $id does not belong to ${target.inputPath}.',
      );
      return SnapshotSelectionResult.lookupError();
    }

    return SnapshotSelectionResult.success(
      SnapshotSelection(
        snapshotId: targetedSnapshot.id,
        target: target,
        snapshotPath: targetedSnapshot.snapshotPath,
        timestamp: targetedSnapshot.timestamp,
        hash: targetedSnapshot.hash,
      ),
    );
  }

  final currentHash = targetExists
      ? await computeFileHash(target.file)
      : tombstoneHash;
  final snapshot = database.getSnapshotForRestore(
    target.relativePath,
    currentHash,
  );
  if (snapshot == null) return SnapshotSelectionResult.notFound();

  return SnapshotSelectionResult.success(
    SnapshotSelection(
      snapshotId: snapshot.id,
      target: target,
      snapshotPath: snapshot.snapshotPath,
      timestamp: snapshot.timestamp,
      hash: snapshot.hash,
    ),
  );
}
