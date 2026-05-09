import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('compare writes repetition JSON and diff reads it', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-compare-artifact-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final artifactPath = '${tempDir.path}/compare.json';
    final compare = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'compare',
        '--scenario=narrow-batch-insert',
        '--interfaces=sqlite3',
        '--rows=3',
        '--repetitions=2',
        '--out-json=$artifactPath',
      ],
      workingDirectory: Directory.current.path,
    );
    expect(
      compare.exitCode,
      0,
      reason: 'compare failed.\nstdout:\n${compare.stdout}\n'
          'stderr:\n${compare.stderr}',
    );

    final artifact = jsonDecode(File(artifactPath).readAsStringSync())
        as Map<String, Object?>;
    expect(artifact['schema'], 'tracelite.compare.v1');
    expect(artifact['repetitions'], 2);
    final peers = artifact['peers'] as List<Object?>;
    expect(peers, hasLength(1));
    final sqlite3 = peers.single as Map<String, Object?>;
    expect(sqlite3['peer'], 'sqlite3');
    expect(sqlite3['status'], 'ok');
    final samples = sqlite3['samples'] as List<Object?>;
    expect(samples, hasLength(2));
    for (final sample in samples.cast<Map<String, Object?>>()) {
      expect(sample['status'], 'ok');
      expect(sample['elapsed_ns'] as int, greaterThan(0));
      expect(sample['child_elapsed_ns'] as int, greaterThan(0));
      expect(sample['span_groups'] as List<Object?>, isNotEmpty);
    }

    final diff = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'diff',
        '--baseline=$artifactPath',
        '--candidate=$artifactPath',
        '--max-cv-percent=1000',
      ],
      workingDirectory: Directory.current.path,
    );
    expect(
      diff.exitCode,
      0,
      reason: 'diff failed.\nstdout:\n${diff.stdout}\n'
          'stderr:\n${diff.stderr}',
    );
    expect(diff.stdout.toString(), contains('| `sqlite3` |'));
    expect(diff.stdout.toString(), contains('neutral'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
