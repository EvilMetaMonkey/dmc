import 'dart:io';

import 'package:path/path.dart' as p;

import 'workspace.dart';

class WorkspaceOperationBusy implements Exception {
  const WorkspaceOperationBusy();
}

/// Serializes checkpoint lifecycle and recovery commands across cooperating
/// DMC processes. It does not prevent writes by editors or other programs.
class WorkspaceOperationLock {
  static final Set<String> _heldRoots = {};
  final String _rootKey;
  final RandomAccessFile _file;

  const WorkspaceOperationLock._(this._rootKey, this._file);

  static WorkspaceOperationLock acquire(
    DmcPaths paths, {
    bool readOnly = false,
  }) {
    final rootKey = Directory(paths.rootPath).resolveSymbolicLinksSync();
    if (!_heldRoots.add(rootKey)) throw const WorkspaceOperationBusy();
    RandomAccessFile? file;
    try {
      file = File(
        paths.validateInternalPath(p.join(paths.dmcPath, 'checkpoint.lock')),
      ).openSync(mode: readOnly ? FileMode.read : FileMode.append);
    } catch (_) {
      _heldRoots.remove(rootKey);
      rethrow;
    }
    try {
      file.lockSync(readOnly ? FileLock.shared : FileLock.exclusive);
      return WorkspaceOperationLock._(rootKey, file);
    } on FileSystemException {
      file.closeSync();
      _heldRoots.remove(rootKey);
      throw const WorkspaceOperationBusy();
    } catch (_) {
      file.closeSync();
      _heldRoots.remove(rootKey);
      rethrow;
    }
  }

  void close() {
    try {
      _file.closeSync();
    } finally {
      _heldRoots.remove(_rootKey);
    }
  }
}
