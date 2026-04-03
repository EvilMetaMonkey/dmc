import 'dart:io';

import 'package:path/path.dart' as p;

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

    final directoryOnly = trimmed.endsWith('/') || trimmed.endsWith('\\');
    var normalized = trimmed
        .replaceAll('/', p.separator)
        .replaceAll('\\', p.separator);

    if (normalized.startsWith('.${p.separator}')) {
      normalized = normalized.substring(2);
    }

    normalized = p.normalize(normalized);
    normalized = _trimTrailingSeparators(normalized);

    if (normalized.isEmpty || normalized == '.') return null;

    return IgnoreRule._(
      pattern: normalized,
      directoryOnly: directoryOnly,
      matchAnywhere: !normalized.contains(p.separator),
      hasWildcard: normalized.contains('*') || normalized.contains('?'),
    );
  }

  bool matches(String relativePath) {
    final normalizedRelativePath = p.normalize(relativePath);
    if (normalizedRelativePath.isEmpty || normalizedRelativePath == '.') {
      return false;
    }

    final segments = p.split(normalizedRelativePath);
    if (matchAnywhere) {
      return _matchesSegments(segments);
    }

    return _matchesPath(normalizedRelativePath);
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

    return pathText.startsWith('$patternText/');
  }

  static RegExp _buildRegex(String pattern) {
    final buffer = StringBuffer('^');

    for (final rune in pattern.runes) {
      final char = String.fromCharCode(rune);
      switch (char) {
        case '*':
          buffer.write('[^/]*');
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

Future<List<IgnoreRule>> loadIgnoreRules(String targetPath) async {
  final rules = [
    for (final ignoredDir in ignoredDirs)
      IgnoreRule.defaultDirectory(ignoredDir),
  ];

  final gitRuleCount = await _loadRulesFromFile(
    File(p.join(targetPath, gitIgnoreFileName)),
    rules,
  );
  if (gitRuleCount > 0) {
    print('[DMC] Loaded $gitRuleCount ignore rule(s) from $gitIgnoreFileName');
  }

  final userRuleCount = await _loadRulesFromFile(
    File(p.join(targetPath, dmcIgnoreFileName)),
    rules,
  );

  if (userRuleCount > 0) {
    print('[DMC] Loaded $userRuleCount ignore rule(s) from $dmcIgnoreFileName');
  }

  return rules;
}

Future<int> _loadRulesFromFile(File file, List<IgnoreRule> rules) async {
  if (!await file.exists()) {
    return 0;
  }

  var ruleCount = 0;
  for (final line in await file.readAsLines()) {
    final rule = IgnoreRule.fromPattern(line);
    if (rule == null) continue;

    rules.add(rule);
    ruleCount++;
  }

  return ruleCount;
}
