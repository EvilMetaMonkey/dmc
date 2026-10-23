import 'dart:io';
import 'package:path/path.dart' as p;
import 'ignore.dart';
import 'workspace.dart';

class WorkspaceScan {
  final List<String> files = [];
  final List<String> directories = [];
  final Map<String, String> exclusions = {};
  final Map<String, String> errors = {};
}

/// Walk one directory at a time, pruning before descent and never following
/// links. Nested .gitignore files are deliberately rejected, not misinterpreted.
Future<WorkspaceScan> scanWorkspace(
  DmcPaths paths,
  List<IgnoreRule> rules, {
  void Function(String directory)? onDirectory,
}) async {
  final result = WorkspaceScan();
  Future<void> visit(String directory) async {
    try {
      paths.validateInternalPath(directory);
      result.directories.add(directory);
      onDirectory?.call(directory);
      await for (final entity in Directory(
        directory,
      ).list(followLinks: false)) {
        final relative = p.relative(entity.path, from: paths.rootPath);
        final directoryEntry = entity is Directory;
        if (rules.any(
          (rule) => rule.matches(relative, isDirectory: directoryEntry),
        )) {
          result.exclusions[relative] = 'ignored';
          continue;
        }
        if (entity is Link) {
          result.exclusions[relative] = 'symlink';
        } else if (entity is Directory) {
          await visit(entity.path);
        } else if (entity is File) {
          if (p.basename(entity.path) == '.gitignore' &&
              directory != paths.rootPath) {
            result.errors[relative] =
                'Nested .gitignore is not supported. Move protection rules to the root .dmcignore before starting DMC.';
          } else {
            result.files.add(entity.path);
          }
        } else {
          result.exclusions[relative] = 'unsupported file type';
        }
      }
    } catch (e) {
      result.errors[p.relative(directory, from: paths.rootPath)] = e.toString();
    }
  }

  await visit(paths.rootPath);
  return result;
}
