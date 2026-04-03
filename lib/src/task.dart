import 'workspace.dart';

String? readActiveTaskSync({String? basePath}) {
  final paths = DmcPaths(basePath: basePath);
  final file = paths.activeTaskFile;
  if (!file.existsSync()) {
    return null;
  }

  final value = file.readAsStringSync().trim();
  return value.isEmpty ? null : value;
}

Future<void> startTask(String name, {String? basePath}) async {
  final trimmedName = name.trim();
  if (trimmedName.isEmpty) {
    print('[DMC] Error: Task name cannot be empty.');
    return;
  }

  final paths = DmcPaths(basePath: basePath);
  if (!await paths.dmcDirectory.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return;
  }

  await paths.activeTaskFile.writeAsString(trimmedName);
  print('[DMC] Active task: $trimmedName');
}

Future<void> endTask({String? basePath}) async {
  final paths = DmcPaths(basePath: basePath);
  if (!await paths.dmcDirectory.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return;
  }

  if (!await paths.activeTaskFile.exists()) {
    print('[DMC] No active task to end.');
    return;
  }

  final previousTask = (await paths.activeTaskFile.readAsString()).trim();
  await paths.activeTaskFile.delete();
  print('[DMC] Ended task: $previousTask');
}
