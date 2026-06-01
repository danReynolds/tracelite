import 'dart:math' as math;

import 'trace.dart';

const String benchmarkInsightsSchema = 'tracelite.insights.v1';

final class BenchmarkInsightOptions {
  const BenchmarkInsightOptions({
    this.maxCvPercent = 15,
    this.bottleneckSharePercent = 55,
    this.traceCoverageFloorPercent = 25,
    this.peerSpreadPercent = 20,
    this.harnessOverheadPercent = 300,
    this.harnessOverheadFloorNs = 50000000,
  });

  final double maxCvPercent;
  final double bottleneckSharePercent;
  final double traceCoverageFloorPercent;
  final double peerSpreadPercent;
  final double harnessOverheadPercent;
  final int harnessOverheadFloorNs;
}

final class BenchmarkInsight {
  const BenchmarkInsight({
    required this.severity,
    required this.id,
    required this.title,
    required this.body,
    this.evidence = const {},
  });

  final String severity;
  final String id;
  final String title;
  final String body;
  final Map<String, Object?> evidence;

  Map<String, Object?> toJson() => {
        'severity': severity,
        'id': id,
        'title': title,
        'body': body,
        if (evidence.isNotEmpty) 'evidence': evidence,
      };
}

List<BenchmarkInsight> benchmarkArtifactInsights(
  Map<String, Object?> artifact, {
  BenchmarkInsightOptions options = const BenchmarkInsightOptions(),
}) {
  final insights = switch (artifact['schema']) {
    'tracelite.compare.v1' => _compareInsights(artifact, options),
    'tracelite.decision.v1' => _decisionInsights(artifact, options),
    'tracelite.diff.v1' => _diffInsights(artifact, options),
    'tracelite.workload_summary.v1' => _workloadInsights(artifact),
    'tracelite.suite.v1' => _suiteInsights(artifact),
    'tracelite.suite_history.v1' => _suiteHistoryInsights(artifact),
    _ => <BenchmarkInsight>[
        BenchmarkInsight(
          severity: 'warning',
          id: 'unsupported_artifact',
          title: 'Unsupported artifact',
          body: 'No insight rules exist for schema `${artifact['schema']}`.',
        ),
      ],
  };
  return insights..sort(_compareInsightPriority);
}

String benchmarkArtifactInsightsMarkdown(
  Map<String, Object?> artifact, {
  BenchmarkInsightOptions options = const BenchmarkInsightOptions(),
  String heading = '## Insights',
}) {
  final insights = benchmarkArtifactInsights(artifact, options: options);
  final buffer = StringBuffer()
    ..writeln(heading)
    ..writeln()
    ..writeln('| severity | finding | detail |')
    ..writeln('|---|---|---|');
  for (final insight in insights) {
    buffer.writeln(
      '| `${insight.severity}` | ${_markdownCell(insight.title)} | '
      '${_markdownCell(insight.body)} |',
    );
  }
  return buffer.toString();
}

List<BenchmarkInsight> _compareInsights(
  Map<String, Object?> artifact,
  BenchmarkInsightOptions options,
) {
  final scenario = _string(artifact['scenario']) ?? 'unknown';
  final peers = _listOfMaps(artifact['peers']);
  if (peers.isEmpty) {
    return [
      const BenchmarkInsight(
        severity: 'critical',
        id: 'compare_no_peers',
        title: 'No peer data',
        body: 'The compare artifact has no peer rows to interpret.',
      ),
    ];
  }

  final insights = <BenchmarkInsight>[];
  final unsupported = <String>[];
  final badStatus = <String>[];
  final noisy = <String>[];
  final unhealthy = <String>[];
  final measuredMeans = <String, double>{};

  for (final peer in peers) {
    final name = _string(peer['peer']) ?? 'unknown';
    final status = _string(peer['status']) ?? 'unknown';
    if (status == 'unsupported') {
      unsupported.add(name);
      continue;
    }
    if (status != 'ok') badStatus.add('$name:$status');

    final healthMax = _traceHealthMax(peer);
    if (healthMax > 0) unhealthy.add('$name:$healthMax');

    final measured = _metricMean(peer, 'measured_elapsed_ns') ??
        _metricMean(peer, 'elapsed_ns');
    if (measured != null && measured > 0) {
      measuredMeans[name] = measured;
      final cv = _metricCv(peer, 'measured_elapsed_ns') ??
          _metricCv(peer, 'elapsed_ns');
      if (cv != null && cv > options.maxCvPercent) {
        noisy.add('$name ${_formatPercent(cv)}%');
      }
      insights.addAll(_peerBottleneckInsights(
        scenario: scenario,
        peer: name,
        measuredMeanNs: measured,
        peerArtifact: peer,
        options: options,
      ));
      final childMean = _metricMean(peer, 'child_elapsed_ns');
      if (childMean != null) {
        final overheadNs = math.max(0, childMean - measured);
        final overheadPercent = (overheadNs / measured) * 100;
        if (overheadNs >= options.harnessOverheadFloorNs &&
            overheadPercent >= options.harnessOverheadPercent) {
          insights.add(BenchmarkInsight(
            severity: 'warning',
            id: 'harness_overhead_dominates',
            title: '$name run is harness dominated',
            body:
                'Child-process wall time is ${formatDurationNs(childMean.round())} while measured workload time is ${formatDurationNs(measured.round())}; use larger workloads or repeated suite profiles before making a production decision from this artifact.',
            evidence: {
              'peer': name,
              'scenario': scenario,
              'child_elapsed_ns_mean': childMean,
              'measured_elapsed_ns_mean': measured,
              'harness_overhead_percent': overheadPercent,
            },
          ));
        }
      }
    }
  }

  if (badStatus.isNotEmpty) {
    insights.add(BenchmarkInsight(
      severity: 'critical',
      id: 'compare_bad_status',
      title: 'Some peers are not trustworthy',
      body: 'Peers finished with non-ok status: ${badStatus.join(', ')}.',
      evidence: {'peers': badStatus},
    ));
  }
  if (unhealthy.isNotEmpty) {
    insights.add(BenchmarkInsight(
      severity: 'critical',
      id: 'compare_trace_health',
      title: 'Trace health failed',
      body:
          'Dropped or unmatched events were reported: ${unhealthy.join(', ')}.',
      evidence: {'peers': unhealthy},
    ));
  }
  if (noisy.isNotEmpty) {
    insights.add(BenchmarkInsight(
      severity: 'warning',
      id: 'compare_noisy_measurements',
      title: 'Measured timing is noisy',
      body:
          'Measured elapsed CV exceeds ${_formatPercent(options.maxCvPercent)}% for ${noisy.join(', ')}.',
      evidence: {'peers': noisy},
    ));
  }
  if (unsupported.isNotEmpty) {
    insights.add(BenchmarkInsight(
      severity: 'info',
      id: 'compare_unsupported_peers',
      title: 'Capability lane is partial',
      body: 'Unsupported peers were skipped: ${unsupported.join(', ')}.',
      evidence: {'peers': unsupported},
    ));
  }

  if (measuredMeans.length >= 2) {
    final entries = measuredMeans.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final fastest = entries.first;
    final slowest = entries.last;
    final spread = fastest.value <= 0
        ? 0.0
        : ((slowest.value - fastest.value) / fastest.value) * 100;
    if (spread >= options.peerSpreadPercent) {
      insights.add(BenchmarkInsight(
        severity: 'info',
        id: 'compare_peer_spread',
        title: 'Peers differ materially',
        body:
            '`${fastest.key}` is fastest at ${formatDurationNs(fastest.value.round())}; `${slowest.key}` is slowest at ${formatDurationNs(slowest.value.round())} (${_formatPercent(spread)}% spread).',
        evidence: {
          'fastest_peer': fastest.key,
          'slowest_peer': slowest.key,
          'spread_percent': spread,
        },
      ));
    }
  }

  if (insights.isEmpty) {
    insights.add(BenchmarkInsight(
      severity: 'good',
      id: 'compare_clean',
      title: 'Compare artifact is interpretable',
      body:
          'All supported peers are ok, trace health is clean, and measured timing is under the configured CV gate.',
    ));
  }
  return insights;
}

List<BenchmarkInsight> _peerBottleneckInsights({
  required String scenario,
  required String peer,
  required double measuredMeanNs,
  required Map<String, Object?> peerArtifact,
  required BenchmarkInsightOptions options,
}) {
  final sqliteMean = _metricMean(peerArtifact, 'sqlite3_step_total_ns') ?? 0;
  final tracedMean = _metricMean(peerArtifact, 'trace_span_total_ns') ?? 0;
  final stepCount = _metricMean(peerArtifact, 'sqlite3_step_count');
  final sqliteShare = (sqliteMean / measuredMeanNs) * 100;
  final tracedShare = (tracedMean / measuredMeanNs) * 100;
  final nonStepShare =
      (math.max(0, tracedMean - sqliteMean) / measuredMeanNs) * 100;
  final topSpan = _topSpanGroup(peerArtifact);

  final detail = [
    'measured ${formatDurationNs(measuredMeanNs.round())}',
    if (stepCount != null) 'sqlite3_step ${_formatCount(stepCount)} calls',
    if (topSpan != null)
      'top span `${topSpan.name}` ${formatDurationNs(topSpan.totalMeanNs.round())}',
  ].join(', ');

  if (sqliteShare >= options.bottleneckSharePercent) {
    return [
      BenchmarkInsight(
        severity: 'info',
        id: 'sqlite_dominated',
        title: '$peer is SQLite-step dominated',
        body:
            'SQLite step time is ${_formatPercent(sqliteShare)}% of measured elapsed for `$scenario` ($detail).',
        evidence: {
          'peer': peer,
          'scenario': scenario,
          'sqlite_share_percent': sqliteShare,
        },
      ),
    ];
  }

  if (tracedShare < options.traceCoverageFloorPercent) {
    return [
      BenchmarkInsight(
        severity: 'warning',
        id: 'low_trace_coverage',
        title: '$peer has low traced coverage',
        body:
            'Traced spans explain ${_formatPercent(tracedShare)}% of measured elapsed; inspect harness/setup or add semantic spans before attributing the remaining time.',
        evidence: {
          'peer': peer,
          'scenario': scenario,
          'traced_share_percent': tracedShare,
        },
      ),
    ];
  }

  if (nonStepShare >= options.bottleneckSharePercent) {
    return [
      BenchmarkInsight(
        severity: 'info',
        id: 'non_step_trace_dominated',
        title: '$peer is dominated outside sqlite3_step',
        body:
            'Traced work outside sqlite3_step is ${_formatPercent(nonStepShare)}% of measured elapsed while sqlite3_step is ${_formatPercent(sqliteShare)}% ($detail).',
        evidence: {
          'peer': peer,
          'scenario': scenario,
          'traced_share_percent': tracedShare,
          'sqlite_share_percent': sqliteShare,
          'non_step_share_percent': nonStepShare,
        },
      ),
    ];
  }

  return [
    BenchmarkInsight(
      severity: 'info',
      id: 'mixed_cost_profile',
      title: '$peer has a mixed cost profile',
      body:
          'SQLite step is ${_formatPercent(sqliteShare)}% and all traced spans are ${_formatPercent(tracedShare)}% of measured elapsed ($detail).',
      evidence: {
        'peer': peer,
        'scenario': scenario,
        'traced_share_percent': tracedShare,
        'sqlite_share_percent': sqliteShare,
      },
    ),
  ];
}

List<BenchmarkInsight> _decisionInsights(
  Map<String, Object?> artifact,
  BenchmarkInsightOptions options,
) {
  final decision = _string(artifact['decision']) ?? 'unknown';
  final gates = _map(artifact['gates']);
  final traceHealth = _map(gates['trace_health']);
  final primary = _map(gates['primary']);
  final guardrails = _map(gates['guardrails']);
  final primaryComparisons = _listOfMaps(primary['comparisons']);
  final guardrailComparisons = _listOfMaps(guardrails['comparisons']);
  final insights = <BenchmarkInsight>[
    BenchmarkInsight(
      severity: switch (decision) {
        'accepted' => 'good',
        'rejected' => 'critical',
        _ => 'warning',
      },
      id: 'decision_outcome',
      title: 'Decision is $decision',
      body: switch (decision) {
        'accepted' =>
          'Primary evidence passed and guardrails/trace health did not block the experiment.',
        'rejected' =>
          'At least one gate rejected the experiment; inspect the critical findings below.',
        _ =>
          'The evidence is not strong enough for a production decision; inspect inconclusive gates and collect more signal.',
      },
    ),
  ];

  final traceStatus = _string(traceHealth['status']) ?? 'unknown';
  final traceIssues = _listOfMaps(traceHealth['issues']);
  if (traceStatus != 'passed') {
    insights.add(BenchmarkInsight(
      severity: 'critical',
      id: 'decision_trace_health',
      title: 'Trace health blocks trust',
      body:
          '${traceIssues.length} trace-health issue(s) affected the decision.',
      evidence: {'status': traceStatus, 'issues': traceIssues.length},
    ));
  }

  final primaryProblems = primaryComparisons
      .where((comparison) => comparison['gate_effect'] != 'pass')
      .toList();
  if (primaryProblems.isEmpty && primaryComparisons.isNotEmpty) {
    final first = primaryComparisons.first;
    insights.add(BenchmarkInsight(
      severity: 'good',
      id: 'decision_primary_passed',
      title: 'Primary metric cleared',
      body:
          '`${first['peer']}` `${first['metric']}` on `${first['scenario']}` changed by ${_formatPercent(first['change_percent'])}% with status `${first['status']}`.',
    ));
  } else {
    for (final problem in primaryProblems.take(3)) {
      insights.add(_comparisonInsight(
        problem,
        idPrefix: 'decision_primary',
        title: 'Primary metric did not clear',
        defaultSeverity:
            problem['gate_effect'] == 'reject' ? 'critical' : 'warning',
      ));
    }
  }

  final guardrailRejects = guardrailComparisons
      .where((comparison) => comparison['gate_effect'] == 'reject')
      .toList();
  final guardrailInconclusive = guardrailComparisons
      .where((comparison) => comparison['gate_effect'] == 'inconclusive')
      .toList();
  if (guardrailRejects.isNotEmpty) {
    insights.add(BenchmarkInsight(
      severity: 'critical',
      id: 'decision_guardrail_rejections',
      title: 'Guardrails rejected',
      body:
          '${guardrailRejects.length} guardrail comparison(s) show clear regression.',
    ));
  } else if (guardrailInconclusive.isNotEmpty) {
    insights.add(BenchmarkInsight(
      severity: 'warning',
      id: 'decision_guardrail_inconclusive',
      title: 'Guardrails are inconclusive',
      body:
          '${guardrailInconclusive.length} guardrail comparison(s) need cleaner or repeated evidence.',
    ));
  }

  if (decision == 'inconclusive' &&
      primaryProblems
          .any((comparison) => comparison['status'] == 'too_noisy')) {
    insights.add(BenchmarkInsight(
      severity: 'warning',
      id: 'decision_noise_next_step',
      title: 'Noise is the next action',
      body:
          'At least one primary comparison is too noisy under the ${_formatPercent(options.maxCvPercent)}% default CV gate; use the experiment or production profile with more repetitions.',
    ));
  }
  return insights;
}

List<BenchmarkInsight> _diffInsights(
  Map<String, Object?> artifact,
  BenchmarkInsightOptions options,
) {
  final comparisons = _listOfMaps(artifact['comparisons']);
  if (comparisons.isEmpty) {
    return [
      const BenchmarkInsight(
        severity: 'critical',
        id: 'diff_no_comparisons',
        title: 'No diff comparisons',
        body: 'The diff artifact has no peer comparisons to interpret.',
      ),
    ];
  }

  final insights = <BenchmarkInsight>[];
  final byVerdict = <String, int>{};
  for (final comparison in comparisons) {
    final verdict = _string(comparison['verdict']) ?? 'unknown';
    byVerdict[verdict] = (byVerdict[verdict] ?? 0) + 1;
  }
  if ((byVerdict['regressed'] ?? 0) > 0) {
    insights.add(BenchmarkInsight(
      severity: 'critical',
      id: 'diff_regressions',
      title: 'Diff contains regressions',
      body: '${byVerdict['regressed']} peer comparison(s) regressed.',
    ));
  }
  if ((byVerdict['too_noisy'] ?? 0) > 0) {
    insights.add(BenchmarkInsight(
      severity: 'warning',
      id: 'diff_too_noisy',
      title: 'Diff is noise-limited',
      body:
          '${byVerdict['too_noisy']} comparison(s) exceeded the ${_formatPercent(options.maxCvPercent)}% default CV gate or lacked clear statistical evidence.',
    ));
  }
  if ((byVerdict['insufficient_samples'] ?? 0) > 0) {
    insights.add(BenchmarkInsight(
      severity: 'warning',
      id: 'diff_insufficient_samples',
      title: 'Diff needs repetitions',
      body:
          '${byVerdict['insufficient_samples']} comparison(s) have fewer than two independent samples.',
    ));
  }
  if ((byVerdict['improved'] ?? 0) > 0) {
    insights.add(BenchmarkInsight(
      severity: 'good',
      id: 'diff_improvements',
      title: 'Diff contains improvements',
      body: '${byVerdict['improved']} peer comparison(s) improved.',
    ));
  }

  final strongest = comparisons
      .where((comparison) => comparison['change_percent'] is num)
      .toList()
    ..sort((a, b) => (b['change_percent']! as num)
        .abs()
        .compareTo((a['change_percent']! as num).abs()));
  if (strongest.isNotEmpty) {
    final comparison = strongest.first;
    insights.add(_comparisonInsight(
      comparison,
      idPrefix: 'diff_largest_change',
      title: 'Largest movement',
      defaultSeverity:
          comparison['verdict'] == 'regressed' ? 'critical' : 'info',
      statusKey: 'verdict',
    ));
  }

  if (insights.isEmpty) {
    insights.add(const BenchmarkInsight(
      severity: 'good',
      id: 'diff_clean',
      title: 'Diff is neutral',
      body: 'No peer comparison crossed the configured threshold.',
    ));
  }
  return insights;
}

List<BenchmarkInsight> _workloadInsights(Map<String, Object?> artifact) {
  final trace = _map(artifact['trace']);
  final healthMax = _traceHealthMapMax(_map(trace['diagnostics']));
  final workloads = _map(artifact['workloads']);
  final insights = <BenchmarkInsight>[];
  if (healthMax > 0) {
    insights.add(BenchmarkInsight(
      severity: 'critical',
      id: 'workload_trace_health',
      title: 'Workload trace health failed',
      body: 'Dropped or unmatched events are non-zero in the source trace.',
    ));
  }
  if (workloads.isEmpty) {
    insights.add(const BenchmarkInsight(
      severity: 'warning',
      id: 'workload_none',
      title: 'No workload spans found',
      body: 'The trace did not contain workload summary boundaries.',
    ));
  } else {
    final empty = workloads.entries
        .where((entry) => _map(_map(entry.value)['summary']).isEmpty)
        .map((entry) => entry.key)
        .toList();
    if (empty.isNotEmpty) {
      insights.add(BenchmarkInsight(
        severity: 'warning',
        id: 'workload_empty_operations',
        title: 'Some workloads lack operation summaries',
        body: 'No operation summary rows were found for ${empty.join(', ')}.',
      ));
    }
    insights.add(BenchmarkInsight(
      severity: 'good',
      id: 'workload_loaded',
      title: 'Workload summaries loaded',
      body: '${workloads.length} workload(s) are available for inspection.',
    ));
  }
  return insights;
}

List<BenchmarkInsight> _suiteInsights(Map<String, Object?> artifact) {
  final profile = _string(artifact['profile']) ?? 'unknown';
  final runs = _listOfMaps(artifact['runs']);
  final bad = runs.where((run) {
    final status = _string(run['status']) ?? 'unknown';
    return status != 'ok' && status != 'unsupported';
  }).toList();
  final unsupportedRuns =
      runs.where((run) => _string(run['status']) == 'unsupported').length;
  final statusDetail = unsupportedRuns == 0
      ? '`$profile` suite has ${runs.length} run(s) and ${bad.length} failed/non-ok run commands. Peer-level unsupported capability lanes are reported in the linked compare artifacts.'
      : '`$profile` suite has ${runs.length} run(s), ${bad.length} failed/non-ok run commands, and $unsupportedRuns unsupported run command(s). Peer-level unsupported capability lanes are reported in the linked compare artifacts.';
  final insights = <BenchmarkInsight>[
    BenchmarkInsight(
      severity: bad.isEmpty ? 'good' : 'critical',
      id: 'suite_status',
      title: bad.isEmpty ? 'Suite completed' : 'Suite has failed runs',
      body: statusDetail,
    ),
  ];
  return insights;
}

List<BenchmarkInsight> _suiteHistoryInsights(Map<String, Object?> artifact) {
  final profile = _string(artifact['profile']) ?? 'unknown';
  final runs = _listOfMaps(artifact['runs']);
  final ok = runs.where((run) => _string(run['status']) == 'ok').length;
  return [
    BenchmarkInsight(
      severity: ok == runs.length ? 'good' : 'warning',
      id: 'suite_history_status',
      title: 'Suite history loaded',
      body: '`$profile` history has $ok/${runs.length} successful run(s).',
    ),
  ];
}

BenchmarkInsight _comparisonInsight(
  Map<String, Object?> comparison, {
  required String idPrefix,
  required String title,
  required String defaultSeverity,
  String statusKey = 'status',
}) {
  final peer = comparison['peer'];
  final metric = comparison['metric'];
  final scenario = comparison['scenario'];
  final status = comparison[statusKey];
  return BenchmarkInsight(
    severity: defaultSeverity,
    id: '$idPrefix.$status',
    title: title,
    body:
        '`${peer ?? 'unknown'}` `${metric ?? 'metric'}` on `${scenario ?? 'scenario'}` changed by ${_formatPercent(comparison['change_percent'])}% with status `$status`.',
    evidence: {
      if (peer != null) 'peer': peer,
      if (metric != null) 'metric': metric,
      if (scenario != null) 'scenario': scenario,
      if (status != null) 'status': status,
    },
  );
}

int _compareInsightPriority(BenchmarkInsight a, BenchmarkInsight b) {
  final bySeverity = _severityRank(a.severity).compareTo(
    _severityRank(b.severity),
  );
  if (bySeverity != 0) return bySeverity;
  return a.title.compareTo(b.title);
}

int _severityRank(String severity) {
  return switch (severity) {
    'critical' => 0,
    'warning' => 1,
    'info' => 2,
    'good' => 3,
    _ => 4,
  };
}

double? _metricMean(Map<String, Object?> peer, String metric) {
  final summary = _map(peer['summary']);
  final stats = _map(summary[metric]);
  final mean = stats['mean'];
  if (mean is num) return mean.toDouble();
  final samples = _sampleMetricValues(peer, metric);
  if (samples.isEmpty) return null;
  return samples.reduce((a, b) => a + b) / samples.length;
}

double? _metricCv(Map<String, Object?> peer, String metric) {
  final summary = _map(peer['summary']);
  final stats = _map(summary[metric]);
  final cv = _metricStatsCv(stats);
  if (cv != null) return cv;
  final samples = _sampleMetricValues(peer, metric);
  if (samples.length < 2) return null;
  final mean = samples.reduce((a, b) => a + b) / samples.length;
  if (mean == 0) return 0;
  final variance = samples
          .map((value) => math.pow(value - mean, 2).toDouble())
          .reduce((a, b) => a + b) /
      (samples.length - 1);
  return math.sqrt(variance) / mean * 100;
}

double? _metricStatsCv(Map<String, Object?> stats) {
  final mean = stats['mean'];
  final stddev = stats['stddev'];
  if (mean is! num || stddev is! num) return null;
  if (mean == 0) return 0;
  return stddev / mean * 100;
}

int _traceHealthMax(Map<String, Object?> peer) {
  final summary = _map(peer['summary']);
  final summaryMax = [
    _metricMax(summary, 'dropped_events'),
    _metricMax(summary, 'unmatched_begin_events'),
    _metricMax(summary, 'unmatched_end_events'),
  ].whereType<int>().fold(0, math.max);
  if (summaryMax > 0) return summaryMax;
  final samples = _listOfMaps(peer['samples']);
  return samples
      .map((sample) => _traceHealthMapMax(_map(sample['diagnostics'])))
      .fold(0, math.max);
}

int? _metricMax(Map<String, Object?> summary, String metric) {
  final stats = _map(summary[metric]);
  final max = stats['max'];
  return max is num ? max.round() : null;
}

int _traceHealthMapMax(Map<String, Object?> diagnostics) {
  final values = [
    diagnostics['dropped_events'],
    diagnostics['unmatched_begin_events'],
    diagnostics['unmatched_end_events'],
  ];
  return values
      .whereType<num>()
      .map((value) => value.round())
      .fold(0, math.max);
}

List<int> _sampleMetricValues(Map<String, Object?> peer, String metric) {
  final samples = _listOfMaps(peer['samples']);
  return [
    for (final sample in samples)
      if (_string(sample['status']) == 'ok')
        if (_sampleMetricValue(sample, metric) case final value?) value,
  ];
}

int? _sampleMetricValue(Map<String, Object?> sample, String metric) {
  final direct = sample[metric];
  if (direct is num) return direct.round();
  final diagnostics = _map(sample['diagnostics']);
  final diagnostic = diagnostics[metric];
  if (diagnostic is num) return diagnostic.round();

  final spanGroups = _listOfMaps(sample['span_groups']);
  if (metric == 'trace_span_total_ns') {
    var total = 0;
    for (final group in spanGroups) {
      final value = group['total_ns'];
      if (value is num) total += value.round();
    }
    return total == 0 ? null : total;
  }
  for (final group in spanGroups) {
    if (group['span_name'] != 'sqlite3_step') continue;
    return switch (metric) {
      'sqlite3_step_count' => (group['count'] as num?)?.round(),
      'sqlite3_step_total_ns' => (group['total_ns'] as num?)?.round(),
      _ => null,
    };
  }
  return null;
}

_SpanGroupTotal? _topSpanGroup(Map<String, Object?> peer) {
  final totals = <String, _SpanGroupTotal>{};
  var okSamples = 0;
  for (final sample in _listOfMaps(peer['samples'])) {
    if (_string(sample['status']) != 'ok') continue;
    okSamples++;
    for (final group in _listOfMaps(sample['span_groups'])) {
      final name = _string(group['span_name']);
      final total = group['total_ns'];
      if (name == null || total is! num) continue;
      totals.putIfAbsent(name, () => _SpanGroupTotal(name)).totalNs +=
          total.toDouble();
    }
  }
  if (totals.isEmpty || okSamples == 0) return null;
  final sorted = totals.values.toList()
    ..sort((a, b) => b.totalNs.compareTo(a.totalNs));
  return sorted.first..sampleCount = okSamples;
}

final class _SpanGroupTotal {
  _SpanGroupTotal(this.name);

  final String name;
  double totalNs = 0;
  int sampleCount = 1;

  double get totalMeanNs => totalNs / sampleCount;
}

Map<String, Object?> _map(Object? value) {
  if (value is Map) return Map<String, Object?>.from(value);
  return const {};
}

List<Object?> _list(Object? value) {
  if (value is List) return List<Object?>.from(value);
  return const [];
}

List<Map<String, Object?>> _listOfMaps(Object? value) {
  return [
    for (final item in _list(value))
      if (item is Map) Map<String, Object?>.from(item),
  ];
}

String? _string(Object? value) => value is String ? value : null;

String _formatPercent(Object? value) {
  if (value is! num || !value.isFinite) return '-';
  final abs = value.abs();
  if (abs >= 100) return value.toStringAsFixed(0);
  if (abs >= 10) return value.toStringAsFixed(1);
  return value.toStringAsFixed(2);
}

String _formatCount(double value) {
  if (value >= 100) return value.toStringAsFixed(0);
  if (value >= 10) return value.toStringAsFixed(1);
  return value.toStringAsFixed(2);
}

String _markdownCell(String value) => value.replaceAll('|', '\\|');
