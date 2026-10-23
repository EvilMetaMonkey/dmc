import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'version.dart';

const int machineSchemaVersion = 1;
const List<int> supportedMachineSchemaVersions = [machineSchemaVersion];
const List<int> supportedCheckpointManifestVersions = [1];

class MachineMessage {
  final String code;
  final String message;
  final String? path;

  const MachineMessage(this.code, this.message, {this.path});

  Map<String, Object?> toJson() => {
    'code': code,
    'message': message,
    if (path != null) 'path': path,
  };
}

class CommandResult {
  final String command;
  final int exitCode;
  final Map<String, Object?> data;
  final List<MachineMessage> warnings;
  final List<MachineMessage> errors;
  final MachineWorkspace? workspace;

  const CommandResult({
    required this.command,
    required this.exitCode,
    this.data = const {},
    this.warnings = const [],
    this.errors = const [],
    this.workspace,
  });

  bool get ok => exitCode == 0;

  Map<String, Object?> toJson() => {
    'schemaVersion': machineSchemaVersion,
    'dmcVersion': dmcVersion,
    'ok': ok,
    'exitCode': exitCode,
    'command': command,
    if (workspace != null) 'workspace': workspace!.toJson(),
    'data': data,
    'warnings': warnings.map((warning) => warning.toJson()).toList(),
    'errors': errors.map((error) => error.toJson()).toList(),
  };

  String encode() => jsonEncode(toJson());

  CommandResult withWorkspace(String workspacePath) => CommandResult(
    command: command,
    exitCode: exitCode,
    data: data,
    warnings: warnings,
    errors: errors,
    workspace: MachineWorkspace.fromPath(workspacePath),
  );
}

class MachineWorkspace {
  final String path;
  final String fingerprint;

  const MachineWorkspace({required this.path, required this.fingerprint});

  factory MachineWorkspace.fromPath(String workspacePath) {
    final normalized = p.normalize(p.absolute(workspacePath));
    var canonical = normalized;
    try {
      canonical = Directory(normalized).resolveSymbolicLinksSync();
    } on FileSystemException {
      // The normalized absolute path remains deterministic when canonical
      // resolution is unavailable.
    }
    final digest = sha256.convert(utf8.encode(canonical)).toString();
    return MachineWorkspace(path: canonical, fingerprint: 'sha256:$digest');
  }

  Map<String, Object?> toJson() => {'path': path, 'fingerprint': fingerprint};
}

CommandResult? validateMachineSchemaRequest(
  String command,
  String? requestedVersion, {
  required bool json,
}) {
  if (requestedVersion == null) return null;
  if (!json) {
    return machineFailure(
      command,
      2,
      'schema_requires_json',
      '--schema-version is valid only with --json.',
    );
  }
  final parsed = int.tryParse(requestedVersion);
  if (parsed == null || !supportedMachineSchemaVersions.contains(parsed)) {
    return machineFailure(
      command,
      2,
      'unsupported_schema_version',
      'Unsupported machine schema version: $requestedVersion. Supported versions: ${supportedMachineSchemaVersions.join(', ')}.',
    );
  }
  return null;
}

CommandResult machineFailure(
  String command,
  int exitCode,
  String code,
  String message, {
  String? path,
}) => CommandResult(
  command: command,
  exitCode: exitCode,
  errors: [MachineMessage(code, message, path: path)],
);
