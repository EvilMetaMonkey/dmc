import 'package:args/args.dart';
import 'daemon.dart';
import 'doctor.dart';
import 'diff.dart';
import 'gc.dart';
import 'init.dart';
import 'log.dart';
import 'marks.dart';
import 'restore.dart';
import 'snap.dart';
import 'status.dart';
import 'task.dart';
import 'ui.dart';
import 'version.dart';
import 'watcher.dart';

ArgParser _addPreviewFlags(ArgParser command) {
  command.addFlag(
    'dry-run',
    negatable: false,
    help: 'Preview the restore without modifying the file',
  );
  command.addFlag('preview', negatable: false, help: 'Alias for --dry-run');
  return command;
}

ArgParser _addRestoreCommand(ArgParser parser, String name) {
  final command = _addPreviewFlags(parser.addCommand(name));
  command.addOption('id', help: 'Specific snapshot ID to target');
  command.addOption('burst', help: 'Specific burst ID to target');
  command.addOption('task', help: 'Specific task name to target');
  command.addOption('mark', help: 'Specific mark name to target');
  return command;
}

Future<int> _runRedoCommand(ArgResults command) async {
  final dryRun =
      (command['dry-run'] as bool? ?? false) ||
      (command['preview'] as bool? ?? false);
  final parsedBurstId = _parseBurstId(command);
  if (!parsedBurstId.isValid) return 1;
  final taskName = _parseStringOption(command, 'task');
  final markName = _parseStringOption(command, 'mark');

  final selectedTargets = [
    if (parsedBurstId.id != null) 'burst',
    if (taskName != null) 'task',
    if (markName != null) 'mark',
  ];
  if (selectedTargets.length > 1) {
    print('[DMC] Error: Use only one of --burst, --task, or --mark.');
    return 1;
  }

  if (selectedTargets.isNotEmpty) {
    if (command.rest.isNotEmpty) {
      print(
        '[DMC] Error: Do not specify a file when using --burst, --task, or --mark.',
      );
      print(
        'Usage: dmc redo [--dry-run|--preview] [--burst <burst-id>|--task <name>|--mark <name>] <filepath>',
      );
      return 1;
    }

    final result = await redoFile(
      '',
      burstId: parsedBurstId.id,
      taskName: taskName,
      markName: markName,
      dryRun: dryRun,
    );
    return result.hadError ? 1 : 0;
  }

  if (command.rest.isEmpty) {
    print('[DMC] Error: Please specify a file to redo.');
    print(
      'Usage: dmc redo [--dry-run|--preview] [--burst <burst-id>|--task <name>|--mark <name>] <filepath>',
    );
    return 1;
  }

  final result = await redoFile(command.rest.first, dryRun: dryRun);
  return result.hadError ? 1 : 0;
}

Future<int> _runLogCommand(ArgResults command) async {
  final bursts = command['bursts'] as bool? ?? false;
  final tasks = command['tasks'] as bool? ?? false;
  if (bursts && tasks) {
    print('[DMC] Error: Use either --bursts or --tasks, not both.');
    return 1;
  }

  await showLogs(bursts: bursts, tasks: tasks);
  return 0;
}

Future<int> _runStatusCommand() async {
  await showStatus();
  return 0;
}

Future<int> _runStartCommand() {
  return startDaemon();
}

Future<int> _runStopCommand() {
  return stopDaemon();
}

Future<int> _runDoctorCommand() async {
  final hadIssues = await runDoctor();
  return hadIssues ? 1 : 0;
}

Future<int> _runTaskCommand(ArgResults command) async {
  final subcommand = command.command;
  if (subcommand == null) {
    print('Usage: dmc task <start|end>');
    return 1;
  }

  switch (subcommand.name) {
    case 'start':
      if (subcommand.rest.isEmpty) {
        print('[DMC] Error: Please specify a task name.');
        return 1;
      }
      await startTask(subcommand.rest.join(' '));
      return 0;
    case 'end':
      await endTask();
      return 0;
    default:
      print('Usage: dmc task <start|end>');
      return 1;
  }
}

Future<int> _runMarkCommand(ArgResults command) async {
  if (command.rest.isEmpty) {
    print('[DMC] Error: Please specify a mark name.');
    return 1;
  }

  await createMark(command.rest.join(' '));
  return 0;
}

Future<int> _runMarksCommand() async {
  await showMarks();
  return 0;
}

Future<int> _runGcCommand(ArgResults command) {
  return runGc(dryRun: command['dry-run'] as bool? ?? false);
}

Future<int> _runSnapCommand() async {
  await takeManualSnapshot();
  return 0;
}

Future<int> _runUiCommand() {
  return runInteractiveUi();
}

({int? id, bool isValid}) _parseSnapshotId(ArgResults command) {
  return _parseIntegerOption(command, 'id');
}

({int? id, bool isValid}) _parseBurstId(ArgResults command) {
  return _parseIntegerOption(command, 'burst');
}

String? _parseStringOption(ArgResults command, String optionName) {
  final rawValue = command[optionName] as String?;
  if (rawValue == null) {
    return null;
  }

  final trimmedValue = rawValue.trim();
  return trimmedValue.isEmpty ? null : trimmedValue;
}

({int? id, bool isValid}) _parseIntegerOption(
  ArgResults command,
  String optionName,
) {
  final rawId = command[optionName] as String?;
  if (rawId == null) {
    return (id: null, isValid: true);
  }

  final parsedId = int.tryParse(rawId);
  if (parsedId == null) {
    print('[DMC] Error: --$optionName must be an integer.');
    return (id: null, isValid: false);
  }

  return (id: parsedId, isValid: true);
}

Future<int> _runRestoreCommand(ArgResults command) async {
  final parsedId = _parseSnapshotId(command);
  if (!parsedId.isValid) return 1;
  final parsedBurstId = _parseBurstId(command);
  if (!parsedBurstId.isValid) return 1;
  final taskName = _parseStringOption(command, 'task');
  final markName = _parseStringOption(command, 'mark');

  final selectedTargets = [
    if (parsedId.id != null) 'id',
    if (parsedBurstId.id != null) 'burst',
    if (taskName != null) 'task',
    if (markName != null) 'mark',
  ];
  if (selectedTargets.length > 1) {
    print('[DMC] Error: Use only one of --id, --burst, --task, or --mark.');
    return 1;
  }

  final dryRun =
      (command['dry-run'] as bool? ?? false) ||
      (command['preview'] as bool? ?? false);

  if (parsedBurstId.id != null || taskName != null || markName != null) {
    if (command.rest.isNotEmpty) {
      print(
        '[DMC] Error: Do not specify a file when using --burst, --task, or --mark.',
      );
      print(
        'Usage: dmc ${command.name} [--dry-run|--preview] [--burst <burst-id>|--task <name>|--mark <name>] <filepath>',
      );
      return 1;
    }

    final result = await restoreFile(
      '',
      burstId: parsedBurstId.id,
      taskName: taskName,
      markName: markName,
      dryRun: dryRun,
      commandName: command.name!,
    );
    return result.hadError ? 1 : 0;
  }

  if (command.rest.isEmpty) {
    print('[DMC] Error: Please specify a file to restore.');
    print(
      'Usage: dmc ${command.name} [--id <snapshot-id>] [--dry-run|--preview] [--burst <burst-id>|--task <name>|--mark <name>] <filepath>',
    );
    return 1;
  }

  final result = await restoreFile(
    command.rest.first,
    id: parsedId.id,
    dryRun: dryRun,
    commandName: command.name!,
  );
  return result.hadError ? 1 : 0;
}

Future<int> _runDiffCommand(ArgResults command) async {
  final parsedId = _parseSnapshotId(command);
  if (!parsedId.isValid) return 1;
  final parsedBurstId = _parseBurstId(command);
  if (!parsedBurstId.isValid) return 1;

  if (parsedId.id != null && parsedBurstId.id != null) {
    print('[DMC] Error: Use either --id or --burst, not both.');
    return 1;
  }

  if (parsedBurstId.id != null) {
    if (command.rest.isNotEmpty) {
      print('[DMC] Error: Do not specify a file when using --burst.');
      print(
        'Usage: dmc diff [--id <snapshot-id> | --burst <burst-id>] <filepath>',
      );
      return 1;
    }

    final hadError = await showDiff('', burstId: parsedBurstId.id);
    return hadError ? 1 : 0;
  }

  if (command.rest.isEmpty) {
    print('[DMC] Error: Please specify a file to diff.');
    print(
      'Usage: dmc diff [--id <snapshot-id> | --burst <burst-id>] <filepath>',
    );
    return 1;
  }

  final hadError = await showDiff(command.rest.first, id: parsedId.id);
  return hadError ? 1 : 0;
}

/// Parse command-line arguments and execute the appropriate command
Future<int> runCli(List<String> args) async {
  final parser = ArgParser();
  parser.addFlag(
    'version',
    negatable: false,
    help: 'Print the current version',
  );
  parser.addCommand('init');
  parser.addCommand('start');
  parser.addCommand('stop');
  parser.addCommand('watch');
  parser.addCommand('status');
  parser.addCommand('doctor');
  parser.addCommand('ui');
  parser.addCommand('snap');
  final gcCommand = parser.addCommand('gc');
  gcCommand.addFlag('dry-run', negatable: false, help: 'Preview cleanup only');
  parser.addCommand('mark');
  parser.addCommand('marks');
  final taskCommand = parser.addCommand('task');
  taskCommand.addCommand('start');
  taskCommand.addCommand('end');
  final logCommand = parser.addCommand('log');
  logCommand.addFlag(
    'bursts',
    negatable: false,
    help: 'Group recent history by burst',
  );
  logCommand.addFlag(
    'tasks',
    negatable: false,
    help: 'Group recent history by task',
  );
  _addRestoreCommand(parser, 'undo');
  _addRestoreCommand(parser, 'restore');
  final redoCommand = _addPreviewFlags(parser.addCommand('redo'));
  redoCommand.addOption('burst', help: 'Specific burst ID to target');
  redoCommand.addOption('task', help: 'Specific task name to target');
  redoCommand.addOption('mark', help: 'Specific mark name to target');
  final diffCommand = parser.addCommand('diff');
  diffCommand.addOption('id', help: 'Specific snapshot ID to target');
  diffCommand.addOption('burst', help: 'Specific burst ID to target');

  final results = parser.parse(args);

  if (results['version'] as bool) {
    print('dmc version $dmcVersion');
    return 0;
  }

  final command = results.command;

  if (command == null) {
    print('Usage: dmc <command>');
    print('Commands:');
    print('  init                 Initialize DMC in the current directory');
    print('  start                Start the watcher as a background daemon');
    print('  stop                 Stop the background watcher daemon');
    print('  watch                Watch for file changes in the foreground');
    print('  status               Show vault health and active config');
    print('  doctor               Check DB access and snapshot consistency');
    print('  ui                   Launch the interactive terminal dashboard');
    print('  snap                 Capture a manual workspace snapshot');
    print(
      '  gc [--dry-run]       Prune expired snapshots using retention config',
    );
    print('  task start <name>    Start assigning snapshots to a task');
    print('  task end             Stop assigning snapshots to a task');
    print('  mark <name>          Save a mark for the latest burst');
    print('  marks                List saved marks');
    print('  log [--bursts|--tasks]       Show recent backup history');
    print(
      '  undo [--id <id>|--burst <id>|--task <name>|--mark <name>] [--dry-run]     Restore a file to a previous state',
    );
    print(
      '  restore [--id <id>|--burst <id>|--task <name>|--mark <name>] [--dry-run]  Alias for undo',
    );
    print(
      '  redo [--burst <id>|--task <name>|--mark <name>] [--dry-run]  Restore the last undone state',
    );
    print(
      '  diff [--id <id>|--burst <id>]    Show a colored diff against a snapshot',
    );
    return 0;
  }

  switch (command.name) {
    case 'init':
      await initDmc();
      return 0;
    case 'start':
      return _runStartCommand();
    case 'stop':
      return _runStopCommand();
    case 'watch':
      await watchDmc();
      return 0;
    case 'snap':
      return _runSnapCommand();
    case 'gc':
      return _runGcCommand(command);
    case 'status':
      return _runStatusCommand();
    case 'doctor':
      return _runDoctorCommand();
    case 'ui':
      return _runUiCommand();
    case 'task':
      return _runTaskCommand(command);
    case 'mark':
      return _runMarkCommand(command);
    case 'marks':
      return _runMarksCommand();
    case 'log':
      return _runLogCommand(command);
    case 'undo':
    case 'restore':
      return _runRestoreCommand(command);
    case 'redo':
      return _runRedoCommand(command);
    case 'diff':
      return _runDiffCommand(command);
    default:
      print('Unknown command: ${command.name}');
      print('Run "dmc" for usage information');
      return 1;
  }
}
