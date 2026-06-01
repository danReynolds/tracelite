import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('doctor reports local checkout status and writes JSON', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-doctor-command-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final jsonPath = '${tempDir.path}/doctor.json';
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'doctor',
        '--json=$jsonPath',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'doctor failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    final stdoutText = result.stdout.toString();
    expect(stdoutText, contains('# tracelite doctor'));
    expect(stdoutText, contains('Status:'));
    expect(stdoutText, contains('native/tracelite_runtime.c'));

    final artifact =
        jsonDecode(File(jsonPath).readAsStringSync()) as Map<String, Object?>;
    expect(artifact['schema'], 'tracelite.doctor.v1');
    expect(artifact['status'], isIn(['ready', 'warning']));
    expect(artifact['root'], Directory.current.absolute.path);
    final checks = artifact['checks']! as List<Object?>;
    expect(
      checks,
      contains(
        containsPair('detail', 'native/tracelite_runtime.c'),
      ),
    );
  });

  test('doctor fails for a non-tracelite root', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-doctor-invalid-root-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'doctor',
        '--root=${tempDir.path}',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 65);
    expect(result.stdout.toString(), contains('Status: `failed`'));
    expect(result.stdout.toString(), contains('missing pubspec.yaml'));
  });

  test('doctor strict mode fails on warnings', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-doctor-strict-warning-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    _writeFixtureCheckout(tempDir);

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'doctor',
        '--root=${tempDir.path}',
        '--strict=true',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 65);
    expect(result.stdout.toString(), contains('Status: `failed`'));
    expect(
      result.stdout.toString(),
      contains('.dart_tool/package_config.json'),
    );
    expect(
      result.stderr.toString(),
      contains('strict mode treats doctor warnings as failures'),
    );
  });
}

void _writeFixtureCheckout(Directory root) {
  for (final directory in const [
    'bin',
    'native',
    'tool',
    'tool/visualizer_app',
    'lib/src',
    'doc',
  ]) {
    Directory('${root.path}/$directory').createSync(recursive: true);
  }

  for (final file in const [
    'pubspec.yaml',
    'bin/tracelite.dart',
    'native/tracelite_runtime.c',
    'native/tracelite_runtime.h',
    'native/shim_sqlite3.c',
    'tool/spans.yaml',
    'lib/src/builtin_spans.g.dart',
    'native/builtin_spans.g.h',
    'doc/format-spec.appendix.md',
    'doc/span-registry.generated.md',
  ]) {
    File('${root.path}/$file').writeAsStringSync('\n');
  }
}
