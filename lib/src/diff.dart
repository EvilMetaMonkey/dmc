import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:path/path.dart' as p;
import 'database.dart';
import 'init.dart';

const String _ansiRed = '\x1B[31m';
const String _ansiGreen = '\x1B[32m';
const String _ansiReset = '\x1B[0m';

Future<String> _computeFileHash(File file) async {
  final content = await file.readAsBytes();
  return sha256.convert(content).toString();
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

Future<void> showDiff(String filePath, {String? basePath}) async {
  final cwd = p.normalize(basePath ?? Directory.current.path);
  final dmcPath = p.join(cwd, dmcDirName);
  final snapshotsPath = p.join(dmcPath, snapshotsDirName);
  final dbPath = p.join(dmcPath, dbFileName);

  final dmcDir = Directory(dmcPath);
  if (!await dmcDir.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return;
  }

  final absolutePath = p.isAbsolute(filePath)
      ? p.normalize(filePath)
      : p.normalize(p.join(cwd, filePath));
  final relativePath = p.normalize(p.relative(absolutePath, from: cwd));

  final currentFile = File(p.join(cwd, relativePath));
  if (!await currentFile.exists()) {
    print('[DMC] Error: File not found: $filePath');
    return;
  }

  final db = DmcDatabase(dbPath);
  db.initialize();

  final currentHash = await _computeFileHash(currentFile);
  final snapshot = db.getSnapshotForRestore(relativePath, currentHash);
  if (snapshot == null) {
    print('[DMC] No history found for $filePath');
    db.close();
    return;
  }

  final snapshotFile = File(p.join(snapshotsPath, snapshot.snapshotPath));
  if (!await snapshotFile.exists()) {
    print('[DMC] Error: Snapshot file not found: ${snapshot.snapshotPath}');
    db.close();
    return;
  }

  try {
    final snapshotText = await snapshotFile.readAsString();
    final currentText = await currentFile.readAsString();
    print(buildColorizedDiff(snapshotText, currentText));
  } catch (e) {
    print('[DMC] Error generating diff: $e');
  }

  db.close();
}
