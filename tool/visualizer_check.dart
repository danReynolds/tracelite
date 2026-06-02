import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';

Future<void> main(List<String> args) async {
  final options = _parseOptions(args);
  if (options.help) {
    _usage(exitCode: 0);
  }

  final root = _checkoutRoot();
  final appDir = Directory(_joinPath(root.path, 'tool/visualizer_app'));
  final flutter = _flutterExecutable(
    options.flutterExecutable ?? Platform.environment['TRACELITE_FLUTTER'],
  );
  final testExcludeTag = options.skipNativeVisualizerTests
      ? 'native-trace'
      : options.skipHeavyVisualizerTests
          ? 'heavy'
          : null;

  if (!appDir.existsSync()) {
    stderr.writeln('missing visualizer app directory: ${appDir.path}');
    exit(66);
  }
  final pubspec = File(_joinPath(appDir.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    stderr.writeln('missing visualizer pubspec: ${pubspec.path}');
    exit(66);
  }

  final buildMode = options.packageMode == 'host' && options.buildMode == 'none'
      ? 'host'
      : options.buildMode;
  final device = _hostFlutterDevice();
  if (buildMode == 'host' && device == null) {
    stderr.writeln(
      'host visualizer builds are supported only on macOS, Linux, and Windows.',
    );
    exit(66);
  }
  if (device != null &&
      device != 'macos' &&
      (options.macosSignIdentity != null ||
          options.macosNotaryProfile != null)) {
    stderr.writeln(
      'macOS signing/notarization options are only valid on a macOS host.',
    );
    exit(64);
  }

  stdout
    ..writeln('# tracelite visualizer check')
    ..writeln('Root: ${root.path}')
    ..writeln('Flutter: $flutter')
    ..writeln('Build: $buildMode')
    ..writeln('Package: ${options.packageMode}')
    ..writeln();

  Map<String, Object?>? sourceOverride;
  if (options.requireCleanSource) {
    sourceOverride = await _sourceState(root.path);
    _requireCleanSource(sourceOverride);
  }

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
    arguments: [
      'test',
      if (testExcludeTag != null) '--exclude-tags=$testExcludeTag',
    ],
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

    if (options.packageMode == 'host') {
      final packaged = await _packageHostRelease(
        root: root,
        appDir: appDir,
        device: device,
        bundle: bundle,
        outDir: _resolveOutDir(root.path, options.outDir),
        sourceOverride: sourceOverride,
        macosSignIdentity: options.macosSignIdentity,
        macosNotaryProfile: options.macosNotaryProfile,
      );
      stdout
        ..writeln('Release archive: ${packaged.archive.path}')
        ..writeln('Release manifest: ${packaged.manifest.path}');
    }
  }

  stdout.writeln('Visualizer check passed.');
}

_Options _parseOptions(List<String> args) {
  var buildMode = 'none';
  var packageMode = 'none';
  String? flutterExecutable;
  String? outDir;
  String? macosSignIdentity;
  String? macosNotaryProfile;
  var requireCleanSource = false;
  var skipHeavyVisualizerTests = false;
  var skipNativeVisualizerTests = false;
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
    } else if (arg.startsWith('--package=')) {
      packageMode = arg.substring('--package='.length);
      if (packageMode != 'none' && packageMode != 'host') {
        stderr.writeln('--package must be `none` or `host`');
        _usage();
      }
    } else if (arg.startsWith('--out-dir=')) {
      outDir = arg.substring('--out-dir='.length);
      if (outDir.isEmpty) {
        stderr.writeln('missing value for --out-dir');
        _usage();
      }
    } else if (arg.startsWith('--macos-sign-identity=')) {
      macosSignIdentity = arg.substring('--macos-sign-identity='.length);
      if (macosSignIdentity.isEmpty) {
        stderr.writeln('missing value for --macos-sign-identity');
        _usage();
      }
    } else if (arg.startsWith('--macos-notary-profile=')) {
      macosNotaryProfile = arg.substring('--macos-notary-profile='.length);
      if (macosNotaryProfile.isEmpty) {
        stderr.writeln('missing value for --macos-notary-profile');
        _usage();
      }
    } else if (arg == '--require-clean-source') {
      requireCleanSource = true;
    } else if (arg.startsWith('--require-clean-source=')) {
      final value = arg.substring('--require-clean-source='.length);
      if (value == 'true') {
        requireCleanSource = true;
      } else if (value == 'false') {
        requireCleanSource = false;
      } else {
        stderr.writeln('--require-clean-source must be true or false');
        _usage();
      }
    } else if (arg == '--skip-heavy-visualizer-tests') {
      skipHeavyVisualizerTests = true;
    } else if (arg.startsWith('--skip-heavy-visualizer-tests=')) {
      final value = arg.substring('--skip-heavy-visualizer-tests='.length);
      if (value == 'true') {
        skipHeavyVisualizerTests = true;
      } else if (value == 'false') {
        skipHeavyVisualizerTests = false;
      } else {
        stderr.writeln('--skip-heavy-visualizer-tests must be true or false');
        _usage();
      }
    } else if (arg == '--skip-native-visualizer-tests') {
      skipNativeVisualizerTests = true;
    } else if (arg.startsWith('--skip-native-visualizer-tests=')) {
      final value = arg.substring('--skip-native-visualizer-tests='.length);
      if (value == 'true') {
        skipNativeVisualizerTests = true;
      } else if (value == 'false') {
        skipNativeVisualizerTests = false;
      } else {
        stderr.writeln('--skip-native-visualizer-tests must be true or false');
        _usage();
      }
    } else {
      stderr.writeln('unknown visualizer-check option: $arg');
      _usage();
    }
  }

  if (macosNotaryProfile != null && macosSignIdentity == null) {
    stderr.writeln('--macos-notary-profile requires --macos-sign-identity');
    _usage();
  }
  if ((macosSignIdentity != null || macosNotaryProfile != null) &&
      packageMode != 'host') {
    stderr.writeln(
      'macOS signing/notarization options require --package=host',
    );
    _usage();
  }

  return _Options(
    buildMode: buildMode,
    packageMode: packageMode,
    flutterExecutable: flutterExecutable,
    outDir: outDir,
    macosSignIdentity: macosSignIdentity,
    macosNotaryProfile: macosNotaryProfile,
    requireCleanSource: requireCleanSource,
    skipHeavyVisualizerTests: skipHeavyVisualizerTests,
    skipNativeVisualizerTests: skipNativeVisualizerTests,
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
      runInShell: _requiresShellExecutable(executable),
    );
    final code = await process.exitCode;
    if (code != 0) {
      stderr.writeln('$label failed with exit code $code');
      exit(code);
    }
  } on ProcessException catch (error) {
    stderr.writeln('could not run `$executable`: ${error.message}');
    if (_isFlutterExecutable(executable)) {
      stderr.writeln(
        'Install Flutter or pass --flutter=/path/to/flutter. '
        'TRACELITE_FLUTTER is also honored.',
      );
    } else {
      stderr.writeln('Install `$executable` and retry this release step.');
    }
    exit(66);
  }
  stdout.writeln();
}

bool _isFlutterExecutable(String executable) {
  final normalized = executable.replaceAll('\\', '/');
  final fileName = normalized.split('/').last.toLowerCase();
  return fileName == 'flutter' ||
      fileName == 'flutter.bat' ||
      fileName == 'flutter.exe';
}

String _flutterExecutable(String? configured) {
  if (configured == null || configured.isEmpty || configured == 'flutter') {
    return Platform.isWindows ? 'flutter.bat' : 'flutter';
  }
  return configured;
}

bool _requiresShellExecutable(String executable) {
  final normalized = executable.replaceAll('\\', '/').toLowerCase();
  return Platform.isWindows &&
      (normalized.endsWith('.bat') || normalized.endsWith('.cmd'));
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

Directory _hostReleaseRoot(String appDir, String device) {
  switch (device) {
    case 'macos':
      return Directory(
        _joinPath(
          appDir,
          'build/macos/Build/Products/Release',
        ),
      );
    case 'linux':
      return Directory(
        _joinPath(
          appDir,
          'build/linux/x64/release/bundle',
        ),
      );
    case 'windows':
      return Directory(
        _joinPath(
          appDir,
          'build/windows/x64/runner/Release',
        ),
      );
    default:
      throw StateError('unsupported visualizer device: $device');
  }
}

Future<_PackagedRelease> _packageHostRelease({
  required Directory root,
  required Directory appDir,
  required String device,
  required FileSystemEntity bundle,
  required Directory outDir,
  required Map<String, Object?>? sourceOverride,
  required String? macosSignIdentity,
  required String? macosNotaryProfile,
}) async {
  await outDir.create(recursive: true);
  final abi = _targetAbi();
  final source = sourceOverride ?? await _sourceState(root.path);

  var signingStatus = device == 'macos' ? 'unsigned' : 'external';
  var notarizationStatus =
      device == 'macos' ? 'not_requested' : 'not_applicable';
  var bundleForArchive = bundle;
  if (device == 'macos' && macosSignIdentity != null) {
    await _runStep(
      label: 'Sign macOS visualizer app',
      executable: 'codesign',
      arguments: [
        '--deep',
        '--force',
        '--options',
        'runtime',
        '--timestamp',
        '--sign',
        macosSignIdentity,
        bundle.path,
      ],
      workingDirectory: root.path,
    );
    await _runStep(
      label: 'Verify macOS signature',
      executable: 'codesign',
      arguments: [
        '--verify',
        '--deep',
        '--strict',
        '--verbose=2',
        bundle.path,
      ],
      workingDirectory: root.path,
    );
    signingStatus = 'signed';

    if (macosNotaryProfile != null) {
      final notarizationArchive = File(
        _joinPath(outDir.path, 'tracelite_visualizer-$abi-notary.zip'),
      );
      if (notarizationArchive.existsSync()) {
        await notarizationArchive.delete();
      }
      await _archiveHostRelease(
        device: device,
        appDir: appDir,
        archive: notarizationArchive,
      );
      await _runStep(
        label: 'Submit macOS visualizer app for notarization',
        executable: 'xcrun',
        arguments: [
          'notarytool',
          'submit',
          notarizationArchive.path,
          '--keychain-profile',
          macosNotaryProfile,
          '--wait',
        ],
        workingDirectory: root.path,
      );
      await _runStep(
        label: 'Staple macOS notarization ticket',
        executable: 'xcrun',
        arguments: ['stapler', 'staple', bundle.path],
        workingDirectory: root.path,
      );
      notarizationStatus = 'stapled';
      bundleForArchive = bundle;
    }
  }

  final archive = File(
    _joinPath(outDir.path, 'tracelite_visualizer-$abi.${_archiveExtension()}'),
  );
  if (archive.existsSync()) {
    await archive.delete();
  }
  await _archiveHostRelease(
    device: device,
    appDir: appDir,
    archive: archive,
  );
  if (!archive.existsSync()) {
    stderr.writeln('expected release archive was not created: ${archive.path}');
    exit(66);
  }

  final digest = await sha256.bind(archive.openRead()).first;
  final manifest = File(
    _joinPath(outDir.path, 'tracelite_visualizer-$abi.manifest.json'),
  );
  final packageRoot = _hostReleaseRoot(appDir.path, device);
  final manifestJson = <String, Object?>{
    'schema': 'tracelite.visualizer_release.v1',
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'platform': device,
    'abi': abi,
    'source': source,
    'bundle_path': bundleForArchive.absolute.path,
    'package_root': packageRoot.absolute.path,
    'archive_path': archive.absolute.path,
    'archive_bytes': await archive.length(),
    'archive_sha256': digest.toString(),
    'signing': {
      'status': signingStatus,
      if (device != 'macos')
        'note': 'host signing is managed outside tracelite on this platform',
      if (device == 'macos' && macosSignIdentity == null)
        'note': 'pass --macos-sign-identity to produce a signed macOS archive',
    },
    'notarization': {
      'status': notarizationStatus,
      if (device == 'macos' && macosNotaryProfile == null)
        'note':
            'pass --macos-notary-profile with --macos-sign-identity to staple a notarized app',
    },
  };
  await manifest.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(manifestJson)}\n',
  );
  return _PackagedRelease(archive: archive, manifest: manifest);
}

Future<void> _archiveHostRelease({
  required String device,
  required Directory appDir,
  required File archive,
}) async {
  final releaseRoot = _hostReleaseRoot(appDir.path, device);
  switch (device) {
    case 'macos':
      final app = _hostReleaseBundle(appDir.path, device);
      await _runStep(
        label: 'Package macOS visualizer archive',
        executable: 'ditto',
        arguments: [
          '-c',
          '-k',
          '--sequesterRsrc',
          '--keepParent',
          app.path,
          archive.absolute.path,
        ],
        workingDirectory: appDir.path,
      );
    case 'linux':
      await _runStep(
        label: 'Package Linux visualizer archive',
        executable: 'tar',
        arguments: ['-czf', archive.absolute.path, '-C', releaseRoot.path, '.'],
        workingDirectory: appDir.path,
      );
    case 'windows':
      await _runStep(
        label: 'Package Windows visualizer archive',
        executable: 'powershell',
        arguments: [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Compress-Archive -Path "${releaseRoot.path}\\*" '
              '-DestinationPath "${archive.absolute.path}" -Force',
        ],
        workingDirectory: appDir.path,
      );
    default:
      throw StateError('unsupported visualizer device: $device');
  }
}

String _archiveExtension() => Platform.isLinux ? 'tar.gz' : 'zip';

Directory _resolveOutDir(String root, String? configured) {
  if (configured == null || configured.isEmpty) {
    return Directory(_joinPath(root, 'build/visualizer-release'));
  }
  final directory = Directory(configured);
  return directory.isAbsolute
      ? directory
      : Directory(_joinPath(root, configured));
}

String _targetAbi() {
  final raw = Abi.current().toString().split('.').last;
  return raw.replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (match) {
    return '${match.group(1)}-${match.group(2)}';
  }).toLowerCase();
}

Future<Map<String, Object?>> _sourceState(String root) async {
  final revision = await _runCapture(
    'git',
    const ['rev-parse', 'HEAD'],
    workingDirectory: root,
  );
  final branch = await _runCapture(
    'git',
    const ['branch', '--show-current'],
    workingDirectory: root,
  );
  final status = await _runCapture(
    'git',
    const ['status', '--porcelain', '--untracked-files=all'],
    workingDirectory: root,
    trimOutput: false,
  );
  if (revision == null) {
    return {'kind': 'unknown'};
  }
  final dirtyFiles = status == null || status.isEmpty
      ? const <String>[]
      : status.split('\n').where((line) => line.trim().isNotEmpty).toList();
  return {
    'kind': 'git',
    'revision': revision,
    if (branch != null && branch.isNotEmpty) 'branch': branch,
    'dirty': dirtyFiles.isNotEmpty,
    'dirty_count': dirtyFiles.length,
    if (dirtyFiles.isNotEmpty) 'dirty_files': dirtyFiles.take(20).toList(),
    if (dirtyFiles.length > 20) 'dirty_files_truncated': true,
  };
}

Future<String?> _runCapture(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  bool trimOutput = true,
}) async {
  try {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    if (result.exitCode != 0) return null;
    final output = result.stdout.toString();
    return trimOutput ? output.trim() : output.trimRight();
  } on ProcessException {
    return null;
  }
}

void _requireCleanSource(Map<String, Object?> source) {
  if (source['kind'] != 'git') {
    stderr.writeln('cannot verify clean visualizer source state');
    exit(65);
  }
  if (source['dirty'] != true) return;
  stderr
    ..writeln('tracelite source has uncommitted changes')
    ..writeln('revision: ${source['revision']}')
    ..writeln('dirty files: ${source['dirty_count']}');
  final dirtyFiles = source['dirty_files'];
  if (dirtyFiles is List<Object?>) {
    for (final file in dirtyFiles.take(20)) {
      stderr.writeln('- $file');
    }
    if (source['dirty_files_truncated'] == true) {
      stderr.writeln('- ...');
    }
  }
  stderr.writeln(
    'Commit or stash changes, or omit --require-clean-source for local '
    'visualizer package checks.',
  );
  exit(65);
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
    '  dart tool/visualizer_check.dart '
    '[--flutter=/path/to/flutter] [--build=none|host] '
    '[--package=none|host] [--out-dir=build/visualizer-release] '
    '[--require-clean-source=true] '
    '[--skip-heavy-visualizer-tests=true] '
    '[--skip-native-visualizer-tests=true] '
    '[--macos-sign-identity=IDENTITY] [--macos-notary-profile=PROFILE]',
  );
  stderr.writeln(
    '  dart run bin/tracelite.dart visualizer-check '
    '[--flutter=/path/to/flutter] [--build=none|host] '
    '[--package=none|host] [--out-dir=build/visualizer-release] '
    '[--require-clean-source=true] '
    '[--skip-heavy-visualizer-tests=true] '
    '[--skip-native-visualizer-tests=true] '
    '[--macos-sign-identity=IDENTITY] [--macos-notary-profile=PROFILE]',
  );
  stderr.writeln();
  stderr.writeln('Runs Flutter pub get, analyze, and test for the desktop');
  stderr.writeln('visualizer. Use --build=host for release-bundle evidence.');
  stderr.writeln(
    'Use --package=host to create an audited host release archive and manifest.',
  );
  stderr.writeln(
    'Use --skip-heavy-visualizer-tests in hosted release packaging when '
    'full widget stress coverage is validated separately.',
  );
  stderr.writeln(
    'Use --skip-native-visualizer-tests only for UI-only checks on hosts '
    'without a built native runtime.',
  );
  stderr.writeln(
    'On macOS, signing and notarization are optional credential-backed steps.',
  );
  stderr.writeln(
    'In a source checkout, the direct tool script is the visualizer-only path '
    'and avoids rebuilding root peer native assets.',
  );
  exit(exitCode);
}

final class _Options {
  const _Options({
    required this.buildMode,
    required this.packageMode,
    required this.flutterExecutable,
    required this.outDir,
    required this.macosSignIdentity,
    required this.macosNotaryProfile,
    required this.requireCleanSource,
    required this.skipHeavyVisualizerTests,
    required this.skipNativeVisualizerTests,
    required this.help,
  });

  final String buildMode;
  final String packageMode;
  final String? flutterExecutable;
  final String? outDir;
  final String? macosSignIdentity;
  final String? macosNotaryProfile;
  final bool requireCleanSource;
  final bool skipHeavyVisualizerTests;
  final bool skipNativeVisualizerTests;
  final bool help;
}

final class _PackagedRelease {
  const _PackagedRelease({
    required this.archive,
    required this.manifest,
  });

  final File archive;
  final File manifest;
}
