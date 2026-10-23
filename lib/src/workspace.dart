import 'dart:io';

import 'package:path/path.dart' as p;

/// The name of the DMC directory.
const String dmcDirName = '.dmc';

/// The name of the snapshots subdirectory.
const String snapshotsDirName = 'snapshots';

/// The name of the database file.
const String dbFileName = 'dmc.db';

/// The name of the repo-local config file.
const String configFileName = 'config.json';

/// The name of the active task tracking file.
const String activeTaskFileName = 'active_task.txt';

/// The name of the daemon PID file.
const String daemonPidFileName = 'daemon.pid';
const String operationsDirName = 'operations';

/// Repo-local filesystem locations used by DMC commands.
class DmcPaths {
  final String rootPath;

  DmcPaths._(this.rootPath);

  factory DmcPaths({String? basePath}) {
    final resolvedBasePath = p.normalize(
      p.absolute(basePath ?? Directory.current.path),
    );
    return DmcPaths._(resolvedBasePath);
  }

  String get dmcPath => validateInternalPath(p.join(rootPath, dmcDirName));

  String get snapshotsPath =>
      validateInternalPath(p.join(dmcPath, snapshotsDirName));

  String get dbPath => validateInternalPath(p.join(dmcPath, dbFileName));

  String get configPath =>
      validateInternalPath(p.join(dmcPath, configFileName));

  String get activeTaskPath =>
      validateInternalPath(p.join(dmcPath, activeTaskFileName));

  String get daemonPidPath =>
      validateInternalPath(p.join(dmcPath, daemonPidFileName));

  String get operationsPath =>
      validateInternalPath(p.join(dmcPath, operationsDirName));

  Directory get dmcDirectory => Directory(dmcPath);

  File get configFile => File(configPath);

  File get activeTaskFile => File(activeTaskPath);

  File get daemonPidFile => File(daemonPidPath);

  ResolvedFileTarget resolveFile(String filePath) {
    final target = resolveFileUnchecked(filePath);
    if (!p.isWithin(rootPath, target.absolutePath) &&
        p.normalize(target.absolutePath) != p.normalize(rootPath)) {
      throw ArgumentError.value(
        filePath,
        'filePath',
        'Path must be inside the DMC workspace: $rootPath',
      );
    }
    if (target.relativePath == '.' ||
        p
            .split(target.relativePath)
            .any(
              (part) =>
                  part.toLowerCase() == '.dmc' || part.toLowerCase() == '.git',
            )) {
      throw ArgumentError(
        'DMC cannot track or restore workspace/vault metadata: $filePath',
      );
    }
    validateInternalPath(target.absolutePath);
    return target;
  }

  /// Reject every link below the chosen root, including dangling links and
  /// existing parent components of a path that does not exist yet.
  /// The root itself may be reached through an OS alias (e.g. macOS /var).
  String validateInternalPath(String filePath) {
    final absolute = p.normalize(p.absolute(filePath));
    if (!p.isWithin(rootPath, absolute) && absolute != rootPath) {
      throw ArgumentError('Path must be inside the DMC workspace: $filePath');
    }
    final canonicalRoot = Directory(rootPath).resolveSymbolicLinksSync();
    var current = rootPath;
    for (final part in p.split(p.relative(absolute, from: rootPath))) {
      if (part == '.') continue;
      current = p.join(current, part);
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw ArgumentError('Symlinks are excluded from DMC: $current');
      }
      if (type == FileSystemEntityType.notFound) continue;
      final resolved = type == FileSystemEntityType.directory
          ? Directory(current).resolveSymbolicLinksSync()
          : File(current).resolveSymbolicLinksSync();
      if (!p.isWithin(canonicalRoot, resolved) && resolved != canonicalRoot) {
        throw ArgumentError(
          'Resolved path escapes the DMC workspace: $current',
        );
      }
    }
    return absolute;
  }

  ResolvedFileTarget resolveFileUnchecked(String filePath) {
    final absolutePath = p.isAbsolute(filePath)
        ? p.normalize(filePath)
        : p.normalize(p.join(rootPath, filePath));
    final relativePath = p.normalize(p.relative(absolutePath, from: rootPath));

    return ResolvedFileTarget._(
      rootPath: rootPath,
      inputPath: filePath,
      absolutePath: absolutePath,
      relativePath: relativePath,
      workingPath: p.join(rootPath, relativePath),
    );
  }
}

/// A file path resolved against a DMC workspace.
class ResolvedFileTarget {
  final String rootPath;
  final String inputPath;
  final String absolutePath;
  final String relativePath;
  final String workingPath;

  const ResolvedFileTarget._({
    required this.rootPath,
    required this.inputPath,
    required this.absolutePath,
    required this.relativePath,
    required this.workingPath,
  });

  File get file {
    DmcPaths(basePath: rootPath).resolveFile(workingPath);
    return File(workingPath);
  }
}
