import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'database.dart';
import 'workspace.dart';

enum CaptureStatus { captured, unchanged, skipped, failed }

class CaptureResult {
  final CaptureStatus status;
  final int? snapshotId;
  final String? message;

  const CaptureResult(this.status, {this.snapshotId, this.message});
  bool get hadError => status == CaptureStatus.failed;
}

class SnapshotIntegrityException implements Exception {
  final String message;
  const SnapshotIntegrityException(this.message);
  @override
  String toString() => 'Snapshot integrity error: $message';
}

/// All new content is published before metadata, using immutable unique names.
/// A failed metadata commit may leave an orphan; doctor can report it.
class SnapshotStore {
  final DmcDatabase database;
  final String snapshotsPath;

  SnapshotStore({required this.database, required this.snapshotsPath});

  /// Override when adapting source reads to another filesystem.
  Future<List<int>> readSourceBytes(File source) => source.readAsBytes();

  static File snapshotFile(String directory, String name) {
    if (name.isEmpty ||
        p.basename(name) != name ||
        name.contains('\\') ||
        name == '.' ||
        name == '..') {
      throw SnapshotIntegrityException('Invalid snapshot filename: $name');
    }
    final file = File(p.join(directory, name));
    if (FileSystemEntity.typeSync(directory, followLinks: false) ==
            FileSystemEntityType.link ||
        FileSystemEntity.typeSync(file.path, followLinks: false) ==
            FileSystemEntityType.link) {
      throw SnapshotIntegrityException(
        'Snapshot storage must not be a symlink: $name',
      );
    }
    return file;
  }

  /// Return exactly the bytes that were verified, for the caller to consume.
  static Uint8List readVerifiedBytes(
    String directory,
    String name,
    String hash,
  ) {
    final file = snapshotFile(directory, name);
    if (!file.existsSync()) {
      throw SnapshotIntegrityException('Snapshot file not found: $name');
    }
    final bytes = file.readAsBytesSync();
    if (sha256.convert(bytes).toString() != hash) {
      throw SnapshotIntegrityException('SHA-256 mismatch: $name');
    }
    return bytes;
  }

  Future<CaptureResult> captureFile({
    required File source,
    required String relativePath,
    required int timestamp,
    int? burstId,
    String? taskName,
    int? maxFileSizeBytes,
    bool Function(List<int> bytes)? skipContent,
    bool recordInitialAbsence = false,
    bool requireStableRead = false,
  }) async {
    Directory? staging;
    try {
      final paths = DmcPaths(basePath: p.dirname(p.dirname(database.dbPath)));
      paths.resolveFile(source.path);
      paths.validateInternalPath(snapshotsPath);
      final sourceType = FileSystemEntity.typeSync(
        source.path,
        followLinks: false,
      );
      if (sourceType != FileSystemEntityType.file &&
          sourceType != FileSystemEntityType.notFound) {
        return const CaptureResult(
          CaptureStatus.failed,
          message: 'Source is not a regular file',
        );
      }
      if (!await source.exists()) {
        return database.transaction(() {
          final latest = database.getLatestSnapshot(relativePath);
          if (latest == null && !recordInitialAbsence) {
            return const CaptureResult(CaptureStatus.skipped);
          }
          if (latest != null &&
              isTombstoneSnapshot(
                hash: latest.hash,
                snapshotPath: latest.snapshotPath,
              )) {
            return CaptureResult(
              CaptureStatus.unchanged,
              snapshotId: latest.id,
            );
          }
          database.insertTombstone(
            filePath: relativePath,
            timestamp: timestamp,
            burstId: burstId,
            taskName: taskName,
          );
          return CaptureResult(
            CaptureStatus.captured,
            snapshotId: database.db.lastInsertRowId,
          );
        });
      }
      if (maxFileSizeBytes != null &&
          await source.length() > maxFileSizeBytes) {
        return const CaptureResult(
          CaptureStatus.skipped,
          message: 'file exceeds max size',
        );
      }
      // Own one read of the live source. Hash and persist this same byte buffer.
      final beforeRead = requireStableRead ? source.statSync() : null;
      paths.resolveFile(source.path);
      final bytes = Uint8List.fromList(await readSourceBytes(source));
      paths.resolveFile(source.path);
      if (beforeRead != null) {
        final afterRead = source.statSync();
        if (afterRead.type != FileSystemEntityType.file ||
            beforeRead.size != afterRead.size ||
            bytes.length != afterRead.size ||
            beforeRead.modified != afterRead.modified ||
            beforeRead.changed != afterRead.changed) {
          return const CaptureResult(
            CaptureStatus.failed,
            message:
                'Source changed during capture; retry after writers settle',
          );
        }
      }
      if (maxFileSizeBytes != null && bytes.length > maxFileSizeBytes) {
        return const CaptureResult(
          CaptureStatus.skipped,
          message: 'file exceeds max size',
        );
      }
      if (skipContent?.call(bytes) ?? false) {
        return const CaptureResult(
          CaptureStatus.skipped,
          message: 'binary files are not tracked',
        );
      }
      final hash = sha256.convert(bytes).toString();
      final latest = database.getLatestSnapshot(relativePath);
      if (latest != null && latest.hash == hash) {
        readVerifiedBytes(snapshotsPath, latest.snapshotPath, latest.hash);
        return CaptureResult(CaptureStatus.unchanged, snapshotId: latest.id);
      }

      Directory(snapshotsPath).createSync(recursive: true);
      // Same filesystem as the final destination. Random directory allocation
      // prevents timestamp collisions across processes without overwriting blobs.
      staging = Directory(p.dirname(snapshotsPath)).createTempSync('.capture-');
      final name = '${p.basename(staging.path)}-$hash.bak';
      final destination = snapshotFile(snapshotsPath, name);
      if (destination.existsSync()) {
        throw const SnapshotIntegrityException(
          'Snapshot name collision; retry capture.',
        );
      }
      final temporary = File(p.join(staging.path, 'content'));
      final handle = temporary.openSync(mode: FileMode.write);
      try {
        handle.writeFromSync(bytes);
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
      temporary.renameSync(destination.path);
      return database.transaction(() {
        database.insertSnapshot(
          filePath: relativePath,
          snapshotPath: name,
          timestamp: timestamp,
          hash: hash,
          burstId: burstId,
          taskName: taskName,
        );
        return CaptureResult(
          CaptureStatus.captured,
          snapshotId: database.db.lastInsertRowId,
        );
      });
    } catch (e) {
      return CaptureResult(CaptureStatus.failed, message: e.toString());
    } finally {
      if (staging != null) {
        try {
          staging.deleteSync(recursive: true);
        } on FileSystemException catch (e) {
          print('[DMC] Could not remove staging directory: $e');
        }
      }
    }
  }
}
