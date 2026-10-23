import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class _CliResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  const _CliResult(this.exitCode, this.stdout, this.stderr);
}

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Pass the compiled dmc executable path.');
  }
  final binary = File(args.single).absolute.path;
  if (!File(binary).existsSync()) {
    throw ArgumentError('Compiled dmc executable not found: $binary');
  }

  final parent = Directory.systemTemp.createTempSync('dmc_haven_reference_');
  final workspace = Directory(p.join(parent.path, "Haven DMC 'contract' Ω"))
    ..createSync();
  const secret = 'DMC_REFERENCE_SECRET_VALUE_49317';
  final modified = File(p.join(workspace.path, 'src', "quoted 'module' Ω.txt"))
    ..createSync(recursive: true);
  final deleted = File(p.join(workspace.path, 'delete me.txt'));
  final created = File(p.join(workspace.path, 'created Ω.txt'));
  modified.writeAsStringSync('before $secret\n');
  deleted.writeAsStringSync('delete before\n');

  Future<_CliResult> run(
    List<String> arguments, {
    int expectedExitCode = 0,
  }) async {
    final process = await Process.run(
      binary,
      arguments,
      workingDirectory: workspace.path,
    ).timeout(const Duration(seconds: 60));
    final result = _CliResult(
      process.exitCode,
      process.stdout as String,
      process.stderr as String,
    );
    if (result.exitCode != expectedExitCode) {
      throw StateError(
        '${arguments.join(' ')} exited ${result.exitCode}; expected '
        '$expectedExitCode\nstdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> jsonCommand(
    List<String> arguments, {
    int expectedExitCode = 0,
  }) async {
    final result = await run(arguments, expectedExitCode: expectedExitCode);
    final output = result.stdout.trim();
    if (output.isEmpty || output.split('\n').length != 1) {
      throw StateError(
        'Expected exactly one JSON line from $arguments: $output',
      );
    }
    if (output.contains(secret)) {
      throw StateError('Machine output exposed file contents.');
    }
    final decoded = jsonDecode(output);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Expected a JSON object from $arguments.');
    }
    if (decoded['exitCode'] != expectedExitCode ||
        decoded['ok'] != (expectedExitCode == 0) ||
        decoded['schemaVersion'] != 1 ||
        decoded['dmcVersion'] == null) {
      throw StateError('Invalid machine envelope from $arguments: $decoded');
    }
    final machineWorkspace = decoded['workspace'];
    if (machineWorkspace is! Map ||
        machineWorkspace['path'] != workspace.resolveSymbolicLinksSync() ||
        !(machineWorkspace['fingerprint'] as String).startsWith('sha256:')) {
      throw StateError('Invalid workspace identity from $arguments: $decoded');
    }
    return decoded;
  }

  try {
    final capabilities = await jsonCommand([
      'capabilities',
      '--json',
      '--schema-version',
      '1',
    ]);
    if (capabilities['data']['contract'] != 'haven-checkpoint-v1' ||
        capabilities['data']['features']['fileContentsInJson'] != false ||
        !(capabilities['data']['commands'] as List).contains(
          'checkpoint.list',
        )) {
      throw StateError('Required Haven capabilities are missing.');
    }

    final unsupported = await jsonCommand([
      'capabilities',
      '--json',
      '--schema-version',
      '999',
    ], expectedExitCode: 2);
    if (unsupported['errors'][0]['code'] != 'unsupported_schema_version') {
      throw StateError('Unsupported schema failure was not explicit.');
    }
    final unknownFlag = await jsonCommand([
      'capabilities',
      '--json',
      '--unknown-haven-flag',
    ], expectedExitCode: 2);
    if (unknownFlag['errors'][0]['code'] != 'invalid_arguments') {
      throw StateError('Unknown flag failure was not explicit.');
    }

    await run(['init']);
    final begin = await jsonCommand([
      'checkpoint',
      'begin',
      '--label',
      "Haven 'quoted' Ω run",
      '--source',
      'haven-reference',
      '--json',
      '--schema-version',
      '1',
    ]);
    final checkpoint = begin['data']['checkpoint'] as Map<String, dynamic>;
    final checkpointId = checkpoint['id'] as String;
    if (checkpoint['status'] != 'open' ||
        checkpoint['protectedFileCount'] != 2) {
      throw StateError('Checkpoint did not open with two protected files.');
    }

    modified.writeAsStringSync('after $secret\n');
    deleted.deleteSync();
    created.writeAsStringSync('created after\n');

    final close = await jsonCommand([
      'checkpoint',
      'close',
      checkpointId,
      '--json',
      '--schema-version',
      '1',
    ]);
    if (close['data']['checkpoint']['status'] != 'closed' ||
        close['data']['checkpoint']['changedFileCount'] != 3) {
      throw StateError('Checkpoint did not close with three changed files.');
    }

    final list = await jsonCommand([
      'checkpoint',
      'list',
      '--limit',
      '10',
      '--json',
      '--schema-version',
      '1',
    ]);
    if (list['data']['count'] != 1 ||
        list['data']['checkpoints'][0]['id'] != checkpointId) {
      throw StateError('Checkpoint list did not return the created run.');
    }
    await jsonCommand([
      'checkpoint',
      'show',
      checkpointId,
      '--json',
      '--schema-version',
      '1',
    ]);
    await jsonCommand([
      'checkpoint',
      'diff',
      checkpointId,
      '--json',
      '--schema-version',
      '1',
    ]);

    final preview = await jsonCommand([
      'checkpoint',
      'restore',
      checkpointId,
      '--json',
      '--schema-version',
      '1',
    ]);
    if (preview['data']['mode'] != 'preview' ||
        preview['data']['applied'] != false ||
        preview['data']['operationId'] != null) {
      throw StateError('Restore preview contract is invalid.');
    }
    if (modified.readAsStringSync() != 'after $secret\n' ||
        deleted.existsSync() ||
        created.readAsStringSync() != 'created after\n') {
      throw StateError('Restore preview changed the workspace.');
    }

    final restore = await jsonCommand([
      'checkpoint',
      'restore',
      checkpointId,
      '--apply',
      '--json',
      '--schema-version',
      '1',
    ]);
    if (restore['data']['operationId'] == null ||
        modified.readAsStringSync() != 'before $secret\n' ||
        deleted.readAsStringSync() != 'delete before\n' ||
        created.existsSync()) {
      throw StateError('Restore did not reproduce the before state.');
    }

    final redoPreview = await jsonCommand([
      'checkpoint',
      'redo',
      checkpointId,
      '--json',
      '--schema-version',
      '1',
    ]);
    if (redoPreview['data']['mode'] != 'preview' ||
        redoPreview['data']['operationId'] != null) {
      throw StateError('Redo preview contract is invalid.');
    }
    final redo = await jsonCommand([
      'checkpoint',
      'redo',
      checkpointId,
      '--apply',
      '--json',
      '--schema-version',
      '1',
    ]);
    if (redo['data']['operationId'] == null ||
        modified.readAsStringSync() != 'after $secret\n' ||
        deleted.existsSync() ||
        created.readAsStringSync() != 'created after\n') {
      throw StateError('Redo did not reproduce the after state.');
    }

    final show = await jsonCommand([
      'checkpoint',
      'show',
      checkpointId,
      '--json',
      '--schema-version',
      '1',
    ]);
    if ((show['data']['operations'] as List).length != 2) {
      throw StateError('Checkpoint show did not expose operation IDs.');
    }
    await jsonCommand([
      'checkpoint',
      'release',
      checkpointId,
      '--json',
      '--schema-version',
      '1',
    ]);
    stdout.writeln('PASS Haven reference lifecycle');
  } finally {
    if (parent.existsSync()) parent.deleteSync(recursive: true);
  }
}
