import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  for (final scenario in [
    'keyed-pk-subscriptions',
    'high-cardinality-fanout',
    'many-streams-writer-throughput',
  ]) {
    test('compare reports capability-aware results for $scenario', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          'run',
          'bin/tracelite.dart',
          'compare',
          '--scenario=$scenario',
          '--interfaces=sqlite3,drift,sqlite_async,resqlite',
          '--rows=4',
        ],
        workingDirectory: Directory.current.path,
      );

      expect(
        result.exitCode,
        0,
        reason: 'compare exited non-zero.\nstdout:\n${result.stdout}\n'
            'stderr:\n${result.stderr}',
      );

      final output = result.stdout as String;
      for (final peer in ['sqlite3', 'drift']) {
        expect(
          _lineFor(output, peer),
          contains('| `$peer` | unsupported |'),
          reason: '$peer should be reported as unsupported for $scenario.\n'
              '$output',
        );
      }
      for (final peer in ['sqlite_async', 'resqlite']) {
        final line = _lineFor(output, peer);
        expect(
          line,
          contains('| `$peer` | ok |'),
          reason: '$peer should complete $scenario.\n$output',
        );
        expect(
          line,
          contains('| 0/0/0 |'),
          reason: '$peer should complete without trace diagnostics.\n$output',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  test('diagnostic scenario records resqlite gauges and unsupported peers',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-diagnostics-artifact-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final artifactPath = '${tempDir.path}/diagnostics.json';

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'compare',
        '--scenario=sqlite-diagnostics',
        '--interfaces=sqlite3,drift,sqlite_async,resqlite',
        '--rows=4',
        '--out-json=$artifactPath',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'compare exited non-zero.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );

    final artifact = jsonDecode(File(artifactPath).readAsStringSync())
        as Map<String, Object?>;
    final workload = artifact['workload']! as Map<String, Object?>;
    expect(workload['required_capabilities'], ['sql', 'diagnostics']);

    final peers = artifact['peers']! as List<Object?>;
    for (final peer in ['sqlite3', 'drift', 'sqlite_async']) {
      final peerArtifact = _peerByName(peers, peer);
      expect(peerArtifact['status'], 'unsupported');
      expect(peerArtifact['unsupported_repetitions'], 1);
    }

    final resqlite = _peerByName(peers, 'resqlite');
    expect(resqlite['status'], 'ok');
    expect(resqlite['capabilities'], contains('diagnostics'));
    final samples = resqlite['samples']! as List<Object?>;
    final sample = samples.single as Map<String, Object?>;
    final measurements = sample['measurements']! as Map<String, Object?>;
    expect(measurements['sqlite_page_cache_bytes'], isA<int>());
    expect(measurements['sqlite_schema_bytes'], isA<int>());
    expect(measurements['sqlite_stmt_bytes'], isA<int>());
    expect(measurements['wal_bytes'], isA<int>());
    expect(measurements['stream_count'], isA<int>());
    expect(measurements['reader_busy'], isA<bool>());

    final counterGroups = sample['counter_groups']! as List<Object?>;
    final counterNames = {
      for (final group in counterGroups.cast<Map<String, Object?>>())
        group['counter_name'],
    };
    expect(counterNames, contains('resqlite.sqlite_page_cache_bytes'));
    expect(counterNames, contains('resqlite.sqlite_schema_bytes'));
    expect(counterNames, contains('resqlite.sqlite_stmt_bytes'));
    expect(counterNames, contains('resqlite.wal_bytes'));
    expect(counterNames, contains('resqlite.stream_count'));
    expect(counterNames, contains('resqlite.reader_busy'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}

String _lineFor(String output, String peer) {
  return output.split('\n').firstWhere(
        (line) => line.startsWith('| `$peer` |'),
        orElse: () => throw StateError('missing table line for $peer'),
      );
}

Map<String, Object?> _peerByName(List<Object?> peers, String name) {
  return peers.cast<Map<String, Object?>>().firstWhere(
        (peer) => peer['peer'] == name,
        orElse: () => throw StateError('missing peer artifact for $name'),
      );
}
