import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';

void main() {
  test('calibrate-policy recommends gates from repeated suite history',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-policy-calibration-ready-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final historyDir = Directory('${tempDir.path}/history')..createSync();
    _writeSuiteRun(
      '${historyDir.path}/run-a',
      elapsedNs: [100000, 101000, 99000, 100500, 99500],
    );
    _writeSuiteRun(
      '${historyDir.path}/run-b',
      elapsedNs: [101000, 100000, 99000, 100200, 99800],
    );
    final outJson = '${tempDir.path}/policy.json';

    final result = await _runCalibratePolicy([
      '--history=${historyDir.path}',
      '--metrics=elapsed_ns',
      '--min-history-runs=2',
      '--min-repetitions=5',
      '--strict=true',
      '--out-json=$outJson',
    ]);

    expect(
      result.exitCode,
      0,
      reason: 'calibrate-policy failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('Status: `ready`'));
    final artifact = _readJson(outJson);
    expect(artifact['schema'], 'tracelite.policy_calibration.v1');
    expect(artifact['status'], 'ready');
    expect(artifact['source_count'], 2);
    final policy = artifact['policy']! as Map<String, Object?>;
    expect(policy['recommended_repetitions'] as int, greaterThanOrEqualTo(5));
    expect(
        policy['primary_threshold_percent'] as double, greaterThanOrEqualTo(5));
    final groups =
        (artifact['groups']! as List<Object?>).cast<Map<String, Object?>>();
    expect(groups, hasLength(1));
    expect(groups.single['status'], 'ready');
    expect(groups.single['history_runs'], 2);
  });

  test('decision and diff consume ready calibration policy', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-policy-calibration-consume-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final historyDir = Directory('${tempDir.path}/history')..createSync();
    _writeSuiteRun(
      '${historyDir.path}/run-a',
      elapsedNs: [100000, 101000, 99000, 100500, 99500],
    );
    _writeSuiteRun(
      '${historyDir.path}/run-b',
      elapsedNs: [101000, 100000, 99000, 100200, 99800],
    );
    final policyPath = '${tempDir.path}/policy.json';
    final policy = await _runCalibratePolicy([
      '--history=${historyDir.path}',
      '--metrics=elapsed_ns',
      '--strict=true',
      '--out-json=$policyPath',
    ]);
    expect(
      policy.exitCode,
      0,
      reason: 'calibrate-policy failed.\nstdout:\n${policy.stdout}\n'
          'stderr:\n${policy.stderr}',
    );

    final baseline = '${tempDir.path}/baseline.json';
    final candidate = '${tempDir.path}/candidate.json';
    final decisionPath = '${tempDir.path}/decision.json';
    _writeCompare(baseline, [1000000, 1010000, 1020000, 1030000, 1040000]);
    _writeCompare(candidate, [700000, 710000, 720000, 730000, 740000]);

    final decision = await _runDecision([
      '--baseline=$baseline',
      '--candidate=$candidate',
      '--policy=$policyPath',
      '--primary-peer=sqlite3',
      '--primary-metric=elapsed_ns',
      '--guardrail-peers=sqlite3',
      '--guardrail-metrics=elapsed_ns',
      '--out-json=$decisionPath',
    ]);
    expect(
      decision.exitCode,
      0,
      reason: 'decision failed.\nstdout:\n${decision.stdout}\n'
          'stderr:\n${decision.stderr}',
    );
    expect(decision.stdout.toString(), contains('Primary threshold: 5.00%'));
    final decisionArtifact = _readJson(decisionPath);
    final effectivePolicy = decisionArtifact['policy']! as Map<String, Object?>;
    expect(effectivePolicy['primary_threshold_percent'], 5.0);
    expect(effectivePolicy['max_cv_percent'], 5.0);

    final diff = await _runDiff([
      '--baseline=$baseline',
      '--candidate=$candidate',
      '--metric=elapsed_ns',
      '--policy=$policyPath',
    ]);
    expect(
      diff.exitCode,
      0,
      reason: 'diff failed.\nstdout:\n${diff.stdout}\n'
          'stderr:\n${diff.stderr}',
    );
    expect(diff.stdout.toString(), contains('Threshold: 5.00%'));
    expect(_lineFor(diff.stdout.toString(), 'sqlite3'), contains('improved'));
  });

  test('calibrate-policy strict mode rejects single-run history', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-policy-calibration-single-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final comparePath = '${tempDir.path}/compare.json';
    _writeCompare(comparePath, [100000, 101000, 99000, 100500, 99500]);
    final outJson = '${tempDir.path}/policy.json';

    final result = await _runCalibratePolicy([
      '--history=$comparePath',
      '--metrics=elapsed_ns',
      '--min-history-runs=2',
      '--min-repetitions=5',
      '--strict=true',
      '--out-json=$outJson',
    ]);

    expect(result.exitCode, 65);
    expect(result.stdout.toString(), contains('Status: `needs_history`'));
    final artifact = _readJson(outJson);
    expect(artifact['status'], 'needs_history');
    final group =
        (artifact['groups']! as List<Object?>).single as Map<String, Object?>;
    expect(group['findings'], contains('insufficient_history'));

    final decision = await _runDecision([
      '--baseline=$comparePath',
      '--candidate=$comparePath',
      '--policy=$outJson',
      '--primary-peer=sqlite3',
      '--primary-metric=elapsed_ns',
    ]);
    expect(decision.exitCode, 65);
    expect(decision.stderr.toString(), contains('status `needs_history`'));
  });

  test('calibrate-policy tolerates isolated repetition outliers', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-policy-calibration-outlier-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final historyDir = Directory('${tempDir.path}/history')..createSync();
    _writeSuiteRun(
      '${historyDir.path}/run-a',
      elapsedNs: [100000, 101000, 99000, 100500, 99500, 100200, 99800],
    );
    _writeSuiteRun(
      '${historyDir.path}/run-b',
      elapsedNs: [101000, 100000, 99000, 100200, 99800, 99500, 100400],
    );
    _writeSuiteRun(
      '${historyDir.path}/run-c',
      elapsedNs: [100000, 99500, 100400, 101000, 99000, 350000, 100200],
    );
    _writeSuiteRun(
      '${historyDir.path}/run-d',
      elapsedNs: [100300, 100500, 99600, 100100, 99700, 100000, 100200],
    );
    _writeSuiteRun(
      '${historyDir.path}/run-e',
      elapsedNs: [100200, 99800, 100300, 100500, 99500, 100100, 99900],
    );
    final outJson = '${tempDir.path}/policy.json';

    final result = await _runCalibratePolicy([
      '--history=${historyDir.path}',
      '--metrics=elapsed_ns',
      '--min-history-runs=5',
      '--min-repetitions=5',
      '--threshold-ceiling-percent=50',
      '--noise-gate-ceiling-percent=50',
      '--strict=true',
      '--out-json=$outJson',
    ]);

    expect(
      result.exitCode,
      0,
      reason: 'calibrate-policy failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    final artifact = _readJson(outJson);
    expect(artifact['status'], 'ready');
    final group =
        (artifact['groups']! as List<Object?>).single as Map<String, Object?>;
    expect(group['status'], 'ready');
    expect(group['outlier_count'], 1);
    expect(group['findings'], isEmpty);
  });

  test('calibrate-policy rejects frequent repetition outliers', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-policy-calibration-outlier-reject-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final historyDir = Directory('${tempDir.path}/history')..createSync();
    for (var i = 0; i < 5; i++) {
      _writeSuiteRun(
        '${historyDir.path}/run-$i',
        elapsedNs: [100000, 101000, 99000, 100500, 99500, 350000, 100200],
      );
    }
    final outJson = '${tempDir.path}/policy.json';

    final result = await _runCalibratePolicy([
      '--history=${historyDir.path}',
      '--metrics=elapsed_ns',
      '--min-history-runs=5',
      '--min-repetitions=5',
      '--max-run-outlier-percent=20',
      '--max-outlier-percent=10',
      '--threshold-ceiling-percent=50',
      '--noise-gate-ceiling-percent=50',
      '--strict=true',
      '--out-json=$outJson',
    ]);

    expect(result.exitCode, 65);
    final artifact = _readJson(outJson);
    expect(artifact['status'], 'not_ready');
    final group =
        (artifact['groups']! as List<Object?>).single as Map<String, Object?>;
    expect(group['status'], 'too_noisy');
    expect(group['findings'], contains('excessive_outliers'));
  });

  test('calibrate-policy rejects thresholds above configured ceiling',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-policy-calibration-ceiling-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final historyDir = Directory('${tempDir.path}/history')..createSync();
    _writeSuiteRun(
      '${historyDir.path}/run-a',
      elapsedNs: [100000, 200000, 100000, 200000, 100000],
    );
    _writeSuiteRun(
      '${historyDir.path}/run-b',
      elapsedNs: [110000, 210000, 110000, 210000, 110000],
    );
    final outJson = '${tempDir.path}/policy.json';

    final result = await _runCalibratePolicy([
      '--history=${historyDir.path}',
      '--metrics=elapsed_ns',
      '--min-history-runs=2',
      '--min-repetitions=5',
      '--max-repetitions=50',
      '--target-rse-percent=10',
      '--threshold-ceiling-percent=50',
      '--strict=true',
      '--out-json=$outJson',
    ]);

    expect(result.exitCode, 65);
    expect(result.stdout.toString(), contains('Status: `not_ready`'));
    expect(result.stdout.toString(), contains('threshold_too_loose'));
    final artifact = _readJson(outJson);
    expect(artifact['status'], 'not_ready');
    final group =
        (artifact['groups']! as List<Object?>).single as Map<String, Object?>;
    expect(group['status'], 'too_noisy');
    expect(group['findings'], contains('threshold_too_loose'));
  });

  test('calibrate-policy can scope release gates by scenario and peer',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-policy-calibration-scope-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final historyDir = Directory('${tempDir.path}/history')..createSync();
    _writeCompare(
      '${historyDir.path}/run-a.json',
      const [],
      scenario: 'release-lane',
      peers: const {
        'resqlite': [100000, 101000, 99000, 100500, 99500],
        'sqlite3': [100000, 200000, 100000, 200000, 100000],
      },
    );
    _writeCompare(
      '${historyDir.path}/run-b.json',
      const [],
      scenario: 'release-lane',
      peers: const {
        'resqlite': [101000, 100000, 99000, 100200, 99800],
        'sqlite3': [110000, 210000, 110000, 210000, 110000],
      },
    );
    final outJson = '${tempDir.path}/policy.json';

    final result = await _runCalibratePolicy([
      '--history=${historyDir.path}',
      '--metrics=elapsed_ns',
      '--scenarios=release-lane',
      '--peers=resqlite',
      '--threshold-ceiling-percent=50',
      '--target-rse-percent=10',
      '--strict=true',
      '--out-json=$outJson',
    ]);

    expect(
      result.exitCode,
      0,
      reason: 'calibrate-policy failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    final artifact = _readJson(outJson);
    expect(artifact['status'], 'ready');
    final options = artifact['options']! as Map<String, Object?>;
    expect(options['scenarios'], ['release-lane']);
    expect(options['peers'], ['resqlite']);
    final groups =
        (artifact['groups']! as List<Object?>).cast<Map<String, Object?>>();
    expect(groups, hasLength(1));
    expect(groups.single['peer'], 'resqlite');
    expect(groups.single['scenario'], 'release-lane');
  });
}

Future<ProcessResult> _runCalibratePolicy(List<String> args) {
  return Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      'bin/tracelite.dart',
      'calibrate-policy',
      ...args,
    ],
    workingDirectory: Directory.current.path,
  );
}

Future<ProcessResult> _runDecision(List<String> args) {
  return Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      'bin/tracelite.dart',
      'decision',
      ...args,
    ],
    workingDirectory: Directory.current.path,
  );
}

Future<ProcessResult> _runDiff(List<String> args) {
  return Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      'bin/tracelite.dart',
      'diff',
      ...args,
    ],
    workingDirectory: Directory.current.path,
  );
}

void _writeSuiteRun(String directoryPath, {required List<int> elapsedNs}) {
  final directory = Directory(directoryPath)..createSync(recursive: true);
  final comparePath = '${directory.path}/compare.json';
  _writeCompare(comparePath, elapsedNs);
  const encoder = JsonEncoder.withIndent('  ');
  File('${directory.path}/manifest.json').writeAsStringSync(
    '${encoder.convert({
          'schema': 'tracelite.suite.v1',
          'generated_at': '2026-05-13T00:00:00Z',
          'profile': 'synthetic',
          'runs': [
            {
              'scenario': 'synthetic',
              'rows': 1,
              'repetitions': elapsedNs.length,
              'artifact': 'compare.json',
              'status': 'ok',
            },
          ],
        })}\n',
  );
}

void _writeCompare(
  String path,
  List<int> elapsedNs, {
  String scenario = 'synthetic',
  Map<String, List<int>>? peers,
}) {
  final peerSamples = peers ?? {'sqlite3': elapsedNs};
  final repetitions = peerSamples.values.first.length;
  const encoder = JsonEncoder.withIndent('  ');
  File(path).writeAsStringSync(
    '${encoder.convert({
          'schema': 'tracelite.compare.v1',
          'generated_at': '2026-05-13T00:00:00Z',
          'scenario': scenario,
          'rows': 1,
          'repetitions': repetitions,
          'peers': [
            for (final entry in peerSamples.entries)
              {
                'peer': entry.key,
                'status': 'ok',
                'successful_repetitions': entry.value.length,
                'failed_repetitions': 0,
                'unsupported_repetitions': 0,
                'summary': {
                  'elapsed_ns': _stats(entry.value),
                },
                'samples': [
                  for (var i = 0; i < entry.value.length; i++)
                    {
                      'repetition': i + 1,
                      'status': 'ok',
                      'elapsed_ns': entry.value[i],
                    },
                ],
              },
          ],
        })}\n',
  );
}

Map<String, Object?> _stats(List<int> values) {
  final sorted = values.toList()..sort();
  final total = sorted.fold<int>(0, (sum, value) => sum + value);
  final mean = total / sorted.length;
  final variance = sorted.fold<double>(
        0,
        (sum, value) => sum + (value - mean) * (value - mean),
      ) /
      sorted.length;
  return {
    'count': sorted.length,
    'total': total,
    'min': sorted.first,
    'max': sorted.last,
    'mean': mean,
    'median': sorted[sorted.length ~/ 2],
    'p90': sorted[((sorted.length - 1) * 0.90).ceil()],
    'p99': sorted[((sorted.length - 1) * 0.99).ceil()],
    'stddev': math.sqrt(variance),
    'cv': mean == 0 ? 0 : math.sqrt(variance) / mean,
  };
}

String _lineFor(String output, String peer) {
  return output.split('\n').firstWhere(
        (line) => line.startsWith('| `$peer` |'),
        orElse: () => throw StateError('missing table line for $peer'),
      );
}

Map<String, Object?> _readJson(String path) {
  return jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
}

void _deleteTemp(Directory directory) {
  try {
    directory.deleteSync(recursive: true);
  } catch (_) {}
}
