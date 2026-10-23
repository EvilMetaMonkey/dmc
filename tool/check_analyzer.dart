import 'dart:io';

/// Preserve the explicitly reviewed user UI warning; fail on every other
/// diagnostic. Remove this exception when that UI work resolves the warning.
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
  final unexpected = diagnostics
      .where(
        (line) =>
            !(line.contains('|UNUSED_ELEMENT|') &&
                line.replaceAll('\\', '/').contains('/lib/src/ui.dart|') &&
                line.contains("'_shiftArtLineLeft'")),
      )
      .toList();
  if (unexpected.isNotEmpty || (result.exitCode != 0 && diagnostics.isEmpty)) {
    exitCode = 1;
  }
}
