import 'dart:convert';
import 'dart:io';

/// Test the distributed layout, including native SQLite and daemon startup.
/// Usage: `dart run tool/smoke_bundle.dart <bundle/bin/dmc[.exe]>`
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Pass the bundled executable path.');
  }
  final binary = File(args.single).absolute.path;
  final root = Directory.systemTemp.createTempSync('dmc_bundle_smoke_');
  Future<String> run(List<String> arguments, {int expected = 0}) async {
    final result = await Process.run(
      binary,
      arguments,
      workingDirectory: root.path,
    ).timeout(const Duration(seconds: 45));
    if (result.exitCode != expected) {
      throw StateError(
        '$arguments: exit ${result.exitCode}\n${result.stdout}\n${result.stderr}',
      );
    }
    print('PASS ${arguments.join(' ')}');
    return result.stdout as String;
  }

  try {
    await run(['--help']);
    await run(['--version']);
    final capabilities = jsonDecode(await run(['capabilities', '--json']));
    if (capabilities is! Map ||
        capabilities['schemaVersion'] != 1 ||
        capabilities['dmcVersion'] == null ||
        capabilities['exitCode'] != 0 ||
        capabilities['workspace'] == null ||
        capabilities['data']['features']['checkpointApply'] != true) {
      throw StateError('$capabilities');
    }
    await run([
      'capabilities',
      '--json',
      '--schema-version',
      '999',
    ], expected: 2);
    await run(['init']);
    final file = File(
      '${root.path}${Platform.pathSeparator}notes with spaces.txt',
    );
    file.writeAsStringSync('original\n');
    await run(['start']);
    final status = await run(['status']);
    if (!status.contains('Protection: ready')) throw StateError(status);
    await run(['start'], expected: 1);
    final log = await run(['log']);
    final id = RegExp(r'\[ID: (\d+)\]').firstMatch(log)!.group(1)!;
    file.writeAsStringSync('last before stop\n');
    await run(['stop']);
    await run(['diff', file.uri.pathSegments.last, '--id', id]);
    await run(['restore', file.uri.pathSegments.last, '--id', id, '--dry-run']);
    if (file.readAsStringSync() != 'last before stop\n') {
      throw StateError('Preview modified file');
    }
    await run(['restore', file.uri.pathSegments.last, '--id', id]);
    if (file.readAsStringSync() != 'original\n') {
      throw StateError('Restore lost baseline');
    }
    await run(['redo', file.uri.pathSegments.last]);
    if (file.readAsStringSync() != 'last before stop\n') {
      throw StateError('Stop lost final capture');
    }
    final checkpointBegin =
        jsonDecode(
              await run([
                'checkpoint',
                'begin',
                '--label',
                'bundle smoke',
                '--source',
                'test',
                '--json',
              ]),
            )
            as Map<String, dynamic>;
    if (checkpointBegin['schemaVersion'] != 1 ||
        checkpointBegin['ok'] != true) {
      throw StateError('$checkpointBegin');
    }
    final checkpointId =
        (checkpointBegin['data']['checkpoint'] as Map)['id'] as String;
    file.writeAsStringSync('checkpoint change\n');
    final created = File(
      '${root.path}${Platform.pathSeparator}created by checkpoint.txt',
    )..writeAsStringSync('created\n');
    await run(['checkpoint', 'close', checkpointId, '--json']);
    await run(['checkpoint', 'show', checkpointId, '--json']);
    await run(['checkpoint', 'list', '--json', '--schema-version', '1']);
    await run(['checkpoint', 'diff', checkpointId]);
    await run(['checkpoint', 'restore', checkpointId, '--json']);
    if (file.readAsStringSync() != 'checkpoint change\n' ||
        !created.existsSync()) {
      throw StateError('Checkpoint preview modified workspace');
    }
    final restore = jsonDecode(
      await run(['checkpoint', 'restore', checkpointId, '--apply', '--json']),
    );
    if (restore['ok'] != true ||
        file.readAsStringSync() != 'last before stop\n' ||
        created.existsSync()) {
      throw StateError('Checkpoint restore did not recover pre-state');
    }
    await run(['checkpoint', 'redo', checkpointId, '--json']);
    final redo = jsonDecode(
      await run(['checkpoint', 'redo', checkpointId, '--apply', '--json']),
    );
    if (redo['ok'] != true ||
        file.readAsStringSync() != 'checkpoint change\n' ||
        created.readAsStringSync() != 'created\n') {
      throw StateError('Checkpoint redo did not recover post-state');
    }
    await run(['checkpoint', 'release', checkpointId, '--json']);
    await run(['doctor']);
    await run(['gc', '--dry-run']);
    await run(['--unknown'], expected: 2);
  } finally {
    // Only asks this fixture's authenticated watcher to stop; never kills a PID.
    await Process.run(binary, ['stop'], workingDirectory: root.path);
    root.deleteSync(recursive: true);
  }
}
