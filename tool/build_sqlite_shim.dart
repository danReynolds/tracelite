import 'dart:io';

import 'package:tracelite/src/native_artifacts.dart' as native_artifacts;

Future<void> main(List<String> args) async {
  final options = _parseOptions(args);
  if (options.containsKey('help')) {
    _usage(exitCode: 0);
  }

  final sqliteAmalgamation = options['sqlite-amalgamation'];
  if (sqliteAmalgamation != null && !File(sqliteAmalgamation).existsSync()) {
    stderr.writeln('missing SQLite amalgamation: $sqliteAmalgamation');
    exitCode = 66;
    return;
  }

  final plan = native_artifacts.sqliteShimBuildPlan(
    embeddedSqliteSourcePath: sqliteAmalgamation,
  );
  if (plan == null) {
    stderr.writeln(
      native_artifacts.sqliteShimUnsupportedReason() ??
          'SQLite shim build is not implemented for '
              '${Platform.operatingSystem}.',
    );
    if (Platform.isWindows) {
      stderr.writeln(
        'Pass --sqlite-amalgamation=/path/to/sqlite3.c to build the '
        'embedded sqlite_traced.dll variant.',
      );
    }
    exitCode = 66;
    return;
  }

  Directory('build').createSync(recursive: true);
  for (final step in plan.steps) {
    stdout.writeln('+ ${step.shellCommand}');
    final result = await Process.run(step.executable, step.arguments);
    if (result.stdout.toString().isNotEmpty) stdout.write(result.stdout);
    if (result.stderr.toString().isNotEmpty) stderr.write(result.stderr);
    if (result.exitCode != 0) {
      exitCode = result.exitCode;
      return;
    }
  }
}

Map<String, String> _parseOptions(List<String> args) {
  final options = <String, String>{};
  for (final arg in args) {
    if (arg == '--help' || arg == '-h') {
      options['help'] = 'true';
      continue;
    }
    if (arg.startsWith('--sqlite-amalgamation=')) {
      options['sqlite-amalgamation'] =
          arg.substring('--sqlite-amalgamation='.length);
      continue;
    }
    stderr.writeln('unknown option: $arg');
    _usage();
  }
  return options;
}

Never _usage({int exitCode = 64}) {
  final output = exitCode == 0 ? stdout : stderr;
  output.writeln(
    'usage: dart --packages=.dart_tool/package_config.json '
    'tool/build_sqlite_shim.dart '
    '[--sqlite-amalgamation=/path/to/sqlite3.c]',
  );
  exit(exitCode);
}
