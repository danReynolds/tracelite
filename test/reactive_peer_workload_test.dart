import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/peer_drift.dart'
    show
        driftReactiveTableColumnsForTesting,
        driftReactiveTablePrimaryKeysForTesting;

const _reactiveScenarios = [
  'keyed-pk-subscriptions',
  'high-cardinality-fanout',
  'many-streams-writer-throughput',
  'sustained-writer-pressure',
];

const _streamInitialDrainScenarios = [
  'stream-initial-drain-text',
  'stream-initial-drain-rowid',
  'stream-initial-drain-indexed-int',
];

void main() {
  test('drift reactive table metadata matches workload schemas', () {
    expect(driftReactiveTableColumnsForTesting(), {
      'tracelite_keyed_items': ['id', 'body', 'updated_at'],
      'tracelite_fanout_items': ['id', 'owner_id', 'value'],
      'tracelite_stream_initial_items': [
        'id',
        'owner_id',
        'lookup_key',
        'body',
        'updated_at',
      ],
      'tracelite_wide_items': ['id', 'partition_id', 'a', 'b', 'c'],
      'tracelite_writer_pressure': [
        'id',
        'producer_id',
        'value',
        'payload',
      ],
    });
    expect(driftReactiveTablePrimaryKeysForTesting(), {
      'tracelite_keyed_items': ['id'],
      'tracelite_fanout_items': ['id'],
      'tracelite_stream_initial_items': ['id'],
      'tracelite_wide_items': ['id'],
      'tracelite_writer_pressure': ['id'],
    });
  });

  for (final scenario in _reactiveScenarios) {
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
      expect(
        _lineFor(output, 'sqlite3'),
        contains('| `sqlite3` | unsupported |'),
        reason: 'sqlite3 should be reported as unsupported for $scenario.\n'
            '$output',
      );
      for (final peer in ['drift', 'sqlite_async', 'resqlite']) {
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

  for (final scenario in _streamInitialDrainScenarios) {
    test('resqlite reports stream initial-drain diagnostics for $scenario',
        () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'tracelite-stream-initial-drain-test-',
      );
      addTearDown(() {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final artifactPath = '${tempDir.path}/$scenario.json';

      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          'run',
          'bin/tracelite.dart',
          'compare',
          '--scenario=$scenario',
          '--interfaces=resqlite',
          '--rows=12',
          '--repetitions=1',
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
      expect(workload['required_capabilities'], ['sql', 'reactive']);
      expect(workload['repeat_count'], isA<int>());
      expect(workload['stream_count'], isA<int>());
      expect(workload['rows_per_stream'], isA<int>());

      final peers = artifact['peers']! as List<Object?>;
      final resqlite = _peerByName(peers, 'resqlite');
      expect(resqlite['status'], 'ok');
      final samples = resqlite['samples']! as List<Object?>;
      final sample = samples.single as Map<String, Object?>;
      final measurements = sample['measurements']! as Map<String, Object?>;
      expect(measurements['repeat_count'], workload['repeat_count']);
      expect(measurements['stream_count'], workload['stream_count']);
      expect(measurements['rows_per_stream'], isA<int>());
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  for (final scenario in _reactiveScenarios) {
    test('drift handles larger generated-table reactive stress for $scenario',
        () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'tracelite-drift-reactive-stress-test-',
      );
      addTearDown(() {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final artifactPath = '${tempDir.path}/$scenario.json';

      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          'run',
          'bin/tracelite.dart',
          'compare',
          '--scenario=$scenario',
          '--interfaces=drift',
          '--rows=16',
          '--out-json=$artifactPath',
        ],
        workingDirectory: Directory.current.path,
      );

      expect(
        result.exitCode,
        0,
        reason: 'drift stress compare exited non-zero.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );

      final artifact = jsonDecode(File(artifactPath).readAsStringSync())
          as Map<String, Object?>;
      final workload = artifact['workload']! as Map<String, Object?>;
      expect(workload['required_capabilities'], ['sql', 'reactive']);
      expect(workload['stream_count'] as int, greaterThan(4));
      final workloadWriteCount = scenario == 'sustained-writer-pressure'
          ? workload['total_writes'] as int
          : workload['write_count'] as int;
      expect(workloadWriteCount, greaterThan(10));

      final peers = artifact['peers']! as List<Object?>;
      final drift = _peerByName(peers, 'drift');
      expect(drift['status'], 'ok');
      expect(drift['capabilities'], contains('reactive'));

      final samples = drift['samples']! as List<Object?>;
      final sample = samples.single as Map<String, Object?>;
      expect(sample['status'], 'ok');
      final diagnostics = sample['diagnostics']! as Map<String, Object?>;
      expect(diagnostics['dropped_events'], 0);
      expect(diagnostics['unmatched_begin_events'], 0);
      expect(diagnostics['unmatched_end_events'], 0);
      expect(sample['span_groups'] as List<Object?>, isNotEmpty);
      expect(sample['sql_fingerprint_groups'] as List<Object?>, isNotEmpty);

      final measurements = sample['measurements']! as Map<String, Object?>;
      expect(measurements['stream_count'], workload['stream_count']);
      if (scenario == 'sustained-writer-pressure') {
        expect(
          measurements['total_writes_per_phase'],
          workload['total_writes'],
        );
        expect(measurements['no_streams_write_loop_elapsed_ns'], isA<int>());
        expect(
          measurements['aggregate_stream_write_loop_elapsed_ns'],
          isA<int>(),
        );
        expect(measurements['aggregate_stream_settle_elapsed_ns'], isA<int>());
        expect(
          measurements['keyed_streams_write_loop_elapsed_ns'],
          isA<int>(),
        );
        expect(measurements['keyed_streams_settle_elapsed_ns'], isA<int>());
        expect(
          measurements['aggregate_stream_elapsed_ns'] as int,
          greaterThanOrEqualTo(
            measurements['aggregate_stream_write_loop_elapsed_ns'] as int,
          ),
        );
        expect(
          measurements['keyed_streams_elapsed_ns'] as int,
          greaterThanOrEqualTo(
            measurements['keyed_streams_write_loop_elapsed_ns'] as int,
          ),
        );
        expect(measurements['aggregate_emissions'], isA<int>());
        expect(measurements['keyed_emissions'], isA<int>());
        expect(
          measurements['aggregate_stream_write_loop_emissions'],
          isA<int>(),
        );
        expect(measurements['aggregate_stream_settle_emissions'], isA<int>());
        expect(measurements['keyed_streams_write_loop_emissions'], isA<int>());
        expect(measurements['keyed_streams_settle_emissions'], isA<int>());
        expect(
          measurements['aggregate_emissions'],
          (measurements['aggregate_stream_write_loop_emissions'] as int) +
              (measurements['aggregate_stream_settle_emissions'] as int),
        );
        expect(
          measurements['keyed_emissions'],
          (measurements['keyed_streams_write_loop_emissions'] as int) +
              (measurements['keyed_streams_settle_emissions'] as int),
        );
      } else if (scenario == 'many-streams-writer-throughput') {
        expect(measurements['write_count'], workload['write_count']);
        expect(measurements['disjoint_emissions'], isA<int>());
        expect(measurements['overlap_emissions'], isA<int>());
      } else {
        expect(measurements['write_count'], workload['write_count']);
        expect(measurements['post_baseline_emissions'], isA<int>());
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
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
