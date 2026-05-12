import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('export-graph-data writes graphable datasets', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-graph-data-test-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final compare = '${tempDir.path}/compare.json';
    final manifest = '${tempDir.path}/manifest.json';
    final decision = '${tempDir.path}/decision.json';
    final workload = '${tempDir.path}/workload-summary.json';
    final outDir = '${tempDir.path}/graph-data';
    _writeCompare(compare);
    _writeManifest(manifest, compare);
    _writeDecision(decision);
    _writeWorkloadSummary(workload);

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'export-graph-data',
        '--suite=$manifest',
        '--decision=$decision',
        '--workload-summary=$workload',
        '--run-id=exp-001',
        '--out=$outDir',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'export failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('scenario_series'));

    final index = _readJson('$outDir/index.json');
    expect(index['schema'], 'tracelite.graph_data.v1');
    expect(index['run_id'], 'exp-001');
    final files = index['files']! as Map<String, Object?>;
    expect(files['scenario_series'], 'scenario-series.json');
    expect(files['decision_summary'], 'decision-summary.json');
    expect(files['workload_operations'], 'workload-operations.json');

    final scenarioSeries = _rows('$outDir/scenario-series.json');
    expect(
      scenarioSeries,
      contains(
        allOf(
          containsPair('scenario', 'synthetic'),
          containsPair('peer', 'resqlite'),
          containsPair('metric', 'elapsed_ns'),
          containsPair('statistic', 'mean'),
          containsPair('value', 100000.0),
        ),
      ),
    );

    final peerSummary = _rows('$outDir/peer-summary.json');
    expect(
      peerSummary.single,
      containsPair('elapsed_mean_ns', 100000.0),
    );

    final decisionSummary = _rows('$outDir/decision-summary.json');
    expect(decisionSummary.single, containsPair('decision', 'accepted'));

    final decisionComparisons = _rows('$outDir/decision-comparisons.json');
    expect(
      decisionComparisons,
      contains(
        allOf(
          containsPair('gate', 'primary'),
          containsPair('metric', 'elapsed_ns'),
          containsPair('gate_effect', 'pass'),
        ),
      ),
    );

    final workloadOperations = _rows('$outDir/workload-operations.json');
    expect(
      workloadOperations,
      contains(
        allOf(
          containsPair('workload', 'single_insert'),
          containsPair('operation', 'execute'),
          containsPair('metric', 'median_us'),
          containsPair('value', 18),
        ),
      ),
    );

    final workloadMemory = _rows('$outDir/workload-memory.json');
    expect(
      workloadMemory,
      contains(
        allOf(
          containsPair('workload', 'single_insert'),
          containsPair('metric', 'rss_delta_mb'),
          containsPair('value', 1.25),
        ),
      ),
    );

    final workloadFanout = _rows('$outDir/workload-fanout.json');
    expect(
      workloadFanout,
      contains(
        allOf(
          containsPair('workload', 'overlap'),
          containsPair('metric', 'writer_us'),
          containsPair('statistic', 'median'),
          containsPair('value', 80),
        ),
      ),
    );

    final validate = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'validate-graph-data',
        outDir,
      ],
      workingDirectory: Directory.current.path,
    );
    expect(
      validate.exitCode,
      0,
      reason: 'validate failed.\nstdout:\n${validate.stdout}\n'
          'stderr:\n${validate.stderr}',
    );
    expect(validate.stdout.toString(), contains('graph data valid'));
  });

  test('validate-graph-data rejects malformed dataset counts', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-graph-data-invalid-test-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final compare = '${tempDir.path}/compare.json';
    final outDir = '${tempDir.path}/graph-data';
    _writeCompare(compare);

    final export = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'export-graph-data',
        '--compare=$compare',
        '--out=$outDir',
      ],
      workingDirectory: Directory.current.path,
    );
    expect(
      export.exitCode,
      0,
      reason: 'export failed.\nstdout:\n${export.stdout}\n'
          'stderr:\n${export.stderr}',
    );

    final indexFile = File('$outDir/index.json');
    final index = _readJson(indexFile.path);
    (index['counts']! as Map<String, Object?>)['peer_summary'] = 999;
    indexFile.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(index)}\n',
    );

    final validate = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'validate-graph-data',
        outDir,
      ],
      workingDirectory: Directory.current.path,
    );
    expect(validate.exitCode, 65);
    expect(validate.stderr.toString(), contains('row count'));
  });

  test('export-graph-data accepts repeated compare inputs', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-graph-data-repeated-compare-test-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final compareA = '${tempDir.path}/compare-a.json';
    final compareB = '${tempDir.path}/compare-b.json';
    final outDir = '${tempDir.path}/graph-data';
    _writeCompare(compareA, scenario: 'synthetic-a');
    _writeCompare(compareB, scenario: 'synthetic-b');

    final export = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'export-graph-data',
        '--compare=$compareA',
        '--compare=$compareB',
        '--out=$outDir',
      ],
      workingDirectory: Directory.current.path,
    );
    expect(
      export.exitCode,
      0,
      reason: 'export failed.\nstdout:\n${export.stdout}\n'
          'stderr:\n${export.stderr}',
    );

    final peerSummary = _rows('$outDir/peer-summary.json');
    expect(
      peerSummary.map((row) => row['scenario']),
      containsAll(['synthetic-a', 'synthetic-b']),
    );
    expect(peerSummary, hasLength(2));
  });
}

void _writeCompare(String path, {String scenario = 'synthetic'}) {
  _writeJson(path, {
    'schema': 'tracelite.compare.v1',
    'generated_at': '2026-05-10T00:00:00Z',
    'scenario': scenario,
    'rows': 10,
    'workload': {
      'rows': 10,
      'required_capabilities': ['sql'],
    },
    'repetitions': 3,
    'peers': [
      {
        'peer': 'resqlite',
        'status': 'ok',
        'successful_repetitions': 3,
        'failed_repetitions': 0,
        'unsupported_repetitions': 0,
        'summary': {
          'elapsed_ns': _stats(100000),
          'measured_elapsed_ns': _stats(80000),
          'sqlite3_step_total_ns': _stats(30000),
          'sqlite3_step_count': _stats(12),
          'trace_span_total_ns': _stats(50000),
          'events': _stats(100),
          'spans': _stats(50),
          'dropped_events': _stats(0),
          'unmatched_begin_events': _stats(0),
          'unmatched_end_events': _stats(0),
        },
        'samples': const [],
        'capabilities': ['sql', 'reactive'],
      },
    ],
  });
}

void _writeManifest(String path, String artifactPath) {
  _writeJson(path, {
    'schema': 'tracelite.suite.v1',
    'generated_at': '2026-05-10T00:00:00Z',
    'profile': 'synthetic',
    'runs': [
      {
        'scenario': 'synthetic',
        'rows': 10,
        'repetitions': 3,
        'artifact': artifactPath,
        'status': 'ok',
      },
    ],
  });
}

void _writeDecision(String path) {
  _writeJson(path, {
    'schema': 'tracelite.decision.v1',
    'generated_at': '2026-05-10T00:00:00Z',
    'decision': 'accepted',
    'baseline_path': 'baseline.json',
    'candidate_path': 'candidate.json',
    'policy': {
      'expectation': 'improvement',
      'primary_peer': 'resqlite',
      'primary_metric': 'elapsed_ns',
      'primary_threshold_percent': 5.0,
      'max_regression_percent': 3.0,
      'max_cv_percent': 15.0,
    },
    'gates': {
      'trace_health': {
        'status': 'passed',
        'issues': const [],
      },
      'primary': {
        'status': 'passed',
        'comparisons': [
          {
            'role': 'primary',
            'scenario': 'synthetic',
            'peer': 'resqlite',
            'metric': 'elapsed_ns',
            'status': 'improved',
            'gate_effect': 'pass',
            'baseline_status': 'ok',
            'candidate_status': 'ok',
            'baseline_mean': 100000.0,
            'candidate_mean': 80000.0,
            'delta': -20000.0,
            'change_percent': -20.0,
            'max_cv_percent': 2.0,
            'nonparametric_p_value': 0.01,
          },
        ],
      },
      'guardrails': {
        'status': 'passed',
        'comparisons': const [],
      },
    },
  });
}

void _writeWorkloadSummary(String path) {
  _writeJson(path, {
    'schema': 'tracelite.workload_summary.v1',
    'generated_at': '2026-05-10T00:00:00Z',
    'workloads': {
      'single_insert': {
        'iterations': 10000,
        'sample_count': 10000,
        'summary': {
          'execute': {
            'count': 10000,
            'min_us': 12,
            'median_us': 18,
            'p90_us': 24,
            'p99_us': 40,
            'max_us': 80,
            'mean_us': 19,
            'work_us_median': 4,
            'dispatch_floor_us': 14,
          },
        },
        'memory': {
          'rss_delta_mb': 1.25,
          'diagnostics_delta': {
            'wal_bytes_delta': 4096,
          },
        },
      },
      'overlap': {
        'iterations': 1,
        'sample_count': 10,
        'summary': const {},
        'fanout_summary': {
          'writer_us': {
            'count': 10,
            'median': 80,
            'p90': 110,
            'max': 130,
          },
        },
      },
    },
  });
}

Map<String, Object?> _stats(num value) => {
      'count': 3,
      'total': value * 3,
      'min': value,
      'max': value,
      'mean': value.toDouble(),
      'median': value,
      'p90': value,
      'p99': value,
      'stddev': 0.0,
      'cv': 0.0,
    };

Map<String, Object?> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

List<Map<String, Object?>> _rows(String path) {
  final json = _readJson(path);
  return (json['rows']! as List<Object?>).cast<Map<String, Object?>>();
}

void _writeJson(String path, Map<String, Object?> value) {
  const encoder = JsonEncoder.withIndent('  ');
  File(path).writeAsStringSync('${encoder.convert(value)}\n');
}

void _deleteTemp(Directory directory) {
  try {
    directory.deleteSync(recursive: true);
  } catch (_) {}
}
