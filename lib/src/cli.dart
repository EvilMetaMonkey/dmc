import 'package:args/args.dart';
import 'diff.dart';
import 'init.dart';
import 'restore.dart';
import 'watcher.dart';

/// Parse command-line arguments and execute the appropriate command
void runCli(List<String> args) {
  final parser = ArgParser();
  parser.addCommand('init');
  parser.addCommand('watch');
  parser.addCommand('log');
  parser.addCommand('undo');
  parser.addCommand('diff');

  final results = parser.parse(args);
  final command = results.command;

  if (command == null) {
    print('Usage: dmc <command>');
    print('Commands:');
    print('  init           Initialize DMC in the current directory');
    print('  watch          Watch for file changes and backup automatically');
    print('  log            Show recent backup history');
    print('  undo <file>    Restore a file to its previous state');
    print('  diff <file>    Show a colored diff against the latest snapshot');
    return;
  }

  switch (command.name) {
    case 'init':
      initDmc();
      break;
    case 'watch':
      watchDmc();
      break;
    case 'log':
      showLogs();
      break;
    case 'undo':
      if (command.rest.isEmpty) {
        print('[DMC] Error: Please specify a file to restore.');
        print('Usage: dmc undo <filepath>');
      } else {
        undoFile(command.rest.first);
      }
      break;
    case 'diff':
      if (command.rest.isEmpty) {
        print('[DMC] Error: Please specify a file to diff.');
        print('Usage: dmc diff <filepath>');
      } else {
        showDiff(command.rest.first);
      }
      break;
    default:
      print('Unknown command: ${command.name}');
      print('Run "dmc" for usage information');
  }
}
