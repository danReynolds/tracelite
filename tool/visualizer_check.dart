import 'dart:io';

Future<void> main(List<String> args) async {
  final options = _parseOptions(args);
  if (options.help) {
    _usage(exitCode: 0);
  }

  final root = _checkoutRoot();
  final appDir = Directory(_joinPath(root.path, 'tool/visualizer_app'));
  final flutter = options.flutterExecutable ??
      Platform.environment['TRACELITE_FLUTTER'] ??
      'flutter';

  if (!appDir.existsSync()) {
    stderr.writeln('missing visualizer app directory: ${appDir.path}');
    exit(66);
  }
  final pubspec = File(_joinPath(appDir.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    stderr.writeln('missing visualizer pubspec: ${pubspec.path}');
    exit(66);
  }

  final buildMode = options.buildMode;
  final device = _hostFlutterDevice();
  if (buildMode == 'host' && device == null) {
    stderr.writeln(
      'host visualizer builds are supported only on macOS, Linux, and Windows.',
    );
    exit(66);
  }

  stdout
    ..writeln('# tracelite visualizer check')
    ..writeln('Root: ${root.path}')
    ..writeln('Flutter: $flutter')
    ..writeln('Build: $buildMode')
    ..writeln();

  await _runStep(
    label: 'Flutter version',
    executable: flutter,
    arguments: const ['--version'],
    workingDirectory: appDir.path,
  );
  await _runStep(
    label: 'Resolve visualizer dependencies',
    executable: flutter,
    arguments: const ['pub', 'get'],
    workingDirectory: appDir.path,
  );
  await _runStep(
    label: 'Analyze visualizer',
    executable: flutter,
    arguments: const ['analyze'],
    workingDirectory: appDir.path,
  );
  await _runStep(
    label: 'Test visualizer',
    executable: flutter,
    arguments: const ['test'],
    workingDirectory: appDir.path,
  );

  if (buildMode == 'host') {
    await _runStep(
      label: 'Build host release visualizer',
      executable: flutter,
      arguments: ['build', device!, '--release'],
      workingDirectory: appDir.path,
    );
    final bundle = _hostReleaseBundle(appDir.path, device);
    if (!bundle.existsSync()) {
      stderr.writeln('expected release bundle was not created: ${bundle.path}');
      exit(66);
    }
    stdout.writeln('Release bundle: ${bundle.path}');
  }

  stdout.writeln('Visualizer check passed.');
}

_Options _parseOptions(List<String> args) {
  var buildMode = 'none';
  String? flutterExecutable;
  var help = false;

  for (final arg in args) {
    if (arg == '--help' || arg == '-h') {
      help = true;
    } else if (arg.startsWith('--flutter=')) {
      flutterExecutable = arg.substring('--flutter='.length);
      if (flutterExecutable.isEmpty) {
        stderr.writeln('missing value for --flutter');
        _usage();
      }
    } else if (arg.startsWith('--build=')) {
      buildMode = arg.substring('--build='.length);
      if (buildMode != 'none' && buildMode != 'host') {
        stderr.writeln('--build must be `none` or `host`');
        _usage();
      }
    } else {
      stderr.writeln('unknown visualizer-check option: $arg');
      _usage();
    }
  }

  return _Options(
    buildMode: buildMode,
    flutterExecutable: flutterExecutable,
    help: help,
  );
}

Future<void> _runStep({
  required String label,
  required String executable,
  required List<String> arguments,
  required String workingDirectory,
}) async {
  stdout
    ..writeln('==> $label')
    ..writeln('    $executable ${arguments.join(' ')}');
  try {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await process.exitCode;
    if (code != 0) {
      stderr.writeln('$label failed with exit code $code');
      exit(code);
    }
  } on ProcessException catch (error) {
    stderr.writeln('could not run `$executable`: ${error.message}');
    stderr.writeln(
      'Install Flutter or pass --flutter=/path/to/flutter. '
      'TRACELITE_FLUTTER is also honored.',
    );
    exit(66);
  }
  stdout.writeln();
}

Directory _checkoutRoot() {
  if (Platform.script.scheme == 'file') {
    return File.fromUri(Platform.script).parent.parent.absolute;
  }
  return Directory.current.absolute;
}

String? _hostFlutterDevice() {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  if (Platform.isWindows) return 'windows';
  return null;
}

FileSystemEntity _hostReleaseBundle(String appDir, String device) {
  switch (device) {
    case 'macos':
      return Directory(
        _joinPath(
          appDir,
          'build/macos/Build/Products/Release/tracelite_visualizer.app',
        ),
      );
    case 'linux':
      return File(_joinPath(
        appDir,
        'build/linux/x64/release/bundle/tracelite_visualizer',
      ));
    case 'windows':
      return File(_joinPath(
        appDir,
        'build/windows/x64/runner/Release/tracelite_visualizer.exe',
      ));
    default:
      throw StateError('unsupported visualizer device: $device');
  }
}

String _joinPath(String first, String second) {
  if (first.isEmpty || first == '.') return second;
  if (second.isEmpty) return first;
  final separator = Platform.pathSeparator;
  if (first.endsWith(separator)) return '$first$second';
  return '$first$separator$second';
}

Never _usage({int exitCode = 64}) {
  stderr.writeln('usage:');
  stderr.writeln(
    '  dart run bin/tracelite.dart visualizer-check '
    '[--flutter=/path/to/flutter] [--build=none|host]',
  );
  stderr.writeln();
  stderr.writeln('Runs Flutter pub get, analyze, and test for the desktop');
  stderr.writeln('visualizer. Use --build=host for release-bundle evidence.');
  exit(exitCode);
}

final class _Options {
  const _Options({
    required this.buildMode,
    required this.flutterExecutable,
    required this.help,
  });

  final String buildMode;
  final String? flutterExecutable;
  final bool help;
}
