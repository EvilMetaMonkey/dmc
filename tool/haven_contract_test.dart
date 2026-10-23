import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory buildRoot;
  late String binary;

  setUpAll(() async {
    buildRoot = Directory.systemTemp.createTempSync('dmc_haven_build_');
    final output = p.join(buildRoot.path, 'dmc_bundle');
    final build = await Process.run(
      Platform.resolvedExecutable,
      ['build', 'cli', '-o', output],
      workingDirectory: Directory.current.path,
    ).timeout(const Duration(minutes: 3));
    expect(
      build.exitCode,
      0,
      reason: 'stdout: ${build.stdout}\nstderr: ${build.stderr}',
    );
    binary = p.join(
      output,
      'bundle',
      'bin',
      Platform.isWindows ? 'dmc.exe' : 'dmc',
    );
    expect(File(binary).existsSync(), isTrue);
  });

  tearDownAll(() {
    if (buildRoot.existsSync()) buildRoot.deleteSync(recursive: true);
  });

  test(
    'compiled CLI completes the Haven reference lifecycle with argument arrays',
    () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'tool/haven_reference.dart', binary],
        workingDirectory: Directory.current.path,
      ).timeout(const Duration(minutes: 3));
      expect(
        result.exitCode,
        0,
        reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
      expect(result.stdout, contains('PASS Haven reference lifecycle'));
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'forced capture cancellation is detectable and does not change workspace files',
    () async {
      final workspace = Directory.systemTemp.createTempSync(
        'dmc_haven_capture_cancel_',
      );
      try {
        await _run(binary, workspace.path, ['init']);
        final expected = <String, String>{};
        for (var i = 0; i < 500; i++) {
          final name = 'capture file ${i.toString().padLeft(4, '0')} Ω.txt';
          final content = 'original-$i\n${'x' * 8192}';
          File(p.join(workspace.path, name)).writeAsStringSync(content);
          expected[name] = content;
        }

        final process = await Process.start(binary, [
          'checkpoint',
          'begin',
          '--label',
          'cancel capture',
          '--source',
          'haven-test',
          '--json',
          '--schema-version',
          '1',
        ], workingDirectory: workspace.path);
        process.stdout.drain<void>();
        process.stderr.drain<void>();
        final observed = await _waitForStatus(
          binary,
          workspace.path,
          '(creating;',
          process,
        );
        expect(
          observed,
          isTrue,
          reason: 'capture finished before cancellation',
        );
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 10));

        for (final entry in expected.entries) {
          expect(
            File(p.join(workspace.path, entry.key)).readAsStringSync(),
            entry.value,
          );
        }
        final list = await _json(binary, workspace.path, [
          'checkpoint',
          'list',
          '--json',
          '--schema-version',
          '1',
        ]);
        final checkpoints = list['data']['checkpoints'] as List;
        final interrupted = checkpoints.cast<Map>().firstWhere(
          (item) => item['status'] == 'creating',
        );
        final release = await _json(binary, workspace.path, [
          'checkpoint',
          'release',
          interrupted['id'] as String,
          '--json',
          '--schema-version',
          '1',
        ]);
        expect(release['data']['checkpoint']['status'], 'released');
      } finally {
        if (workspace.existsSync()) workspace.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'forced journaled apply cancellation exposes an operation that can resume',
    () async {
      final workspace = Directory.systemTemp.createTempSync(
        'dmc_haven_apply_cancel_',
      );
      try {
        await _run(binary, workspace.path, ['init']);
        final files = <File>[];
        for (var i = 0; i < 350; i++) {
          files.add(
            File(
              p.join(
                workspace.path,
                'nested path',
                "agent file '${i.toString().padLeft(4, '0')}' Ω.txt",
              ),
            )..createSync(recursive: true),
          );
          files.last.writeAsStringSync('before-$i\n${'a' * 4096}');
        }
        final begin = await _json(binary, workspace.path, [
          'checkpoint',
          'begin',
          '--source',
          'haven-test',
          '--json',
          '--schema-version',
          '1',
        ]);
        final checkpointId = begin['data']['checkpoint']['id'] as String;
        for (var i = 0; i < files.length; i++) {
          files[i].writeAsStringSync('after-$i\n${'b' * 4096}');
        }
        await _json(binary, workspace.path, [
          'checkpoint',
          'close',
          checkpointId,
          '--json',
          '--schema-version',
          '1',
        ]);

        final process = await Process.start(binary, [
          'checkpoint',
          'restore',
          checkpointId,
          '--apply',
          '--json',
          '--schema-version',
          '1',
        ], workingDirectory: workspace.path);
        process.stdout.drain<void>();
        process.stderr.drain<void>();
        final operationId = await _waitForApplyingOperation(
          binary,
          workspace.path,
          checkpointId,
          process,
        );
        expect(
          operationId,
          isNotNull,
          reason: 'apply finished before cancellation',
        );
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 10));

        final interrupted = await _json(binary, workspace.path, [
          'checkpoint',
          'show',
          checkpointId,
          '--json',
          '--schema-version',
          '1',
        ]);
        final operation = (interrupted['data']['operations'] as List)
            .cast<Map>()
            .firstWhere((item) => item['id'] == operationId);
        expect(operation['status'], anyOf('planned', 'applying', 'failed'));
        final beforePreview = _inventory(workspace);
        for (final mode in ['--rollback', '--resume']) {
          final preview = await _json(binary, workspace.path, [
            'checkpoint',
            'recover',
            operationId!,
            mode,
            '--preview',
            '--json',
            '--schema-version',
            '1',
          ]);
          expect(preview['data']['preview'], true);
          expect(preview['data']['applied'], false);
          expect(preview['data']['canRecover'], true);
          expect(preview['data']['checkpointId'], checkpointId);
          expect((preview['data']['actions'] as List).length, files.length);
          expect(_inventory(workspace), beforePreview);
        }
        final recovery = await _json(binary, workspace.path, [
          'checkpoint',
          'recover',
          operationId!,
          '--resume',
          '--json',
          '--schema-version',
          '1',
        ]);
        expect(recovery['data']['operationId'], operationId);
        expect(recovery['data']['operation']['status'], 'completed');
        expect(files.first.readAsStringSync(), 'before-0\n${'a' * 4096}');
        expect(
          files.last.readAsStringSync(),
          'before-${files.length - 1}\n${'a' * 4096}',
        );
      } finally {
        if (workspace.existsSync()) workspace.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Map<String, Object?> _inventory(Directory root) => {
  for (final entry in root.listSync(recursive: true, followLinks: false))
    p.relative(entry.path, from: root.path): entry is File
        ? [
            base64Encode(entry.readAsBytesSync()),
            entry.statSync().modified.toIso8601String(),
            entry.statSync().mode,
          ]
        : 'directory',
};

Future<ProcessResult> _run(
  String binary,
  String workspace,
  List<String> arguments, {
  int expectedExitCode = 0,
}) async {
  final result = await Process.run(
    binary,
    arguments,
    workingDirectory: workspace,
  ).timeout(const Duration(seconds: 60));
  expect(
    result.exitCode,
    expectedExitCode,
    reason: '$arguments\nstdout: ${result.stdout}\nstderr: ${result.stderr}',
  );
  return result;
}

Future<Map<String, dynamic>> _json(
  String binary,
  String workspace,
  List<String> arguments, {
  int expectedExitCode = 0,
}) async {
  final result = await _run(
    binary,
    workspace,
    arguments,
    expectedExitCode: expectedExitCode,
  );
  final decoded = jsonDecode((result.stdout as String).trim());
  expect(decoded, isA<Map<String, dynamic>>());
  return decoded as Map<String, dynamic>;
}

Future<bool> _waitForStatus(
  String binary,
  String workspace,
  String needle,
  Process process,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    final result = await Process.run(binary, [
      'status',
    ], workingDirectory: workspace);
    if ((result.stdout as String).contains(needle)) return true;
    if (await _hasExited(process)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return false;
}

Future<String?> _waitForApplyingOperation(
  String binary,
  String workspace,
  String checkpointId,
  Process process,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    final result = await Process.run(binary, [
      'checkpoint',
      'show',
      checkpointId,
      '--json',
      '--schema-version',
      '1',
    ], workingDirectory: workspace);
    if (result.exitCode == 0) {
      final decoded = jsonDecode((result.stdout as String).trim()) as Map;
      final operations = decoded['data']['operations'] as List;
      for (final operation in operations.cast<Map>()) {
        if (operation['status'] == 'applying' ||
            operation['status'] == 'planned') {
          return operation['id'] as String;
        }
      }
    }
    if (await _hasExited(process)) return null;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return null;
}

Future<bool> _hasExited(Process process) async {
  try {
    await process.exitCode.timeout(const Duration(milliseconds: 1));
    return true;
  } on TimeoutException {
    return false;
  }
}
