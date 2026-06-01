import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options == null) {
    _printUsage();
    exitCode = 64;
    return;
  }

  final configFile = File(options.packageConfig);
  if (!configFile.existsSync()) {
    _fail('missing package config: ${configFile.path}');
    return;
  }

  final decoded = jsonDecode(await configFile.readAsString());
  if (decoded is! Map) {
    _fail('invalid package config: expected JSON object');
    return;
  }
  final config = decoded.cast<String, Object?>();
  final packages = config['packages'];
  if (packages is! List) {
    _fail('invalid package config: missing packages list');
    return;
  }

  Map<String, Object?>? resqlite;
  for (final package in packages) {
    if (package is Map && package['name'] == 'resqlite') {
      resqlite = package.cast<String, Object?>();
      break;
    }
  }
  if (resqlite == null) {
    _fail('resqlite is missing from ${configFile.path}');
    return;
  }

  final rootUri = resqlite['rootUri'];
  if (rootUri is! String || rootUri.isEmpty) {
    _fail('resqlite rootUri is missing from ${configFile.path}');
    return;
  }

  final root = await _resolvedRoot(rootUri, configFile);
  final hook = File(_join(root, 'hook/build.dart'));
  if (!hook.existsSync()) {
    _fail('resqlite source $root has no hook/build.dart');
    return;
  }
  final hookSource = await hook.readAsString();
  if (!hookSource.contains('trace_sqlite')) {
    _fail('resqlite source $root does not expose trace_sqlite');
    return;
  }

  final revision = await _gitHead(root);
  if (revision == null) return;
  if (revision != options.expectedRevision) {
    _fail(
        'resqlite resolved to $revision, expected ${options.expectedRevision}');
    return;
  }

  stdout.writeln('resqlite source: $root @ $revision');
}

Future<String> _resolvedRoot(String rootUri, File packageConfig) async {
  final uri = Uri.parse(rootUri);
  final resolved = uri.hasScheme
      ? uri
      : packageConfig.parent.uri.resolveUri(Uri.parse(rootUri));
  if (resolved.scheme != 'file') {
    _fail('resqlite rootUri must resolve to a file URI: $rootUri');
    return rootUri;
  }

  final directory = Directory.fromUri(resolved);
  if (!directory.existsSync()) {
    _fail('resqlite source directory does not exist: ${directory.path}');
    return directory.absolute.path;
  }
  return directory.resolveSymbolicLinks();
}

Future<String?> _gitHead(String root) async {
  final result = await Process.run(
    'git',
    const ['rev-parse', 'HEAD'],
    workingDirectory: root,
  );
  if (result.exitCode != 0) {
    _fail('failed to read resqlite git revision: ${result.stderr}');
    return null;
  }
  return (result.stdout as String).trim();
}

void _printUsage() {
  stderr.writeln(
    'Usage: dart tool/verify_resqlite_source.dart '
    '--revision=<expected-sha> '
    '[--package-config=.dart_tool/package_config.json]',
  );
}

void _fail(String message) {
  stderr.writeln(message);
  exitCode = 65;
}

String _join(String parent, String child) {
  if (parent.endsWith(Platform.pathSeparator)) {
    return '$parent$child';
  }
  return '$parent${Platform.pathSeparator}$child';
}

final class _Options {
  const _Options({
    required this.expectedRevision,
    required this.packageConfig,
  });

  final String expectedRevision;
  final String packageConfig;

  static _Options? parse(List<String> args) {
    String? revision;
    var packageConfig = '.dart_tool/package_config.json';

    for (final arg in args) {
      if (arg == '--help' || arg == '-h') {
        return null;
      }
      if (arg.startsWith('--revision=')) {
        revision = arg.substring('--revision='.length);
      } else if (arg.startsWith('--package-config=')) {
        packageConfig = arg.substring('--package-config='.length);
      } else {
        return null;
      }
    }

    if (revision == null || revision.isEmpty) {
      return null;
    }
    return _Options(
      expectedRevision: revision,
      packageConfig: packageConfig,
    );
  }
}
