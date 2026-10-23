import 'dart:io';

import 'package:path/path.dart' as p;
import 'workspace.dart';

/// Directories to ignore when watching for file changes.
const List<String> ignoredDirs = [
  '.git',
  '.dmc',
  '.dart_tool',
  'build',
  'node_modules',
];

/// The name of the optional user ignore file.
const String dmcIgnoreFileName = '.dmcignore';

/// The name of the optional repo-root Git ignore file.
const String gitIgnoreFileName = '.gitignore';

class IgnoreRule {
  final String pattern;
  final bool directoryOnly;
  final bool matchAnywhere;
  final bool hasWildcard;

  const IgnoreRule._({
    required this.pattern,
    required this.directoryOnly,
    required this.matchAnywhere,
    required this.hasWildcard,
  });

  factory IgnoreRule.defaultDirectory(String name) {
    return IgnoreRule._(
      pattern: p.normalize(name),
      directoryOnly: true,
      matchAnywhere: true,
      hasWildcard: false,
    );
  }

  static IgnoreRule? fromPattern(String rawPattern) {
    final trimmed = rawPattern.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) return null;
    if (trimmed.startsWith('!') ||
        trimmed.contains('[') ||
        trimmed.contains(']')) {
      throw FormatException(
        'Unsupported ignore pattern "$trimmed". DMC supports /, *, ** and ?; negation and character classes are not supported.',
      );
    }
    final anchored = trimmed.startsWith('/');

    final directoryOnly = trimmed.endsWith('/') || trimmed.endsWith('\\');
    var normalized = trimmed
        .replaceAll('/', p.separator)
        .replaceAll('\\', p.separator);

    if (normalized.startsWith('.${p.separator}')) {
      normalized = normalized.substring(2);
    }
    while (normalized.startsWith(p.separator)) {
      normalized = normalized.substring(1);
    }

    normalized = p.normalize(normalized);
    normalized = _trimTrailingSeparators(normalized);

    if (normalized.isEmpty || normalized == '.') return null;

    return IgnoreRule._(
      pattern: normalized,
      directoryOnly: directoryOnly,
      matchAnywhere: !anchored && !normalized.contains(p.separator),
      hasWildcard: normalized.contains('*') || normalized.contains('?'),
    );
  }

  bool matches(String relativePath, {bool isDirectory = false}) {
    final normalizedRelativePath = p.normalize(relativePath);
    if (normalizedRelativePath.isEmpty || normalizedRelativePath == '.') {
      return false;
    }

    final segments = p.split(normalizedRelativePath);
    // Match each ancestor as a directory, so directory exclusions also apply
    // to events below a directory that the scanner has pruned.
    for (var length = 1; length <= segments.length; length++) {
      if (directoryOnly && length == segments.length && !isDirectory) continue;
      final candidate = segments.take(length).join(p.separator);
      if (matchAnywhere
          ? _matchesSegments([segments[length - 1]])
          : _matchesPath(candidate)) {
        return true;
      }
    }
    return false;
  }

  bool _matchesSegments(List<String> segments) {
    if (hasWildcard) {
      final regex = _buildRegex(_toPosix(pattern));
      return segments.any((segment) => regex.hasMatch(_toPosix(segment)));
    }

    return segments.any((segment) => _equals(segment, pattern));
  }

  bool _matchesPath(String relativePath) {
    final pathText = _toPosix(relativePath);
    final patternText = _toPosix(pattern);

    if (hasWildcard) {
      final regex = _buildRegex(patternText);
      if (regex.hasMatch(pathText)) return true;
    } else if (_equals(pathText, patternText)) {
      return true;
    }

    return false;
  }

  static RegExp _buildRegex(String pattern) {
    final buffer = StringBuffer('^');

    for (var i = 0; i < pattern.length; i++) {
      final char = pattern[i];
      switch (char) {
        case '*':
          if (i + 1 < pattern.length && pattern[i + 1] == '*') {
            i++;
            if (i + 1 < pattern.length && pattern[i + 1] == '/') {
              buffer.write('(?:.*/)?');
              i++;
            } else {
              buffer.write('.*');
            }
          } else {
            buffer.write('[^/]*');
          }
          break;
        case '?':
          buffer.write('[^/]');
          break;
        default:
          buffer.write(RegExp.escape(char));
      }
    }

    buffer.write(r'$');
    return RegExp(buffer.toString(), caseSensitive: !Platform.isWindows);
  }

  static String _trimTrailingSeparators(String value) {
    var result = value;
    while (result.endsWith(p.separator)) {
      result = result.substring(0, result.length - p.separator.length);
    }
    return result;
  }

  static String _toPosix(String value) {
    return value.replaceAll('\\', '/');
  }

  static bool _equals(String left, String right) {
    if (Platform.isWindows) {
      return left.toLowerCase() == right.toLowerCase();
    }
    return left == right;
  }
}

Future<List<IgnoreRule>> loadIgnoreRules(
  String targetPath, {
  bool announce = true,
}) async {
  final rules = [
    for (final ignoredDir in ignoredDirs)
      IgnoreRule.defaultDirectory(ignoredDir),
  ];

  final gitRuleCount = await _loadRulesFromFile(
    File(p.join(targetPath, gitIgnoreFileName)),
    rules,
  );
  if (announce && gitRuleCount > 0) {
    print('[DMC] Loaded $gitRuleCount ignore rule(s) from $gitIgnoreFileName');
  }

  final userRuleCount = await _loadRulesFromFile(
    File(p.join(targetPath, dmcIgnoreFileName)),
    rules,
  );

  if (announce && userRuleCount > 0) {
    print('[DMC] Loaded $userRuleCount ignore rule(s) from $dmcIgnoreFileName');
  }

  return rules;
}

Future<int> _loadRulesFromFile(File file, List<IgnoreRule> rules) async {
  DmcPaths(basePath: file.parent.path).validateInternalPath(file.path);
  if (!await file.exists()) {
    return 0;
  }

  var ruleCount = 0;
  for (final line in await file.readAsLines()) {
    if (p.basename(file.path) == gitIgnoreFileName && line.contains('\\')) {
      throw FormatException(
        'Git ignore escapes are unsupported: $line. Use simple rules in .dmcignore.',
      );
    }
    final rule = IgnoreRule.fromPattern(line);
    if (rule == null) continue;

    rules.add(rule);
    ruleCount++;
  }

  return ruleCount;
}
