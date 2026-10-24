import 'dart:io';

/// CI analyzer gate: fail on any analyzer diagnostic (error, warning, or info).
Future<void> main() async {
  final result = await Process.run(Platform.resolvedExecutable, [
    '--suppress-analytics',
    'analyze',
    '--format',
    'machine',
  ]);
  final output = '${result.stdout}\n${result.stderr}';
  stdout.write(output);
  final diagnostics = output
      .split('\n')
      .where((line) => RegExp(r'^(ERROR|WARNING|INFO)\|').hasMatch(line))
      .toList();
  final unexpected = diagnostics;
  if (unexpected.isNotEmpty || (result.exitCode != 0 && diagnostics.isEmpty)) {
    exitCode = 1;
  }
}
