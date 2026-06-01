import 'dart:convert';
import 'dart:io';

import 'package:tracelite/src/core_cli.dart';

const _peerCommands = {'compare', 'suite', 'suite-history', '_run-peer'};

Future<void> main(List<String> args) async {
  final root = _checkoutRoot();
  final forceCore = Platform.environment['TRACELITE_FORCE_CORE_CLI'] == 'true';
  if (!forceCore && await _canRunDevelopmentCli(root)) {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [_join(root, 'tool/tracelite_dev.dart'), ...args],
      mode: ProcessStartMode.inheritStdio,
    );
    exitCode = await process.exitCode;
    return;
  }

  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    printTraceliteCoreUsage(exitCode: args.isEmpty ? 64 : 0);
  }

  final command = args.first;
  if (_peerCommands.contains(command)) {
    _printPeerUnavailable(command);
    exitCode = 64;
    return;
  }
  if (isTraceliteCoreCommand(command)) {
    runTraceliteCoreCli(args);
    return;
  }

  stderr.writeln('unknown or source-checkout-only command: $command');
  printTraceliteCoreUsage();
}

Future<bool> _canRunDevelopmentCli(String root) async {
  final devCli = File(_join(root, 'tool/tracelite_dev.dart'));
  return devCli.existsSync() && _hasDevPeerDependencies(root);
}

String _checkoutRoot() {
  if (Platform.script.scheme == 'file') {
    return File.fromUri(Platform.script).parent.parent.path;
  }
  return Directory.current.path;
}

bool _hasDevPeerDependencies(String root) {
  final packageConfig = File(_join(root, '.dart_tool/package_config.json'));
  if (!packageConfig.existsSync()) return false;
  final decoded = jsonDecode(packageConfig.readAsStringSync());
  if (decoded is! Map<String, Object?>) return false;
  final packages = decoded['packages'];
  if (packages is! List<Object?>) return false;
  final names = <String>{
    for (final package in packages)
      if (package is Map<String, Object?> && package['name'] is String)
        package['name']! as String,
  };
  return const {
    'drift',
    'resqlite',
    'sqlite3',
    'sqlite_async',
  }.every(names.contains);
}

void _printPeerUnavailable(String command) {
  stderr.writeln('`tracelite $command` requires a tracelite source checkout.');
  stderr.writeln('');
  stderr.writeln('From a checkout, run `dart pub get` and retry the command.');
  stderr.writeln(
    'The published package keeps the recorder/runtime dependency graph '
    'core-only until the peer benchmark CLI becomes a companion package.',
  );
}

String _join(String parent, String child) {
  return parent.endsWith(Platform.pathSeparator)
      ? '$parent$child'
      : '$parent${Platform.pathSeparator}$child';
}
