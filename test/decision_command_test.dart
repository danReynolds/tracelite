import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('decision accepts clear experiment wins with clean guardrails',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-decision-accepted-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final baseline = '${tempDir.path}/baseline.json';
    final candidate = '${tempDir.path}/candidate.json';
    final decision = '${tempDir.path}/decision.json';
    _writeArtifact(baseline, [100000, 102000, 98000, 101000, 99000]);
    _writeArtifact(candidate, [80000, 82000, 78000, 81000, 79000]);

    final result = await _runDecision(
      baseline: baseline,
      candidate: candidate,
      outJson: decision,
    );

    expect(
      result.exitCode,
      0,
      reason: 'decision failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('Decision: `accepted`'));
    final artifact =
        jsonDecode(File(decision).readAsStringSync()) as Map<String, Object?>;
    expect(artifact['schema'], 'tracelite.decision.v1');
    expect(artifact['decision'], 'accepted');
  });

  test('decision rejects statistically clear regressions', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-decision-rejected-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final baseline = '${tempDir.path}/baseline.json';
    final candidate = '${tempDir.path}/candidate.json';
    _writeArtifact(baseline, [100000, 102000, 98000, 101000, 99000]);
    _writeArtifact(candidate, [120000, 122000, 118000, 121000, 119000]);

    final result = await _runDecision(
      baseline: baseline,
      candidate: candidate,
      expect: 'no_regression',
    );

    expect(result.exitCode, 65);
    expect(result.stdout.toString(), contains('Decision: `rejected`'));
    expect(result.stdout.toString(), contains('`regressed`'));
  });

  test('decision marks neutral experiment evidence inconclusive', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-decision-inconclusive-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final baseline = '${tempDir.path}/baseline.json';
    final candidate = '${tempDir.path}/candidate.json';
    _writeArtifact(baseline, [100000, 102000, 98000, 101000, 99000]);
    _writeArtifact(candidate, [99000, 103000, 98000, 102000, 100000]);

    final result = await _runDecision(
      baseline: baseline,
      candidate: candidate,
    );

    expect(result.exitCode, 65);
    expect(result.stdout.toString(), contains('Decision: `inconclusive`'));
    expect(result.stdout.toString(), contains('`neutral`'));
  });

  test('decision accepts suite manifests', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-decision-suite-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final baselineArtifact = '${tempDir.path}/baseline-synthetic.json';
    final candidateArtifact = '${tempDir.path}/candidate-synthetic.json';
    final baselineManifest = '${tempDir.path}/baseline-manifest.json';
    final candidateManifest = '${tempDir.path}/candidate-manifest.json';
    _writeArtifact(baselineArtifact, [100000, 102000, 98000, 101000, 99000]);
    _writeArtifact(candidateArtifact, [80000, 82000, 78000, 81000, 79000]);
    _writeManifest(baselineManifest, baselineArtifact);
    _writeManifest(candidateManifest, candidateArtifact);

    final result = await _runDecision(
      baseline: baselineManifest,
      candidate: candidateManifest,
    );

    expect(
      result.exitCode,
      0,
      reason: 'decision failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('Decision: `accepted`'));
  });

  test('decision accepts suite history manifests', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-decision-suite-history-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final baselineArtifact = '${tempDir.path}/baseline-synthetic.json';
    final candidateArtifact = '${tempDir.path}/candidate-synthetic.json';
    final baselineManifest = '${tempDir.path}/baseline-manifest.json';
    final candidateManifest = '${tempDir.path}/candidate-manifest.json';
    final baselineHistory = '${tempDir.path}/baseline-history.json';
    final candidateHistory = '${tempDir.path}/candidate-history.json';
    _writeArtifact(baselineArtifact, [100000, 102000, 98000, 101000, 99000]);
    _writeArtifact(candidateArtifact, [80000, 82000, 78000, 81000, 79000]);
    _writeManifest(baselineManifest, baselineArtifact);
    _writeManifest(candidateManifest, candidateArtifact);
    _writeHistory(baselineHistory, [baselineManifest]);
    _writeHistory(candidateHistory, [candidateManifest]);

    final result = await _runDecision(
      baseline: baselineHistory,
      candidate: candidateHistory,
    );

    expect(
      result.exitCode,
      0,
      reason: 'decision failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('Decision: `accepted`'));
  });

  test('decision aggregates repetitions across suite history runs', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-decision-suite-history-aggregate-',
    );
    addTearDown(() => _deleteTemp(tempDir));

    final baselineA = '${tempDir.path}/baseline-a.json';
    final baselineB = '${tempDir.path}/baseline-b.json';
    final candidateA = '${tempDir.path}/candidate-a.json';
    final candidateB = '${tempDir.path}/candidate-b.json';
    final baselineManifestA = '${tempDir.path}/baseline-manifest-a.json';
    final baselineManifestB = '${tempDir.path}/baseline-manifest-b.json';
    final candidateManifestA = '${tempDir.path}/candidate-manifest-a.json';
    final candidateManifestB = '${tempDir.path}/candidate-manifest-b.json';
    final baselineHistory = '${tempDir.path}/baseline-history.json';
    final candidateHistory = '${tempDir.path}/candidate-history.json';
    final decision = '${tempDir.path}/decision.json';

    _writeArtifact(baselineA, [100000, 102000, 98000]);
    _writeArtifact(baselineB, [101000, 99000, 100000]);
    _writeArtifact(candidateA, [80000, 82000, 78000]);
    _writeArtifact(candidateB, [81000, 79000, 80000]);
    _writeManifest(baselineManifestA, baselineA);
    _writeManifest(baselineManifestB, baselineB);
    _writeManifest(candidateManifestA, candidateA);
    _writeManifest(candidateManifestB, candidateB);
    _writeHistory(baselineHistory, [baselineManifestA, baselineManifestB]);
    _writeHistory(candidateHistory, [candidateManifestA, candidateManifestB]);

    final result = await _runDecision(
      baseline: baselineHistory,
      candidate: candidateHistory,
      outJson: decision,
    );

    expect(
      result.exitCode,
      0,
      reason: 'decision failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    final artifact =
        jsonDecode(File(decision).readAsStringSync()) as Map<String, Object?>;
    final gates = artifact['gates']! as Map<String, Object?>;
    final primary = gates['primary']! as Map<String, Object?>;
    final comparisons = primary['comparisons']! as List<Object?>;
    final comparison = comparisons.single as Map<String, Object?>;
    expect(comparison['baseline_samples'], 6);
    expect(comparison['candidate_samples'], 6);
  });
}

Future<ProcessResult> _runDecision({
  required String baseline,
  required String candidate,
  String? outJson,
  String expect = 'improvement',
}) {
  return Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      'bin/tracelite.dart',
      'decision',
      '--baseline=$baseline',
      '--candidate=$candidate',
      '--expect=$expect',
      '--primary-peer=sqlite3',
      '--primary-metric=elapsed_ns',
      '--guardrail-peers=sqlite3',
      '--guardrail-metrics=elapsed_ns',
      '--max-cv-percent=100',
      if (outJson != null) '--out-json=$outJson',
    ],
    workingDirectory: Directory.current.path,
  );
}

void _writeArtifact(String path, List<int> elapsedNs) {
  const encoder = JsonEncoder.withIndent('  ');
  File(path).writeAsStringSync(
    '${encoder.convert({
          'schema': 'tracelite.compare.v1',
          'generated_at': '2026-05-10T00:00:00Z',
          'scenario': 'synthetic',
          'rows': 1,
          'workload': const {
            'rows': 1,
            'required_capabilities': ['sql'],
          },
          'repetitions': elapsedNs.length,
          'peers': [
            {
              'peer': 'sqlite3',
              'status': 'ok',
              'successful_repetitions': elapsedNs.length,
              'failed_repetitions': 0,
              'unsupported_repetitions': 0,
              'summary': const {},
              'samples': [
                for (var i = 0; i < elapsedNs.length; i++)
                  {
                    'repetition': i + 1,
                    'status': 'ok',
                    'elapsed_ns': elapsedNs[i],
                  },
              ],
              'capabilities': ['sql'],
            },
          ],
        })}\n',
  );
}

void _writeManifest(String path, String artifactPath) {
  const encoder = JsonEncoder.withIndent('  ');
  File(path).writeAsStringSync(
    '${encoder.convert({
          'schema': 'tracelite.suite.v1',
          'generated_at': '2026-05-10T00:00:00Z',
          'profile': 'synthetic',
          'runs': [
            {
              'scenario': 'synthetic',
              'rows': 1,
              'repetitions': 5,
              'artifact': artifactPath,
              'status': 'ok',
            },
          ],
        })}\n',
  );
}

void _writeHistory(String path, List<String> manifestPaths) {
  const encoder = JsonEncoder.withIndent('  ');
  File(path).writeAsStringSync(
    '${encoder.convert({
          'schema': 'tracelite.suite_history.v1',
          'generated_at': '2026-05-10T00:00:00Z',
          'profile': 'synthetic',
          'requested_runs': manifestPaths.length,
          'successful_runs': manifestPaths.length,
          'runs': [
            for (var i = 0; i < manifestPaths.length; i++)
              {
                'run': i + 1,
                'name': 'run-${(i + 1).toString().padLeft(3, '0')}',
                'manifest': manifestPaths[i],
                'status': 'ok',
              },
          ],
        })}\n',
  );
}

void _deleteTemp(Directory directory) {
  try {
    directory.deleteSync(recursive: true);
  } catch (_) {}
}
