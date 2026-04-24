import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

String buildSnapshotFilename({
  required String relativePath,
  required int timestamp,
  required String hash,
}) {
  final filename = p.basenameWithoutExtension(relativePath);
  final extension = p.extension(relativePath);
  final normalizedPath = p.normalize(relativePath);
  final pathDigest = sha256.convert(utf8.encode(normalizedPath)).toString();
  final safePathId = pathDigest.substring(0, 12);
  final safeHashId = hash.length <= 12 ? hash : hash.substring(0, 12);

  return '${filename}_${timestamp}_$safePathId$safeHashId$extension.bak';
}
