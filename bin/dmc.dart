import 'dart:io';

import 'package:dmc/dmc.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runCli(arguments);
}
