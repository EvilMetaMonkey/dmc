import 'dart:convert';
import 'dart:io';

import 'workspace.dart';

const int defaultRetentionHours = 168;
const int defaultMaxFileSizeKb = 2048;
const String globalConfigFileName = '.dmcconfig';

class DmcConfig {
  final int retentionHours;
  final int maxFileSizeKb;
  final String globalConfigPath;
  final String localConfigPath;
  final bool hasGlobalConfig;
  final bool hasLocalConfig;

  const DmcConfig({
    required this.retentionHours,
    required this.maxFileSizeKb,
    required this.globalConfigPath,
    required this.localConfigPath,
    required this.hasGlobalConfig,
    required this.hasLocalConfig,
  });

  Duration get retentionDuration => Duration(hours: retentionHours);

  int get maxFileSizeBytes => maxFileSizeKb * 1024;
}

String resolveGlobalConfigPath({String? homePath}) {
  final resolvedHome =
      homePath ??
      Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'];
  if (resolvedHome == null || resolvedHome.isEmpty) {
    throw StateError('[DMC] Could not determine the user home directory.');
  }

  return '$resolvedHome${Platform.pathSeparator}$globalConfigFileName';
}

Future<DmcConfig> loadDmcConfig({String? basePath, String? homePath}) async {
  final paths = DmcPaths(basePath: basePath);
  final globalConfigPath = resolveGlobalConfigPath(homePath: homePath);
  final globalConfigFile = File(globalConfigPath);
  final localConfigFile = paths.configFile;

  final globalConfig = await _readConfigFile(globalConfigFile);
  final localConfig = await _readConfigFile(localConfigFile);

  final mergedConfig = {...globalConfig, ...localConfig};

  return DmcConfig(
    retentionHours: _readIntSetting(
      mergedConfig,
      'retention_hours',
      defaultRetentionHours,
    ),
    maxFileSizeKb: _readIntSetting(
      mergedConfig,
      'max_file_size_kb',
      defaultMaxFileSizeKb,
    ),
    globalConfigPath: globalConfigPath,
    localConfigPath: paths.configPath,
    hasGlobalConfig: await globalConfigFile.exists(),
    hasLocalConfig: await localConfigFile.exists(),
  );
}

Future<Map<String, Object?>> _readConfigFile(File file) async {
  if (!await file.exists()) {
    return const {};
  }

  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('Config file must contain a JSON object.');
  }

  return decoded;
}

int _readIntSetting(Map<String, Object?> config, String key, int defaultValue) {
  final rawValue = config[key];
  if (rawValue == null) {
    return defaultValue;
  }

  if (rawValue is int) {
    return rawValue;
  }

  if (rawValue is String) {
    final parsedValue = int.tryParse(rawValue);
    if (parsedValue != null) {
      return parsedValue;
    }
  }

  throw FormatException('Invalid value for "$key". Expected an integer.');
}
