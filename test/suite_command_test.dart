import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('suite writes a CI manifest and per-scenario artifacts', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-suite-command-test-',
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
        'suite',
        '--profile=ci',
        '--interfaces=sqlite3',
        '--out-dir=${tempDir.path}',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'suite failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );

    final manifest = jsonDecode(
      File('${tempDir.path}/manifest.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(manifest['schema'], 'tracelite.suite.v1');
    expect(manifest['profile'], 'ci');
    final runs = manifest['runs']! as List<Object?>;
    expect(runs, hasLength(4));
    for (final run in runs.cast<Map<String, Object?>>()) {
      expect(run['status'], 'ok');
      expect(File(run['artifact']! as String).existsSync(), isTrue);
      expect(File(run['log']! as String).existsSync(), isTrue);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
