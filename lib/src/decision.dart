import 'dart:math' as math;

import 'trace.dart';

const String benchmarkDecisionSchema = 'tracelite.decision.v1';

final class BenchmarkDecisionOptions {
  const BenchmarkDecisionOptions({
    this.expectation = 'improvement',
    this.primaryPeer = 'resqlite',
    this.primaryScenarios = const [],
    this.primaryMetric = 'elapsed_ns',
    this.guardrailPeers = const [],
    this.guardrailScenarios = const [],
    this.guardrailMetrics = defaultGuardrailMetrics,
    this.primaryThresholdPercent = 5,
    this.maxRegressionPercent = 3,
    this.maxCvPercent = 15,
    this.alpha = 0.05,
  });

  final String expectation;
  final String primaryPeer;
  final List<String> primaryScenarios;
  final String primaryMetric;
  final List<String> guardrailPeers;
  final List<String> guardrailScenarios;
  final List<String> guardrailMetrics;
  final double primaryThresholdPercent;
  final double maxRegressionPercent;
  final double maxCvPercent;
  final double alpha;

  Map<String, Object?> toJson() => {
        'expectation': expectation,
        'primary_peer': primaryPeer,
        'primary_scenarios': primaryScenarios,
        'primary_metric': primaryMetric,
        'guardrail_peers': guardrailPeers,
        'guardrail_scenarios': guardrailScenarios,
        'guardrail_metrics': guardrailMetrics,
        'primary_threshold_percent': primaryThresholdPercent,
        'max_regression_percent': maxRegressionPercent,
        'max_cv_percent': maxCvPercent,
        'alpha': alpha,
      };
}

const List<String> defaultGuardrailMetrics = [
  'elapsed_ns',
  'measured_elapsed_ns',
  'sqlite3_step_total_ns',
  'trace_span_total_ns',
  'dropped_events',
  'unmatched_begin_events',
  'unmatched_end_events',
];

Map<String, Object?> benchmarkDecisionArtifact({
  required List<Map<String, Object?>> baselineArtifacts,
  required List<Map<String, Object?>> candidateArtifacts,
  required BenchmarkDecisionOptions options,
  String? baselinePath,
  String? candidatePath,
}) {
  final baselineByScenario = _artifactsByScenario(baselineArtifacts);
  final candidateByScenario = _artifactsByScenario(candidateArtifacts);
  final commonScenarios = baselineByScenario.keys
      .where(candidateByScenario.containsKey)
      .toList()
    ..sort();

  final primaryScenarios = _selectedValues(
    requested: options.primaryScenarios,
    available: commonScenarios,
  );
  final guardrailScenarios = _selectedValues(
    requested: options.guardrailScenarios,
    available: commonScenarios,
  );

  final traceHealth = <Map<String, Object?>>[];
  final primary = <Map<String, Object?>>[];
  final guardrails = <Map<String, Object?>>[];

  for (final scenario in commonScenarios) {
    final baseline = baselineByScenario[scenario]!;
    final candidate = candidateByScenario[scenario]!;
    final baselinePeers = _peersByName(baseline);
    final candidatePeers = _peersByName(candidate);
    final commonPeers = baselinePeers.keys.where(candidatePeers.containsKey);
    final peers = _selectedValues(
      requested: options.guardrailPeers,
      available: commonPeers.toList()..sort(),
    );
    for (final peer in peers) {
      final health = _traceHealthCheck(
        scenario: scenario,
        peer: peer,
        baselinePeer: baselinePeers[peer],
        candidatePeer: candidatePeers[peer],
      );
      if (health != null) traceHealth.add(health);
    }
  }

  for (final scenario in primaryScenarios) {
    final comparison = _compareMetric(
      role: 'primary',
      scenario: scenario,
      peer: options.primaryPeer,
      metric: options.primaryMetric,
      baselineArtifact: baselineByScenario[scenario],
      candidateArtifact: candidateByScenario[scenario],
      thresholdPercent: options.primaryThresholdPercent,
      maxCvPercent: options.maxCvPercent,
      alpha: options.alpha,
    );
    primary.add({
      ...comparison,
      'gate_effect': _primaryGateEffect(
        comparison,
        expectation: options.expectation,
      ),
    });
  }
  final missingPrimaryScenarios = options.primaryScenarios
      .where((scenario) => !commonScenarios.contains(scenario))
      .toList()
    ..sort();
  if (primaryScenarios.isEmpty) {
    primary.add(_missingPrimaryComparison(
      scenario: options.primaryScenarios.isEmpty
          ? '<no-common-scenario>'
          : options.primaryScenarios.join(','),
      peer: options.primaryPeer,
      metric: options.primaryMetric,
    ));
  } else {
    for (final scenario in missingPrimaryScenarios) {
      primary.add(_missingPrimaryComparison(
        scenario: scenario,
        peer: options.primaryPeer,
        metric: options.primaryMetric,
      ));
    }
  }

  for (final scenario in guardrailScenarios) {
    final baseline = baselineByScenario[scenario]!;
    final candidate = candidateByScenario[scenario]!;
    final baselinePeers = _peersByName(baseline);
    final candidatePeers = _peersByName(candidate);
    final commonPeers = baselinePeers.keys.where(candidatePeers.containsKey);
    final peers = _selectedValues(
      requested: options.guardrailPeers,
      available: commonPeers.toList()..sort(),
    );
    for (final peer in peers) {
      for (final metric in options.guardrailMetrics) {
        final comparison = _compareMetric(
          role: 'guardrail',
          scenario: scenario,
          peer: peer,
          metric: metric,
          baselineArtifact: baseline,
          candidateArtifact: candidate,
          thresholdPercent: options.maxRegressionPercent,
          maxCvPercent: options.maxCvPercent,
          alpha: options.alpha,
        );
        final effect = _guardrailGateEffect(comparison);
        if (effect == 'skip') continue;
        guardrails.add({
          ...comparison,
          'gate_effect': effect,
        });
      }
    }
  }

  final traceHealthGate = _gateStatus(traceHealth);
  final primaryGate = _gateStatus(primary);
  final guardrailGate = _gateStatus(guardrails);
  final decision = _overallDecision([
    traceHealthGate,
    primaryGate,
    guardrailGate,
  ]);

  return {
    'schema': benchmarkDecisionSchema,
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'decision': decision,
    if (baselinePath != null) 'baseline_path': baselinePath,
    if (candidatePath != null) 'candidate_path': candidatePath,
    'policy': options.toJson(),
    'gates': {
      'trace_health': {
        'status': traceHealthGate,
        'issues': traceHealth,
      },
      'primary': {
        'status': primaryGate,
        'comparisons': primary,
      },
      'guardrails': {
        'status': guardrailGate,
        'comparisons': guardrails,
      },
    },
    'scenario_count': commonScenarios.length,
  };
}

bool benchmarkDecisionPassed(Map<String, Object?> artifact) =>
    artifact['decision'] == 'accepted';

String benchmarkDecisionMarkdown(Map<String, Object?> artifact) {
  final policy = artifact['policy']! as Map<String, Object?>;
  final gates = artifact['gates']! as Map<String, Object?>;
  final traceHealth = gates['trace_health']! as Map<String, Object?>;
  final primary = gates['primary']! as Map<String, Object?>;
  final guardrails = gates['guardrails']! as Map<String, Object?>;
  final primaryComparisons =
      (primary['comparisons']! as List<Object?>).cast<Map<String, Object?>>();
  final guardrailComparisons = (guardrails['comparisons']! as List<Object?>)
      .cast<Map<String, Object?>>();
  final guardrailFindings = guardrailComparisons
      .where((comparison) => comparison['gate_effect'] != 'pass')
      .toList();
  final traceIssues =
      (traceHealth['issues']! as List<Object?>).cast<Map<String, Object?>>();

  final buffer = StringBuffer()
    ..writeln('# tracelite decision')
    ..writeln()
    ..writeln('Decision: `${artifact['decision']}`')
    ..writeln('Expectation: `${policy['expectation']}`')
    ..writeln('Primary: `${policy['primary_peer']}` '
        '`${policy['primary_metric']}`')
    ..writeln('Primary threshold: '
        '${_trimDouble(policy['primary_threshold_percent']! as double)}%')
    ..writeln('Max guardrail regression: '
        '${_trimDouble(policy['max_regression_percent']! as double)}%')
    ..writeln('Max CV: ${_trimDouble(policy['max_cv_percent']! as double)}%')
    ..writeln()
    ..writeln('## Gate Status')
    ..writeln()
    ..writeln('| gate | status |')
    ..writeln('|---|---|')
    ..writeln('| trace health | `${traceHealth['status']}` |')
    ..writeln('| primary | `${primary['status']}` |')
    ..writeln('| guardrails | `${guardrails['status']}` |');

  buffer
    ..writeln()
    ..writeln('## Primary')
    ..writeln()
    ..writeln(_comparisonTable(primaryComparisons));

  if (traceIssues.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Trace Health Findings')
      ..writeln()
      ..writeln('| scenario | peer | baseline | candidate | effect |')
      ..writeln('|---|---|---|---|---|');
    for (final issue in traceIssues) {
      buffer.writeln(
        '| `${issue['scenario']}` | `${issue['peer']}` | '
        '`${issue['baseline_status']}` | `${issue['candidate_status']}` | '
        '`${issue['gate_effect']}` |',
      );
    }
  }

  buffer
    ..writeln()
    ..writeln('## Guardrail Findings')
    ..writeln();
  if (guardrailFindings.isEmpty) {
    buffer.writeln('No failing or inconclusive guardrails.');
  } else {
    buffer.writeln(_comparisonTable(guardrailFindings));
  }

  return buffer.toString();
}

String _comparisonTable(List<Map<String, Object?>> comparisons) {
  final buffer = StringBuffer()
    ..writeln(
      '| scenario | peer | metric | baseline | candidate | change | '
      'max cv | p | verdict | effect |',
    )
    ..writeln('|---|---|---|---:|---:|---:|---:|---:|---|---|');
  for (final comparison in comparisons) {
    buffer.writeln(
      '| `${comparison['scenario']}` | `${comparison['peer']}` | '
      '`${comparison['metric']}` | '
      '${_formatMetricValue(
        comparison['metric']! as String,
        comparison['baseline_mean'] as double?,
      )} | '
      '${_formatMetricValue(
        comparison['metric']! as String,
        comparison['candidate_mean'] as double?,
      )} | '
      '${_formatPercent(comparison['change_percent'])} | '
      '${_formatPercent(comparison['max_cv_percent'])} | '
      '${_formatPValue(comparison)} | '
      '`${comparison['status']}` | `${comparison['gate_effect']}` |',
    );
  }
  return buffer.toString();
}

Map<String, Map<String, Object?>> _artifactsByScenario(
  List<Map<String, Object?>> artifacts,
) {
  return {
    for (final artifact in artifacts)
      if (artifact['scenario'] is String)
        artifact['scenario']! as String: artifact,
  };
}

List<String> _selectedValues({
  required List<String> requested,
  required List<String> available,
}) {
  if (requested.isEmpty) return available;
  final availableSet = available.toSet();
  return requested.where(availableSet.contains).toList()..sort();
}

Map<String, Map<String, Object?>> _peersByName(Map<String, Object?> artifact) {
  final peers = artifact['peers'];
  if (peers is! List<Object?>) return const {};
  return {
    for (final peer in peers.whereType<Map<String, Object?>>())
      if (peer['peer'] is String) peer['peer']! as String: peer,
  };
}

Map<String, Object?>? _traceHealthCheck({
  required String scenario,
  required String peer,
  required Map<String, Object?>? baselinePeer,
  required Map<String, Object?>? candidatePeer,
}) {
  final baselineStatus = baselinePeer?['status'] as String?;
  final candidateStatus = candidatePeer?['status'] as String?;
  if (baselineStatus == null || candidateStatus == null) {
    return {
      'scenario': scenario,
      'peer': peer,
      'baseline_status': baselineStatus ?? 'missing',
      'candidate_status': candidateStatus ?? 'missing',
      'gate_effect': 'reject',
    };
  }
  if (baselineStatus == 'unsupported' && candidateStatus == 'unsupported') {
    return null;
  }
  if (baselineStatus == 'ok' && candidateStatus == 'ok') return null;
  return {
    'scenario': scenario,
    'peer': peer,
    'baseline_status': baselineStatus,
    'candidate_status': candidateStatus,
    'gate_effect': 'reject',
  };
}

Map<String, Object?> _missingPrimaryComparison({
  required String scenario,
  required String peer,
  required String metric,
}) {
  return {
    'role': 'primary',
    'scenario': scenario,
    'peer': peer,
    'metric': metric,
    'status': 'missing_scenario',
    'baseline_status': 'missing',
    'candidate_status': 'missing',
    'baseline_samples': 0,
    'candidate_samples': 0,
    'gate_effect': 'inconclusive',
  };
}

Map<String, Object?> _compareMetric({
  required String role,
  required String scenario,
  required String peer,
  required String metric,
  required Map<String, Object?>? baselineArtifact,
  required Map<String, Object?>? candidateArtifact,
  required double thresholdPercent,
  required double maxCvPercent,
  required double alpha,
}) {
  final basePeer =
      baselineArtifact == null ? null : _peersByName(baselineArtifact)[peer];
  final candPeer =
      candidateArtifact == null ? null : _peersByName(candidateArtifact)[peer];
  final baseStatus = basePeer?['status'] as String?;
  final candStatus = candPeer?['status'] as String?;
  final baseSamples =
      basePeer == null ? const <int>[] : _sampleMetricValues(basePeer, metric);
  final candSamples =
      candPeer == null ? const <int>[] : _sampleMetricValues(candPeer, metric);
  final baseStats =
      baseSamples.isEmpty ? null : _IntStats.fromValues(baseSamples);
  final candStats =
      candSamples.isEmpty ? null : _IntStats.fromValues(candSamples);
  final maxCv = baseStats == null || candStats == null
      ? null
      : math.max(_cvPercent(baseStats), _cvPercent(candStats));
  final changePercent = baseStats == null || candStats == null
      ? null
      : _changePercent(baseStats.mean, candStats.mean);
  final ci = _meanDeltaConfidenceInterval(
    baselineSamples: baseSamples,
    candidateSamples: candSamples,
  );
  final nonParametric = _mannWhitneyTwoSided(
    baselineSamples: baseSamples,
    candidateSamples: candSamples,
  );

  final status = _changeStatus(
    baselineStatus: baseStatus,
    candidateStatus: candStatus,
    baselineSamples: baseSamples,
    candidateSamples: candSamples,
    changePercent: changePercent,
    maxCvPercent: maxCv,
    maxAllowedCvPercent: maxCvPercent,
    thresholdPercent: thresholdPercent,
    confidenceInterval: ci,
    nonParametric: nonParametric,
    alpha: alpha,
  );

  return {
    'role': role,
    'scenario': scenario,
    'peer': peer,
    'metric': metric,
    'status': status,
    'baseline_status': baseStatus ?? 'missing',
    'candidate_status': candStatus ?? 'missing',
    'baseline_samples': baseSamples.length,
    'candidate_samples': candSamples.length,
    if (baseStats != null) 'baseline_mean': baseStats.mean,
    if (candStats != null) 'candidate_mean': candStats.mean,
    if (baseStats != null && candStats != null)
      'delta': candStats.mean - baseStats.mean,
    if (changePercent != null) 'change_percent': changePercent,
    if (maxCv != null) 'max_cv_percent': maxCv,
    if (ci.available) ...{
      'delta_ci95_low': ci.lower,
      'delta_ci95_high': ci.upper,
    },
    if (nonParametric.available) ...{
      'nonparametric_p_value': nonParametric.pValue,
      'nonparametric_exact': nonParametric.exact,
    },
  };
}

String _changeStatus({
  required String? baselineStatus,
  required String? candidateStatus,
  required List<int> baselineSamples,
  required List<int> candidateSamples,
  required double? changePercent,
  required double? maxCvPercent,
  required double maxAllowedCvPercent,
  required double thresholdPercent,
  required _ConfidenceInterval confidenceInterval,
  required _MannWhitneyResult nonParametric,
  required double alpha,
}) {
  if (baselineStatus == 'unsupported' && candidateStatus == 'unsupported') {
    return 'unsupported';
  }
  if (baselineStatus != 'ok' || candidateStatus != 'ok') {
    return 'bad_status';
  }
  if (baselineSamples.isEmpty && candidateSamples.isEmpty) {
    return 'missing_metric';
  }
  if (baselineSamples.length < 2 || candidateSamples.length < 2) {
    return 'insufficient_samples';
  }
  if (changePercent == null) return 'missing_metric';
  if (maxCvPercent != null && maxCvPercent > maxAllowedCvPercent) {
    return 'too_noisy';
  }
  if (changePercent.abs() < thresholdPercent) {
    return 'neutral';
  }
  final statisticallyClear = confidenceInterval.excludesZero;
  final nonParametricClear = nonParametric.available &&
      nonParametric.pValue <= alpha &&
      nonParametric.directionMatches(changePercent);
  if (!statisticallyClear || !nonParametricClear) {
    return 'too_noisy';
  }
  return changePercent < 0 ? 'improved' : 'regressed';
}

String _primaryGateEffect(
  Map<String, Object?> comparison, {
  required String expectation,
}) {
  final status = comparison['status'];
  return switch (expectation) {
    'no_regression' => switch (status) {
        'improved' || 'neutral' => 'pass',
        'regressed' || 'bad_status' => 'reject',
        _ => 'inconclusive',
      },
    _ => switch (status) {
        'improved' => 'pass',
        'regressed' || 'bad_status' => 'reject',
        _ => 'inconclusive',
      },
  };
}

String _guardrailGateEffect(Map<String, Object?> comparison) {
  return switch (comparison['status']) {
    'improved' || 'neutral' => 'pass',
    'regressed' || 'bad_status' => 'reject',
    'missing_metric' || 'unsupported' => 'skip',
    _ => 'inconclusive',
  };
}

String _gateStatus(List<Map<String, Object?>> checks) {
  if (checks.any((check) => check['gate_effect'] == 'reject')) {
    return 'rejected';
  }
  if (checks.any((check) => check['gate_effect'] == 'inconclusive')) {
    return 'inconclusive';
  }
  return 'passed';
}

String _overallDecision(List<String> gateStatuses) {
  if (gateStatuses.contains('rejected')) return 'rejected';
  if (gateStatuses.contains('inconclusive')) return 'inconclusive';
  return 'accepted';
}

List<int> _sampleMetricValues(Map<String, Object?> peer, String metric) {
  final samples = peer['samples'];
  if (samples is! List<Object?>) return const [];
  return [
    for (final sampleObj in samples)
      if (sampleObj is Map<String, Object?> && sampleObj['status'] == 'ok')
        if (_sampleMetricValue(sampleObj, metric) case final value?) value,
  ];
}

int? _sampleMetricValue(Map<String, Object?> sample, String metric) {
  final direct = sample[metric];
  if (direct is int) return direct;

  final diagnostics = sample['diagnostics'];
  if (diagnostics is Map<String, Object?>) {
    final diagnostic = diagnostics[metric];
    if (diagnostic is int) return diagnostic;
  }

  final spanGroups = sample['span_groups'];
  if (spanGroups is List<Object?>) {
    if (metric == 'trace_span_total_ns') {
      var total = 0;
      for (final group in spanGroups) {
        if (group is Map<String, Object?> && group['total_ns'] is int) {
          total += group['total_ns']! as int;
        }
      }
      return total;
    }

    for (final group in spanGroups) {
      if (group is! Map<String, Object?>) continue;
      if (group['span_name'] != 'sqlite3_step') continue;
      return switch (metric) {
        'sqlite3_step_count' => group['count'] as int?,
        'sqlite3_step_total_ns' => group['total_ns'] as int?,
        _ => null,
      };
    }
  }

  return null;
}

double _changePercent(double baseline, double candidate) {
  if (baseline == 0) {
    if (candidate == 0) return 0;
    return candidate > 0 ? double.infinity : double.negativeInfinity;
  }
  return (candidate - baseline) / baseline * 100.0;
}

double _cvPercent(_IntStats stats) {
  if (stats.mean == 0) return 0;
  return stats.stddev / stats.mean * 100;
}

_ConfidenceInterval _meanDeltaConfidenceInterval({
  required List<int> baselineSamples,
  required List<int> candidateSamples,
}) {
  if (baselineSamples.length < 2 || candidateSamples.length < 2) {
    return const _ConfidenceInterval.unavailable();
  }

  final baseline = _DoubleSample.fromInts(baselineSamples);
  final candidate = _DoubleSample.fromInts(candidateSamples);
  final delta = candidate.mean - baseline.mean;
  final baselineTerm = baseline.variance / baseline.count;
  final candidateTerm = candidate.variance / candidate.count;
  final standardError = math.sqrt(baselineTerm + candidateTerm);
  if (standardError == 0) {
    return _ConfidenceInterval(lower: delta, upper: delta);
  }

  final numerator = math.pow(baselineTerm + candidateTerm, 2).toDouble();
  final denominator = math.pow(baselineTerm, 2) / (baseline.count - 1) +
      math.pow(candidateTerm, 2) / (candidate.count - 1);
  final degreesOfFreedom = denominator == 0 ? 1.0 : numerator / denominator;
  final margin = _tCritical95(degreesOfFreedom) * standardError;
  return _ConfidenceInterval(lower: delta - margin, upper: delta + margin);
}

_MannWhitneyResult _mannWhitneyTwoSided({
  required List<int> baselineSamples,
  required List<int> candidateSamples,
}) {
  if (baselineSamples.length < 3 || candidateSamples.length < 3) {
    return const _MannWhitneyResult.unavailable();
  }

  final combined = <_RankedValue>[
    for (final value in baselineSamples) _RankedValue(value, true),
    for (final value in candidateSamples) _RankedValue(value, false),
  ]..sort((a, b) => a.value.compareTo(b.value));

  final hasTies = _assignAverageRanks(combined);
  final baselineCount = baselineSamples.length;
  final candidateCount = candidateSamples.length;
  final baselineRankSum = combined
      .where((value) => value.isBaseline)
      .fold<double>(0, (sum, value) => sum + value.rank);
  final baselineU = baselineRankSum - baselineCount * (baselineCount + 1) / 2.0;
  final maxU = baselineCount * candidateCount.toDouble();
  final observedMinU = math.min(baselineU, maxU - baselineU);

  final exactPValue = hasTies
      ? null
      : _exactMannWhitneyTwoSidedPValue(
          totalCount: combined.length,
          baselineCount: baselineCount,
          observedMinU: observedMinU,
        );
  final pValue = exactPValue ??
      _approximateMannWhitneyTwoSidedPValue(
        u: baselineU,
        baselineCount: baselineCount,
        candidateCount: candidateCount,
      );
  final direction = candidateSamples.average - baselineSamples.average;
  return _MannWhitneyResult(
    pValue: pValue.clamp(0.0, 1.0).toDouble(),
    direction: direction,
    exact: exactPValue != null,
  );
}

bool _assignAverageRanks(List<_RankedValue> values) {
  var hasTies = false;
  var index = 0;
  while (index < values.length) {
    var end = index + 1;
    while (end < values.length && values[end].value == values[index].value) {
      end++;
    }
    if (end - index > 1) {
      hasTies = true;
    }
    final rank = (index + 1 + end) / 2.0;
    for (var i = index; i < end; i++) {
      values[i].rank = rank;
    }
    index = end;
  }
  return hasTies;
}

double? _exactMannWhitneyTwoSidedPValue({
  required int totalCount,
  required int baselineCount,
  required double observedMinU,
}) {
  final candidateCount = totalCount - baselineCount;
  final totalCombinations = _combinationCount(totalCount, baselineCount);
  if (totalCombinations > 1000000) return null;

  var extreme = 0;
  var combinations = 0;

  void visit(int nextRank, int chosen, int rankSum) {
    if (chosen == baselineCount) {
      combinations++;
      final u = rankSum - baselineCount * (baselineCount + 1) / 2.0;
      final minU = math.min(u, baselineCount * candidateCount - u);
      if (minU <= observedMinU + 1e-9) {
        extreme++;
      }
      return;
    }
    final remainingNeeded = baselineCount - chosen;
    for (var rank = nextRank;
        rank <= totalCount - remainingNeeded + 1;
        rank++) {
      visit(rank + 1, chosen + 1, rankSum + rank);
    }
  }

  visit(1, 0, 0);
  return combinations == 0 ? null : extreme / combinations;
}

int _combinationCount(int n, int k) {
  final r = math.min(k, n - k);
  var result = 1;
  for (var i = 1; i <= r; i++) {
    result = result * (n - r + i) ~/ i;
  }
  return result;
}

double _approximateMannWhitneyTwoSidedPValue({
  required double u,
  required int baselineCount,
  required int candidateCount,
}) {
  final mean = baselineCount * candidateCount / 2.0;
  final variance = baselineCount *
      candidateCount *
      (baselineCount + candidateCount + 1) /
      12.0;
  if (variance <= 0) return 1;
  final continuity = u > mean
      ? -0.5
      : u < mean
          ? 0.5
          : 0.0;
  final z = (u - mean + continuity) / math.sqrt(variance);
  final oneTail = math.min(_normalCdf(z), 1.0 - _normalCdf(z));
  return math.min(1.0, oneTail * 2.0);
}

double _normalCdf(double z) {
  final sign = z < 0 ? -1.0 : 1.0;
  final x = z.abs();
  final t = 1.0 / (1.0 + 0.2316419 * x);
  final y = 1.0 -
      0.3989422804014327 *
          math.exp(-x * x / 2.0) *
          t *
          (0.319381530 +
              t *
                  (-0.356563782 +
                      t *
                          (1.781477937 +
                              t * (-1.821255978 + 1.330274429 * t))));
  return sign == 1.0 ? y : 1.0 - y;
}

double _tCritical95(double degreesOfFreedom) {
  if (degreesOfFreedom >= 120) return 1.98;
  if (degreesOfFreedom >= 60) return 2.00;
  if (degreesOfFreedom >= 40) return 2.02;
  if (degreesOfFreedom >= 30) return 2.04;
  if (degreesOfFreedom >= 20) return 2.09;
  if (degreesOfFreedom >= 15) return 2.13;
  if (degreesOfFreedom >= 10) return 2.23;
  if (degreesOfFreedom >= 8) return 2.31;
  if (degreesOfFreedom >= 6) return 2.45;
  if (degreesOfFreedom >= 5) return 2.57;
  if (degreesOfFreedom >= 4) return 2.78;
  if (degreesOfFreedom >= 3) return 3.18;
  if (degreesOfFreedom >= 2) return 4.30;
  return 12.71;
}

String _formatMetricValue(String metric, double? value) {
  if (value == null) return '-';
  if (metric.endsWith('_ns')) {
    final rounded = value.round();
    if (rounded < 0) return '-${formatDurationNs(-rounded)}';
    return formatDurationNs(rounded);
  }
  return _trimDouble(value);
}

String _formatPercent(Object? value) {
  if (value is! num) return '-';
  if (!value.isFinite) return value.toString();
  return '${_trimDouble(value.toDouble())}%';
}

String _formatPValue(Map<String, Object?> comparison) {
  final pValue = comparison['nonparametric_p_value'];
  if (pValue is! num) return '-';
  final exact = comparison['nonparametric_exact'] == true;
  final prefix = exact ? '' : '~';
  if (pValue < 0.001) return '${prefix}<0.001';
  return '$prefix${_trimDouble(pValue.toDouble())}';
}

String _trimDouble(double value) {
  if (!value.isFinite) return value.toString();
  if (value.abs() >= 100) return value.toStringAsFixed(0);
  if (value.abs() >= 10) return value.toStringAsFixed(1);
  return value.toStringAsFixed(2);
}

final class _IntStats {
  _IntStats._({
    required this.mean,
    required this.stddev,
  });

  factory _IntStats.fromValues(List<int> values) {
    final mean =
        values.fold<double>(0, (sum, value) => sum + value) / values.length;
    final variance = values.fold<double>(
          0,
          (sum, value) => sum + math.pow(value - mean, 2),
        ) /
        values.length;
    return _IntStats._(
      mean: mean,
      stddev: math.sqrt(variance),
    );
  }

  final double mean;
  final double stddev;
}

final class _DoubleSample {
  _DoubleSample._({
    required this.count,
    required this.mean,
    required this.variance,
  });

  factory _DoubleSample.fromInts(List<int> values) {
    final count = values.length;
    final mean = values.fold<double>(0, (sum, value) => sum + value) / count;
    final variance = count < 2
        ? 0.0
        : values.fold<double>(
              0,
              (sum, value) => sum + math.pow(value - mean, 2),
            ) /
            (count - 1);
    return _DoubleSample._(
      count: count,
      mean: mean,
      variance: variance,
    );
  }

  final int count;
  final double mean;
  final double variance;
}

final class _ConfidenceInterval {
  const _ConfidenceInterval({
    required this.lower,
    required this.upper,
  }) : available = true;

  const _ConfidenceInterval.unavailable()
      : lower = 0,
        upper = 0,
        available = false;

  final double lower;
  final double upper;
  final bool available;

  bool get excludesZero => available && (upper < 0 || lower > 0);
}

final class _MannWhitneyResult {
  const _MannWhitneyResult({
    required this.pValue,
    required this.direction,
    required this.exact,
  }) : available = true;

  const _MannWhitneyResult.unavailable()
      : pValue = 1,
        direction = 0,
        exact = false,
        available = false;

  final double pValue;
  final double direction;
  final bool exact;
  final bool available;

  bool directionMatches(double meanChangePercent) {
    if (direction == 0 || meanChangePercent == 0) return false;
    return direction.sign == meanChangePercent.sign;
  }
}

final class _RankedValue {
  _RankedValue(this.value, this.isBaseline);

  final int value;
  final bool isBaseline;
  double rank = 0;
}

extension _AverageIntSamples on List<int> {
  double get average {
    if (isEmpty) return 0;
    return fold<double>(0, (sum, value) => sum + value) / length;
  }
}
