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
    expect(compare.stdout.toString(), contains('measured elapsed avg'));
    expect(compare.stdout.toString(), contains('scenario elapsed avg'));

    final artifact = jsonDecode(File(artifactPath).readAsStringSync())
        as Map<String, Object?>;
    expect(artifact['schema'], 'tracelite.compare.v1');
    expect(artifact['workload'], isA<Map<String, Object?>>());
    expect(artifact['environment'], isA<Map<String, Object?>>());
    final source = artifact['tracelite_source'] as Map<String, Object?>;
    expect(source['kind'], 'git');
    expect(source['revision'], isA<String>());
    expect(source['dirty'], isA<bool>());
    expect(source['dirty_count'], isA<int>());
    final runner = artifact['runner'] as Map<String, Object?>;
    expect(runner['mode'], 'app_jit');
    expect(runner['requested_mode'], 'auto');
    expect(runner['build_elapsed_ns'] as int, greaterThan(0));
    expect(artifact['repetitions'], 2);
    expect(artifact['ring_data_words'] as int, greaterThan(0));
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
      expect(sample['setup_elapsed_ns'] as int, greaterThan(0));
      expect(sample['measured_elapsed_ns'] as int, greaterThan(0));
      expect(sample['child_elapsed_ns'] as int, greaterThan(0));
      expect(sample['span_groups'] as List<Object?>, isNotEmpty);
      final fingerprints = sample['sql_fingerprint_groups'] as List<Object?>;
      expect(fingerprints, isNotEmpty);
      final normalizedSql = fingerprints
          .cast<Map<String, Object?>>()
          .map((group) => group['normalized_sql'])
          .join('\n');
      expect(normalizedSql, contains('INSERT INTO TRACELITE_ITEMS'));
      expect(normalizedSql, isNot(contains('name_')));
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
    expect(diff.stdout.toString(), contains('delta 95% CI'));
    expect(diff.stdout.toString(), contains('neutral'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('worker runner retargets repeated sqlite samples', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-worker-compare-test-',
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
        '--runner=worker',
        '--out-json=$artifactPath',
      ],
      workingDirectory: Directory.current.path,
    );
    expect(
      compare.exitCode,
      0,
      reason: 'worker compare failed.\nstdout:\n${compare.stdout}\n'
          'stderr:\n${compare.stderr}',
    );

    final artifact = jsonDecode(File(artifactPath).readAsStringSync())
        as Map<String, Object?>;
    final runner = artifact['runner'] as Map<String, Object?>;
    expect(runner['mode'], 'worker');
    expect(runner['requested_mode'], 'worker');
    expect(runner['runtime_libraries'] as List<Object?>, isNotEmpty);

    final peers = artifact['peers'] as List<Object?>;
    final sqlite3 = peers.single as Map<String, Object?>;
    expect(sqlite3['peer'], 'sqlite3');
    expect(sqlite3['status'], 'ok');
    final samples = sqlite3['samples'] as List<Object?>;
    expect(samples, hasLength(2));
    for (final sample in samples.cast<Map<String, Object?>>()) {
      expect(sample['status'], 'ok');
      expect(sample['child_elapsed_ns'] as int, greaterThan(0));
      expect(sample['span_groups'] as List<Object?>, isNotEmpty);
      expect(sample['sql_fingerprint_groups'] as List<Object?>, isNotEmpty);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('require-clean-source rejects dirty source checkouts', () async {
    final marker = File(
      '.tracelite-clean-source-test-${DateTime.now().microsecondsSinceEpoch}',
    );
    marker.writeAsStringSync('temporary dirty marker for test\n');
    addTearDown(() {
      if (marker.existsSync()) marker.deleteSync();
    });

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'compare',
        '--scenario=narrow-batch-insert',
        '--interfaces=sqlite3',
        '--rows=1',
        '--require-clean-source=true',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 65);
    expect(
      result.stderr.toString(),
      contains('tracelite source has uncommitted changes'),
    );
  });
}
