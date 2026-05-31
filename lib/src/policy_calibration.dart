import 'dart:math' as math;

const String benchmarkPolicyCalibrationSchema =
    'tracelite.policy_calibration.v1';

const List<String> defaultPolicyCalibrationMetrics = [
  'elapsed_ns',
  'measured_elapsed_ns',
  'sqlite3_step_total_ns',
  'trace_span_total_ns',
];
const double _outlierFenceMultiplier = 3;

final class BenchmarkPolicyCalibrationOptions {
  const BenchmarkPolicyCalibrationOptions({
    this.metrics = defaultPolicyCalibrationMetrics,
    this.scenarios = const [],
    this.peers = const [],
    this.minHistoryRuns = 2,
    this.minRepetitions = 5,
    this.maxRepetitions = 30,
    this.targetRelativeStandardErrorPercent = 2.5,
    this.withinRunNoisePercentile = 0.75,
    this.thresholdFloorPercent = 5,
    this.guardrailFloorPercent = 3,
    this.noiseGateFloorPercent = 5,
    this.noiseGateMultiplier = 1.5,
    this.maxOutlierPercent = 10,
    this.maxRunOutlierPercent = 20,
    this.thresholdCeilingPercent,
    this.guardrailCeilingPercent,
    this.noiseGateCeilingPercent,
  });

  final List<String> metrics;
  final List<String> scenarios;
  final List<String> peers;
  final int minHistoryRuns;
  final int minRepetitions;
  final int maxRepetitions;
  final double targetRelativeStandardErrorPercent;
  final double withinRunNoisePercentile;
  final double thresholdFloorPercent;
  final double guardrailFloorPercent;
  final double noiseGateFloorPercent;
  final double noiseGateMultiplier;
  final double maxOutlierPercent;
  final double maxRunOutlierPercent;
  final double? thresholdCeilingPercent;
  final double? guardrailCeilingPercent;
  final double? noiseGateCeilingPercent;

  Map<String, Object?> toJson() => {
        'metrics': metrics,
        'scenarios': scenarios,
        'peers': peers,
        'min_history_runs': minHistoryRuns,
        'min_repetitions': minRepetitions,
        'max_repetitions': maxRepetitions,
        'target_relative_standard_error_percent':
            targetRelativeStandardErrorPercent,
        'within_run_noise_percentile': withinRunNoisePercentile,
        'threshold_floor_percent': thresholdFloorPercent,
        'guardrail_floor_percent': guardrailFloorPercent,
        'noise_gate_floor_percent': noiseGateFloorPercent,
        'noise_gate_multiplier': noiseGateMultiplier,
        'max_outlier_percent': maxOutlierPercent,
        'max_run_outlier_percent': maxRunOutlierPercent,
        if (thresholdCeilingPercent != null)
          'threshold_ceiling_percent': thresholdCeilingPercent,
        if (guardrailCeilingPercent != null)
          'guardrail_ceiling_percent': guardrailCeilingPercent,
        if (noiseGateCeilingPercent != null)
          'noise_gate_ceiling_percent': noiseGateCeilingPercent,
      };
}

final class BenchmarkPolicyCalibrationInput {
  const BenchmarkPolicyCalibrationInput({
    required this.path,
    required this.artifact,
  });

  final String path;
  final Map<String, Object?> artifact;
}

Map<String, Object?> benchmarkPolicyCalibrationArtifact({
  required List<BenchmarkPolicyCalibrationInput> compareArtifacts,
  BenchmarkPolicyCalibrationOptions options =
      const BenchmarkPolicyCalibrationOptions(),
}) {
  final observations = <_CalibrationObservation>[];
  final sourcePaths = <String>{};

  for (final input in compareArtifacts) {
    final artifact = input.artifact;
    if (artifact['schema'] != 'tracelite.compare.v1') {
      throw FormatException(
        '${input.path} is not a tracelite compare artifact',
      );
    }
    sourcePaths.add(input.path);
    observations.addAll(_observationsForArtifact(input, options));
  }

  final grouped = <String, List<_CalibrationObservation>>{};
  for (final observation in observations) {
    grouped
        .putIfAbsent(observation.key, () => <_CalibrationObservation>[])
        .add(observation);
  }

  final groups = [
    for (final entry in grouped.entries)
      _calibratedGroup(entry.value, options).toJson(),
  ]..sort((a, b) {
      final scenario = (a['scenario']! as String).compareTo(
        b['scenario']! as String,
      );
      if (scenario != 0) return scenario;
      final peer = (a['peer']! as String).compareTo(b['peer']! as String);
      if (peer != 0) return peer;
      return (a['metric']! as String).compareTo(b['metric']! as String);
    });

  final coveredGroups =
      groups.where((group) => group['status'] != 'unsupported').toList();
  final readyGroups =
      coveredGroups.where((group) => group['status'] == 'ready').toList();
  final status = coveredGroups.isEmpty
      ? 'no_covered_groups'
      : readyGroups.length == coveredGroups.length
          ? 'ready'
          : coveredGroups.any(
              (group) =>
                  group['status'] == 'not_ready' ||
                  group['status'] == 'too_noisy',
            )
              ? 'not_ready'
              : 'needs_history';

  return {
    'schema': benchmarkPolicyCalibrationSchema,
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'status': status,
    'source_count': sourcePaths.length,
    'observation_count': observations.length,
    'covered_group_count': coveredGroups.length,
    'ready_group_count': readyGroups.length,
    'unsupported_group_count': groups.length - coveredGroups.length,
    'options': options.toJson(),
    'policy': _aggregatePolicy(coveredGroups, options),
    'groups': groups,
    'sources': sourcePaths.toList()..sort(),
  };
}

bool benchmarkPolicyCalibrationPassed(Map<String, Object?> artifact) =>
    artifact['status'] == 'ready';

String benchmarkPolicyCalibrationMarkdown(Map<String, Object?> artifact) {
  final policy = artifact['policy']! as Map<String, Object?>;
  final groups =
      (artifact['groups']! as List<Object?>).cast<Map<String, Object?>>();
  final coveredGroups =
      groups.where((group) => group['status'] != 'unsupported').toList();
  final findingCounts = <String, int>{};
  for (final group in coveredGroups) {
    for (final finding in (group['findings']! as List<Object?>)) {
      findingCounts.update(finding! as String, (count) => count + 1,
          ifAbsent: () => 1);
    }
  }

  final buffer = StringBuffer()
    ..writeln('# tracelite policy calibration')
    ..writeln()
    ..writeln('Status: `${artifact['status']}`')
    ..writeln('Sources: ${artifact['source_count']}')
    ..writeln('Covered groups: ${artifact['ready_group_count']}/'
        '${artifact['covered_group_count']} ready')
    ..writeln('Unsupported groups: ${artifact['unsupported_group_count']}')
    ..writeln()
    ..writeln('## Recommended Policy')
    ..writeln()
    ..writeln('| setting | value |')
    ..writeln('|---|---:|')
    ..writeln('| repetitions | ${policy['recommended_repetitions']} |')
    ..writeln('| primary threshold | '
        '${_formatPercent(policy['primary_threshold_percent'])} |')
    ..writeln('| guardrail regression | '
        '${_formatPercent(policy['max_regression_percent'])} |')
    ..writeln('| max CV | ${_formatPercent(policy['max_cv_percent'])} |');

  if (findingCounts.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Findings')
      ..writeln()
      ..writeln('| finding | groups |')
      ..writeln('|---|---:|');
    final entries = findingCounts.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in entries) {
      buffer.writeln('| `${entry.key}` | ${entry.value} |');
    }
  }

  buffer
    ..writeln()
    ..writeln('## Coverage Summary')
    ..writeln();
  _writeStatusSummary(buffer, groups, field: 'metric', title: 'By metric');
  buffer.writeln();
  _writeStatusSummary(buffer, groups, field: 'peer', title: 'By peer');

  buffer
    ..writeln()
    ..writeln('## Groups')
    ..writeln()
    ..writeln('| scenario | peer | metric | history | min reps | '
        'noise | threshold | max CV | outliers | status | findings |')
    ..writeln('|---|---|---|---:|---:|---:|---:|---:|---:|---|---|');

  for (final group in groups) {
    final findings = (group['findings']! as List<Object?>).cast<String>();
    buffer.writeln(
      '| `${group['scenario']}` | `${group['peer']}` | `${group['metric']}` | '
      '${group['history_runs']} | ${group['min_repetitions']} | '
      '${_formatPercent(group['observed_noise_percent'])} | '
      '${_formatPercent(group['primary_threshold_percent'])} | '
      '${_formatPercent(group['max_cv_percent'])} | '
      '${_formatPercent(group['outlier_percent'])} | '
      '`${group['status']}` | '
      '${findings.isEmpty ? '-' : findings.map((f) => '`$f`').join(', ')} |',
    );
  }

  return buffer.toString();
}

List<_CalibrationObservation> _observationsForArtifact(
  BenchmarkPolicyCalibrationInput input,
  BenchmarkPolicyCalibrationOptions options,
) {
  final artifact = input.artifact;
  final scenario = artifact['scenario'] as String? ?? '<unknown>';
  if (options.scenarios.isNotEmpty && !options.scenarios.contains(scenario)) {
    return const [];
  }
  final peers = artifact['peers'];
  if (peers is! List<Object?>) {
    throw FormatException('${input.path} has no peers list');
  }

  final observations = <_CalibrationObservation>[];
  for (final peerObj in peers) {
    if (peerObj is! Map<String, Object?>) continue;
    final peer = peerObj['peer'] as String? ?? '<unknown>';
    if (options.peers.isNotEmpty && !options.peers.contains(peer)) {
      continue;
    }
    final status = peerObj['status'] as String? ?? 'missing';
    for (final metric in options.metrics) {
      final values = _sampleMetricValues(peerObj, metric)
          .map((value) => value.toDouble())
          .toList();
      final stats =
          values.isEmpty ? null : _RobustDoubleStats.fromValues(values);
      observations.add(
        _CalibrationObservation(
          sourcePath: input.path,
          scenario: scenario,
          peer: peer,
          metric: metric,
          status: status,
          sampleCount: values.length,
          mean: stats?.mean,
          cvPercent: stats?.cvPercent,
          outlierCount: stats?.outlierCount ?? 0,
          outlierPercent: stats?.outlierPercent ?? 0,
        ),
      );
    }
  }
  return observations;
}

_CalibratedGroup _calibratedGroup(
  List<_CalibrationObservation> observations,
  BenchmarkPolicyCalibrationOptions options,
) {
  final first = observations.first;
  final valid = observations.where((observation) => observation.hasMetric);
  final validList = valid.toList();
  final findings = <String>{};
  final statuses =
      observations.map((observation) => observation.status).toSet();

  if (statuses.every((status) => status == 'unsupported')) {
    return _CalibratedGroup.unsupported(first);
  }
  if (statuses.any((status) => status != 'ok' && status != 'unsupported')) {
    findings.add('bad_status');
  }
  if (validList.isEmpty) {
    findings.add('missing_metric');
  }
  if (validList.length < options.minHistoryRuns) {
    findings.add('insufficient_history');
  }

  final sampleCounts = validList.map((observation) => observation.sampleCount);
  final minRepetitions =
      sampleCounts.isEmpty ? 0 : sampleCounts.reduce(math.min);
  if (minRepetitions < options.minRepetitions) {
    findings.add('insufficient_repetitions');
  }
  final totalSamples = validList.fold<int>(
    0,
    (total, observation) => total + observation.sampleCount,
  );
  final totalOutliers = validList.fold<int>(
    0,
    (total, observation) => total + observation.outlierCount,
  );
  final outlierPercent =
      totalSamples == 0 ? 0.0 : totalOutliers / totalSamples * 100;
  final maxRunOutlierPercent = validList.isEmpty
      ? 0.0
      : validList
          .map((observation) => observation.outlierPercent)
          .reduce(math.max);
  if (_exceeds(outlierPercent, options.maxOutlierPercent) ||
      _exceeds(maxRunOutlierPercent, options.maxRunOutlierPercent)) {
    findings.add('excessive_outliers');
  }

  final withinCv = [
    for (final observation in validList) observation.cvPercent ?? 0,
  ];
  final means = [
    for (final observation in validList) observation.mean ?? 0,
  ];
  final withinP90 = _percentile(withinCv, 0.90);
  final withinPercentile = _percentile(
    withinCv,
    options.withinRunNoisePercentile,
  );
  final runMeanCv =
      means.length < 2 ? 0.0 : _cvPercent(_DoubleStats.fromValues(means));
  final observedNoise = math.max(withinPercentile, runMeanCv);
  final estimatedRepetitions = _estimatedRepetitions(
    observedNoisePercent: observedNoise,
    options: options,
  );
  if (estimatedRepetitions > options.maxRepetitions) {
    findings.add('excessive_noise');
  }

  final recommendedRepetitions = math.max(
    options.minRepetitions,
    math.min(estimatedRepetitions, options.maxRepetitions),
  );
  final primaryThreshold = _roundUpHalf(
    math.max(options.thresholdFloorPercent, observedNoise * 2),
  );
  final guardrailThreshold = _roundUpHalf(
    math.max(options.guardrailFloorPercent, observedNoise * 1.5),
  );
  final maxCv = _roundUpHalf(
    math.max(
      options.noiseGateFloorPercent,
      observedNoise * options.noiseGateMultiplier,
    ),
  );
  if (_exceeds(primaryThreshold, options.thresholdCeilingPercent)) {
    findings.add('threshold_too_loose');
  }
  if (_exceeds(guardrailThreshold, options.guardrailCeilingPercent)) {
    findings.add('guardrail_too_loose');
  }
  if (_exceeds(maxCv, options.noiseGateCeilingPercent)) {
    findings.add('noise_gate_too_loose');
  }
  final status = findings.isEmpty
      ? 'ready'
      : findings.contains('bad_status') || findings.contains('missing_metric')
          ? 'not_ready'
          : findings.any(_isNoiseFinding)
              ? 'too_noisy'
              : 'needs_history';

  return _CalibratedGroup(
    scenario: first.scenario,
    peer: first.peer,
    metric: first.metric,
    status: status,
    findings: findings.toList()..sort(),
    historyRuns: validList.length,
    minRepetitions: minRepetitions,
    medianRepetitions:
        sampleCounts.isEmpty ? 0 : _medianInt(sampleCounts.toList()),
    observedWithinCvP90Percent: withinP90,
    observedWithinCvPercentile: withinPercentile,
    withinRunNoisePercentile: options.withinRunNoisePercentile,
    runMeanCvPercent: runMeanCv,
    observedNoisePercent: observedNoise,
    outlierCount: totalOutliers,
    sampleCount: totalSamples,
    outlierPercent: outlierPercent,
    maxRunOutlierPercent: maxRunOutlierPercent,
    recommendedRepetitions: recommendedRepetitions,
    estimatedRepetitions: estimatedRepetitions,
    primaryThresholdPercent: primaryThreshold,
    maxRegressionPercent: guardrailThreshold,
    maxCvPercent: maxCv,
  );
}

Map<String, Object?> _aggregatePolicy(
  List<Map<String, Object?>> groups,
  BenchmarkPolicyCalibrationOptions options,
) {
  final calibratable = groups.where((group) {
    final findings = (group['findings']! as List<Object?>).cast<String>();
    return group['history_runs'] != 0 &&
        !findings.contains('bad_status') &&
        !findings.contains('missing_metric');
  }).toList();
  if (calibratable.isEmpty) {
    return {
      'recommended_repetitions': options.minRepetitions,
      'primary_threshold_percent': options.thresholdFloorPercent,
      'max_regression_percent': options.guardrailFloorPercent,
      'max_cv_percent': options.noiseGateFloorPercent,
    };
  }

  int maxInt(String key) =>
      calibratable.map((group) => group[key]! as int).reduce(math.max);
  double maxDouble(String key) =>
      calibratable.map((group) => group[key]! as double).reduce(math.max);

  return {
    'recommended_repetitions': maxInt('recommended_repetitions'),
    'primary_threshold_percent': maxDouble('primary_threshold_percent'),
    'max_regression_percent': maxDouble('max_regression_percent'),
    'max_cv_percent': maxDouble('max_cv_percent'),
  };
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
  if (direct is num) return direct.round();

  final diagnostics = sample['diagnostics'];
  if (diagnostics is Map<String, Object?>) {
    final diagnostic = diagnostics[metric];
    if (diagnostic is int) return diagnostic;
    if (diagnostic is num) return diagnostic.round();
  }

  final spanGroups = sample['span_groups'];
  if (spanGroups is List<Object?>) {
    if (metric == 'trace_span_total_ns') {
      var total = 0;
      for (final group in spanGroups) {
        if (group is! Map<String, Object?>) continue;
        final value = group['total_ns'];
        if (value is int) total += value;
        if (value is num) total += value.round();
      }
      return total;
    }

    for (final group in spanGroups) {
      if (group is! Map<String, Object?>) continue;
      if (group['span_name'] != 'sqlite3_step') continue;
      return switch (metric) {
        'sqlite3_step_count' => _intValue(group['count']),
        'sqlite3_step_total_ns' => _intValue(group['total_ns']),
        _ => null,
      };
    }
  }

  return null;
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return null;
}

int _estimatedRepetitions({
  required double observedNoisePercent,
  required BenchmarkPolicyCalibrationOptions options,
}) {
  if (observedNoisePercent <= 0) return options.minRepetitions;
  final target = options.targetRelativeStandardErrorPercent;
  if (target <= 0) return options.maxRepetitions;
  return math.max(
    options.minRepetitions,
    math.pow(observedNoisePercent / target, 2).ceil(),
  );
}

double _cvPercent(_DoubleStats stats) {
  if (stats.mean == 0) return 0;
  return stats.stddev / stats.mean.abs() * 100;
}

double _percentile(List<double> values, double percentile) {
  if (values.isEmpty) return 0;
  final sorted = values.toList()..sort();
  final rank = ((sorted.length - 1) * percentile).ceil();
  return sorted[rank.clamp(0, sorted.length - 1)];
}

double _percentileInterpolated(List<double> sortedValues, double percentile) {
  if (sortedValues.isEmpty) return 0;
  if (sortedValues.length == 1) return sortedValues.single;
  final position = (sortedValues.length - 1) * percentile;
  final lower = position.floor();
  final upper = position.ceil();
  if (lower == upper) return sortedValues[lower];
  final fraction = position - lower;
  return sortedValues[lower] +
      (sortedValues[upper] - sortedValues[lower]) * fraction;
}

List<double> _withoutTukeyOutliers(List<double> values) {
  if (values.length < 7) return values;
  final sorted = values.toList()..sort();
  final q1 = _percentileInterpolated(sorted, 0.25);
  final q3 = _percentileInterpolated(sorted, 0.75);
  final iqr = q3 - q1;
  if (iqr <= 0) return values;
  final lower = q1 - _outlierFenceMultiplier * iqr;
  final upper = q3 + _outlierFenceMultiplier * iqr;
  final clean = values
      .where((value) => value >= lower && value <= upper)
      .toList(growable: false);
  return clean.length >= 2 ? clean : values;
}

int _medianInt(List<int> values) {
  if (values.isEmpty) return 0;
  final sorted = values.toList()..sort();
  return sorted[sorted.length ~/ 2];
}

double _roundUpHalf(double value) => (value * 2).ceil() / 2;

bool _exceeds(double value, double? ceiling) =>
    ceiling != null && value > ceiling;

bool _isNoiseFinding(String finding) {
  return finding == 'excessive_noise' ||
      finding == 'excessive_outliers' ||
      finding == 'threshold_too_loose' ||
      finding == 'guardrail_too_loose' ||
      finding == 'noise_gate_too_loose';
}

void _writeStatusSummary(
  StringBuffer buffer,
  List<Map<String, Object?>> groups, {
  required String field,
  required String title,
}) {
  const statuses = [
    'ready',
    'too_noisy',
    'needs_history',
    'not_ready',
    'unsupported',
  ];
  final rows = <String, Map<String, int>>{};
  for (final group in groups) {
    final name = group[field] as String? ?? '<unknown>';
    final status = group['status'] as String? ?? 'not_ready';
    final counts = rows.putIfAbsent(name, () => <String, int>{});
    counts.update(status, (value) => value + 1, ifAbsent: () => 1);
  }

  buffer
    ..writeln('### $title')
    ..writeln()
    ..writeln('| $field | ready | too noisy | needs history | not ready | '
        'unsupported |')
    ..writeln('|---|---:|---:|---:|---:|---:|');
  final names = rows.keys.toList()..sort();
  for (final name in names) {
    final counts = rows[name]!;
    buffer.writeln(
      '| `$name` | ${counts[statuses[0]] ?? 0} | '
      '${counts[statuses[1]] ?? 0} | ${counts[statuses[2]] ?? 0} | '
      '${counts[statuses[3]] ?? 0} | ${counts[statuses[4]] ?? 0} |',
    );
  }
}

String _formatPercent(Object? value) {
  if (value is! num) return '-';
  return '${_trimDouble(value.toDouble())}%';
}

String _trimDouble(double value) {
  if (value.isInfinite) return value.isNegative ? '-inf' : 'inf';
  if (value.isNaN) return 'nan';
  final fixed = value.toStringAsFixed(2);
  return fixed
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

final class _CalibrationObservation {
  const _CalibrationObservation({
    required this.sourcePath,
    required this.scenario,
    required this.peer,
    required this.metric,
    required this.status,
    required this.sampleCount,
    required this.mean,
    required this.cvPercent,
    required this.outlierCount,
    required this.outlierPercent,
  });

  final String sourcePath;
  final String scenario;
  final String peer;
  final String metric;
  final String status;
  final int sampleCount;
  final double? mean;
  final double? cvPercent;
  final int outlierCount;
  final double outlierPercent;

  String get key => '$scenario\u0000$peer\u0000$metric';
  bool get hasMetric => sampleCount > 0 && mean != null && cvPercent != null;
}

final class _CalibratedGroup {
  const _CalibratedGroup({
    required this.scenario,
    required this.peer,
    required this.metric,
    required this.status,
    required this.findings,
    required this.historyRuns,
    required this.minRepetitions,
    required this.medianRepetitions,
    required this.observedWithinCvP90Percent,
    required this.observedWithinCvPercentile,
    required this.withinRunNoisePercentile,
    required this.runMeanCvPercent,
    required this.observedNoisePercent,
    required this.outlierCount,
    required this.sampleCount,
    required this.outlierPercent,
    required this.maxRunOutlierPercent,
    required this.recommendedRepetitions,
    required this.estimatedRepetitions,
    required this.primaryThresholdPercent,
    required this.maxRegressionPercent,
    required this.maxCvPercent,
  });

  factory _CalibratedGroup.unsupported(_CalibrationObservation observation) {
    return _CalibratedGroup(
      scenario: observation.scenario,
      peer: observation.peer,
      metric: observation.metric,
      status: 'unsupported',
      findings: const ['unsupported'],
      historyRuns: 0,
      minRepetitions: 0,
      medianRepetitions: 0,
      observedWithinCvP90Percent: 0,
      observedWithinCvPercentile: 0,
      withinRunNoisePercentile: 0,
      runMeanCvPercent: 0,
      observedNoisePercent: 0,
      outlierCount: 0,
      sampleCount: 0,
      outlierPercent: 0,
      maxRunOutlierPercent: 0,
      recommendedRepetitions: 0,
      estimatedRepetitions: 0,
      primaryThresholdPercent: 0,
      maxRegressionPercent: 0,
      maxCvPercent: 0,
    );
  }

  final String scenario;
  final String peer;
  final String metric;
  final String status;
  final List<String> findings;
  final int historyRuns;
  final int minRepetitions;
  final int medianRepetitions;
  final double observedWithinCvP90Percent;
  final double observedWithinCvPercentile;
  final double withinRunNoisePercentile;
  final double runMeanCvPercent;
  final double observedNoisePercent;
  final int outlierCount;
  final int sampleCount;
  final double outlierPercent;
  final double maxRunOutlierPercent;
  final int recommendedRepetitions;
  final int estimatedRepetitions;
  final double primaryThresholdPercent;
  final double maxRegressionPercent;
  final double maxCvPercent;

  Map<String, Object?> toJson() => {
        'scenario': scenario,
        'peer': peer,
        'metric': metric,
        'status': status,
        'findings': findings,
        'history_runs': historyRuns,
        'min_repetitions': minRepetitions,
        'median_repetitions': medianRepetitions,
        'observed_within_cv_p90_percent': observedWithinCvP90Percent,
        'observed_within_cv_percentile': withinRunNoisePercentile,
        'observed_within_cv_percentile_percent': observedWithinCvPercentile,
        'run_mean_cv_percent': runMeanCvPercent,
        'observed_noise_percent': observedNoisePercent,
        'outlier_count': outlierCount,
        'sample_count': sampleCount,
        'outlier_percent': outlierPercent,
        'max_run_outlier_percent': maxRunOutlierPercent,
        'estimated_repetitions': estimatedRepetitions,
        'recommended_repetitions': recommendedRepetitions,
        'primary_threshold_percent': primaryThresholdPercent,
        'max_regression_percent': maxRegressionPercent,
        'max_cv_percent': maxCvPercent,
      };
}

final class _DoubleStats {
  const _DoubleStats({
    required this.count,
    required this.mean,
    required this.stddev,
  });

  factory _DoubleStats.fromValues(List<double> values) {
    if (values.isEmpty) {
      return const _DoubleStats(count: 0, mean: 0, stddev: 0);
    }
    final total = values.fold<double>(0, (sum, value) => sum + value);
    final mean = total / values.length;
    final variance = values.fold<double>(
          0,
          (sum, value) => sum + (value - mean) * (value - mean),
        ) /
        values.length;
    return _DoubleStats(
      count: values.length,
      mean: mean,
      stddev: math.sqrt(variance),
    );
  }

  final int count;
  final double mean;
  final double stddev;
}

final class _RobustDoubleStats {
  _RobustDoubleStats._({
    required this.mean,
    required this.cvPercent,
    required this.outlierCount,
    required this.outlierPercent,
  });

  factory _RobustDoubleStats.fromValues(List<double> values) {
    final cleanValues = _withoutTukeyOutliers(values);
    final stats = _DoubleStats.fromValues(cleanValues);
    final outlierCount = values.length - cleanValues.length;
    return _RobustDoubleStats._(
      mean: stats.mean,
      cvPercent: _cvPercent(stats),
      outlierCount: outlierCount,
      outlierPercent: values.isEmpty ? 0 : outlierCount / values.length * 100,
    );
  }

  final double mean;
  final double cvPercent;
  final int outlierCount;
  final double outlierPercent;
}
