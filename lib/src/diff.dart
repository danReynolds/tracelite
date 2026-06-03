import 'dart:math' as math;

import 'trace.dart';

const String benchmarkDiffSchema = 'tracelite.diff.v1';

final class BenchmarkDiffOptions {
  const BenchmarkDiffOptions({
    this.metric = 'elapsed_ns',
    this.thresholdPercent = 5,
    this.maxCvPercent = 15,
    this.alpha = 0.05,
  });

  final String metric;
  final double thresholdPercent;
  final double maxCvPercent;
  final double alpha;

  Map<String, Object?> toJson() => {
        'metric': metric,
        'threshold_percent': thresholdPercent,
        'max_cv_percent': maxCvPercent,
        'alpha': alpha,
      };
}

Map<String, Object?> benchmarkDiffArtifact({
  required Map<String, Object?> baselineArtifact,
  required Map<String, Object?> candidateArtifact,
  required BenchmarkDiffOptions options,
  String? baselinePath,
  String? candidatePath,
}) {
  final baselinePeers = _peersByName(baselineArtifact);
  final candidatePeers = _peersByName(candidateArtifact);
  final names = baselinePeers.keys.where(candidatePeers.containsKey).toList()
    ..sort();

  return {
    'schema': benchmarkDiffSchema,
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    if (baselinePath != null) 'baseline_path': baselinePath,
    if (candidatePath != null) 'candidate_path': candidatePath,
    'policy': options.toJson(),
    'comparisons': [
      for (final name in names)
        _diffComparison(
          name,
          baselinePeers[name]!,
          candidatePeers[name]!,
          options,
        ),
    ],
  };
}

String benchmarkDiffMarkdown(Map<String, Object?> artifact) {
  if (artifact['schema'] != benchmarkDiffSchema) {
    throw const FormatException('not a tracelite diff artifact');
  }
  final policy = artifact['policy']! as Map<String, Object?>;
  final metric = policy['metric']! as String;
  final comparisons =
      (artifact['comparisons']! as List<Object?>).cast<Map<String, Object?>>();

  final buffer = StringBuffer()
    ..writeln('# tracelite diff')
    ..writeln()
    ..writeln('Metric: `$metric`')
    ..writeln('Threshold: ${_trimDouble(policy['threshold_percent']! as num)}%')
    ..writeln('Max CV: ${_trimDouble(policy['max_cv_percent']! as num)}%')
    ..writeln('Alpha: ${_trimDouble(policy['alpha']! as num)}')
    ..writeln()
    ..writeln(
      '| peer | samples | baseline mean | candidate mean | delta | '
      'delta 95% CI | nonparam p | outliers | change | max cv | verdict |',
    )
    ..writeln('|---|---:|---:|---:|---:|---:|---:|---:|---:|---|');

  for (final comparison in comparisons) {
    final confidenceInterval =
        comparison['confidence_interval']! as Map<String, Object?>;
    final nonParametric = comparison['non_parametric']! as Map<String, Object?>;
    final outliers = comparison['outliers']! as Map<String, Object?>;
    buffer.writeln(
      '| `${comparison['peer']}` | '
      '${comparison['baseline_samples']}/${comparison['candidate_samples']} | '
      '${_formatMetricValue(metric, comparison['baseline_mean']! as num)} | '
      '${_formatMetricValue(metric, comparison['candidate_mean']! as num)} | '
      '${_formatMetricValue(metric, comparison['delta']! as num)} | '
      '${_formatConfidenceInterval(metric, confidenceInterval)} | '
      '${_formatPValue(nonParametric)} | '
      '${outliers['baseline']}/${outliers['candidate']} | '
      '${_trimDouble(comparison['change_percent']! as num)}% | '
      '${_trimDouble(comparison['max_cv_percent']! as num)}% | '
      '${comparison['verdict']} |',
    );
  }
  return buffer.toString();
}

Map<String, Object?> _diffComparison(
  String name,
  Map<String, Object?> baselinePeer,
  Map<String, Object?> candidatePeer,
  BenchmarkDiffOptions options,
) {
  final baselineMetric =
      _metric(baselinePeer['summary']! as Map<String, Object?>, options.metric);
  final candidateMetric = _metric(
    candidatePeer['summary']! as Map<String, Object?>,
    options.metric,
  );
  final baselineSamples = _sampleMetricValues(baselinePeer, options.metric);
  final candidateSamples = _sampleMetricValues(candidatePeer, options.metric);
  final delta = candidateMetric.mean - baselineMetric.mean;
  final change =
      baselineMetric.mean == 0 ? 0.0 : delta / baselineMetric.mean * 100.0;
  final baselineCv = _cvPercent(baselineMetric);
  final candidateCv = _cvPercent(candidateMetric);
  final maxCv = math.max(baselineCv, candidateCv);
  final ci = _meanDeltaConfidenceInterval(
    baselineSamples: baselineSamples,
    candidateSamples: candidateSamples,
  );
  final nonParametric = _mannWhitneyTwoSided(
    baselineSamples: baselineSamples,
    candidateSamples: candidateSamples,
  );
  final outliers = _outlierSummary(
    baselineSamples: baselineSamples,
    candidateSamples: candidateSamples,
  );
  final hasSamples =
      baselineSamples.length >= 2 && candidateSamples.length >= 2;
  final statisticallyClear = ci.excludesZero;
  final nonParametricClear = nonParametric.available &&
      nonParametric.pValue <= options.alpha &&
      nonParametric.directionMatches(change);
  final verdict = !hasSamples
      ? 'insufficient_samples'
      : maxCv > options.maxCvPercent
          ? 'too_noisy'
          : change.abs() < options.thresholdPercent
              ? 'neutral'
              : !statisticallyClear || !nonParametricClear
                  ? 'too_noisy'
                  : change < 0
                      ? 'improved'
                      : 'regressed';

  return {
    'peer': name,
    'baseline_samples': baselineSamples.length,
    'candidate_samples': candidateSamples.length,
    'baseline_mean': baselineMetric.mean,
    'candidate_mean': candidateMetric.mean,
    'delta': delta,
    'confidence_interval': ci.toJson(),
    'non_parametric': nonParametric.toJson(),
    'outliers': outliers.toJson(),
    'change_percent': change,
    'max_cv_percent': maxCv,
    'verdict': verdict,
  };
}

Map<String, Map<String, Object?>> _peersByName(Map<String, Object?> artifact) {
  final peers = artifact['peers'];
  if (peers is! List<Object?>) {
    throw const FormatException('artifact has no peers list');
  }
  return {
    for (final peer in peers.cast<Map<String, Object?>>())
      peer['peer']! as String: peer,
  };
}

_IntStats _metric(Map<String, Object?> summary, String metric) {
  final value = summary[metric];
  if (value is! Map<String, Object?>) {
    throw ArgumentError.value(metric, 'metric', 'not present in summary');
  }
  return _IntStats.fromJson(value);
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

_OutlierSummary _outlierSummary({
  required List<int> baselineSamples,
  required List<int> candidateSamples,
}) {
  return _OutlierSummary(
    baseline: _tukeyOutlierCount(baselineSamples),
    candidate: _tukeyOutlierCount(candidateSamples),
  );
}

int _tukeyOutlierCount(List<int> samples) {
  if (samples.length < 4) return 0;
  final sorted = samples.toList()..sort();
  final q1 = _percentileInterpolated(sorted, 0.25);
  final q3 = _percentileInterpolated(sorted, 0.75);
  final iqr = q3 - q1;
  if (iqr == 0) return 0;
  final low = q1 - 1.5 * iqr;
  final high = q3 + 1.5 * iqr;
  return sorted.where((value) => value < low || value > high).length;
}

double _percentileInterpolated(List<int> values, double percentile) {
  if (values.isEmpty) return 0;
  final position = (values.length - 1) * percentile;
  final lower = position.floor();
  final upper = position.ceil();
  if (lower == upper) return values[lower].toDouble();
  final weight = position - lower;
  return values[lower] * (1 - weight) + values[upper] * weight;
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

double _cvPercent(_IntStats stats) {
  if (stats.mean == 0) return 0;
  return stats.stddev / stats.mean * 100;
}

String _formatMetricValue(String metric, num value) {
  if (metric.endsWith('_ns')) {
    final rounded = value.round();
    if (rounded < 0) return '-${formatDurationNs(-rounded)}';
    return formatDurationNs(rounded);
  }
  return _trimDouble(value);
}

String _formatConfidenceInterval(
  String metric,
  Map<String, Object?> interval,
) {
  if (interval['available'] != true) return '-';
  return '[${_formatMetricValue(metric, interval['lower']! as num)}, '
      '${_formatMetricValue(metric, interval['upper']! as num)}]';
}

String _formatPValue(Map<String, Object?> result) {
  if (result['available'] != true) return '-';
  final prefix = result['exact'] == true ? '' : '~';
  final pValue = result['p_value']! as num;
  if (pValue < 0.001) return '${prefix}<0.001';
  return '$prefix${_trimDouble(pValue)}';
}

String _trimDouble(num value) {
  final asDouble = value.toDouble();
  if (!asDouble.isFinite) return asDouble.toString();
  if (asDouble.abs() >= 100) return asDouble.toStringAsFixed(0);
  if (asDouble.abs() >= 10) return asDouble.toStringAsFixed(1);
  return asDouble.toStringAsFixed(2);
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

  Map<String, Object?> toJson() => {
        'available': available,
        if (available) ...{
          'lower': lower,
          'upper': upper,
        },
      };
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

  Map<String, Object?> toJson() => {
        'available': available,
        if (available) ...{
          'p_value': pValue,
          'direction': direction,
          'exact': exact,
        },
      };
}

final class _OutlierSummary {
  const _OutlierSummary({
    required this.baseline,
    required this.candidate,
  });

  final int baseline;
  final int candidate;

  Map<String, Object?> toJson() => {
        'baseline': baseline,
        'candidate': candidate,
      };
}

final class _RankedValue {
  _RankedValue(this.value, this.isBaseline);

  final int value;
  final bool isBaseline;
  double rank = 0;
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

final class _IntStats {
  _IntStats._({
    required this.count,
    required this.total,
    required this.min,
    required this.max,
    required this.mean,
    required this.median,
    required this.p90,
    required this.p99,
    required this.stddev,
  });

  factory _IntStats.fromJson(Map<String, Object?> json) {
    return _IntStats._(
      count: json['count']! as int,
      total: json['total']! as int,
      min: json['min']! as int,
      max: json['max']! as int,
      mean: (json['mean']! as num).toDouble(),
      median: json['median']! as int,
      p90: json['p90']! as int,
      p99: json['p99']! as int,
      stddev: (json['stddev']! as num).toDouble(),
    );
  }

  final int count;
  final int total;
  final int min;
  final int max;
  final double mean;
  final int median;
  final int p90;
  final int p99;
  final double stddev;
}

extension _AverageIntSamples on List<int> {
  double get average {
    if (isEmpty) return 0;
    return fold<double>(0, (sum, value) => sum + value) / length;
  }
}
