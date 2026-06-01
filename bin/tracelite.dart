import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final root = _checkoutRoot();
  final devCli = File(_join(root, 'tool/tracelite_dev.dart'));
  if (!devCli.existsSync() || !_hasDevPeerDependencies(root)) {
    _printUnavailable(args);
    exitCode =
        args.isEmpty || args.first == '--help' || args.first == '-h' ? 0 : 64;
    return;
  }

  final process = await Process.start(
    Platform.resolvedExecutable,
    [devCli.path, ...args],
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await process.exitCode;
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

void _printUnavailable(List<String> args) {
  stdout.writeln('tracelite benchmark CLI is source-checkout only for now.');
  stdout.writeln('');
  stdout.writeln('From a tracelite checkout, run:');
  stdout.writeln('  dart pub get');
  stdout.writeln('  dart run bin/tracelite.dart <command>');
  stdout.writeln('');
  stdout.writeln(
    'The published package is the core recorder/runtime library. '
    'The peer benchmark CLI uses dev dependencies until the companion CLI '
    'package split lands.',
  );
}

String _join(String parent, String child) {
  return parent.endsWith(Platform.pathSeparator)
      ? '$parent$child'
      : '$parent${Platform.pathSeparator}$child';
}
