import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('published dependencies stay core-only', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    final dependencies = (pubspec['dependencies'] as YamlMap)
        .keys
        .cast<Object?>()
        .map((key) => key.toString())
        .toSet();

    expect(dependencies, containsAll(<String>['ffi', 'yaml']));
    expect(
      dependencies,
      isNot(contains(anyOf('drift', 'sqlite3', 'sqlite_async', 'resqlite'))),
      reason:
          'Peer adapters belong to the source-checkout benchmark CLI until the '
          'companion CLI package split lands. The recorder package must stay '
          'safe for peer libraries to depend on.',
    );
  });

  test('published launcher keeps core commands available', () async {
    final binSource = File('bin/tracelite.dart').readAsStringSync();
    final coreCliSource = File('lib/src/core_cli.dart').readAsStringSync();
    for (final source in [binSource, coreCliSource]) {
      expect(source, isNot(contains("package:drift/")));
      expect(source, isNot(contains("package:sqlite3/")));
      expect(source, isNot(contains("package:sqlite_async/")));
      expect(source, isNot(contains("package:resqlite/")));
    }
    expect(
      binSource.split('\n').length,
      lessThan(150),
      reason: 'The published launcher should stay a thin boundary wrapper. '
          'Core artifact commands live in lib/src/core_cli.dart.',
    );

    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-core-cli-boundary-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final regionPath = '${tempDir.path}/core.tlt-region';
    final create = await _runCoreCli([
      'create-region',
      '--out=$regionPath',
      '--ring-data-words=1024',
    ]);
    expect(
      create.exitCode,
      0,
      reason: 'create-region failed.\nstdout:\n${create.stdout}\n'
          'stderr:\n${create.stderr}',
    );
    expect(File(regionPath).existsSync(), isTrue);

    final report = await _runCoreCli(['report', regionPath]);
    expect(
      report.exitCode,
      0,
      reason: 'report failed.\nstdout:\n${report.stdout}\n'
          'stderr:\n${report.stderr}',
    );
    expect(report.stdout.toString(), contains('# tracelite report'));
  });

  test('peer commands stay out of the published core launcher', () async {
    final result = await _runCoreCli([
      'compare',
      '--scenario=narrow-batch-insert',
      '--interfaces=sqlite3',
      '--rows=1',
    ]);
    expect(result.exitCode, 64);
    expect(
      result.stderr.toString(),
      contains('requires a tracelite source checkout'),
    );
  });
}

Future<ProcessResult> _runCoreCli(List<String> args) {
  return Process.run(
    Platform.resolvedExecutable,
    ['bin/tracelite.dart', ...args],
    workingDirectory: Directory.current.path,
    environment: {'TRACELITE_FORCE_CORE_CLI': 'true'},
  );
}
