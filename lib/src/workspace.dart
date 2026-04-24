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

  String get dmcPath => p.join(rootPath, dmcDirName);

  String get snapshotsPath => p.join(dmcPath, snapshotsDirName);

  String get dbPath => p.join(dmcPath, dbFileName);

  String get configPath => p.join(dmcPath, configFileName);

  String get activeTaskPath => p.join(dmcPath, activeTaskFileName);

  String get daemonPidPath => p.join(dmcPath, daemonPidFileName);

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

    return target;
  }

  ResolvedFileTarget resolveFileUnchecked(String filePath) {
    final absolutePath = p.isAbsolute(filePath)
        ? p.normalize(filePath)
        : p.normalize(p.join(rootPath, filePath));
    final relativePath = p.normalize(p.relative(absolutePath, from: rootPath));

    return ResolvedFileTarget._(
      inputPath: filePath,
      absolutePath: absolutePath,
      relativePath: relativePath,
      workingPath: p.join(rootPath, relativePath),
    );
  }
}

/// A file path resolved against a DMC workspace.
class ResolvedFileTarget {
  final String inputPath;
  final String absolutePath;
  final String relativePath;
  final String workingPath;

  const ResolvedFileTarget._({
    required this.inputPath,
    required this.absolutePath,
    required this.relativePath,
    required this.workingPath,
  });

  File get file => File(workingPath);
}
