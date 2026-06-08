import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:tracelite/tracelite.dart';

void main() {
  test('compare insights flag trace health, noise, and bottlenecks', () {
    final artifact = _compareArtifact(
      measured: [100000, 140000, 70000, 150000, 90000],
      sqliteStepTotal: [70000, 90000, 50000, 100000, 60000],
      droppedEvents: 1,
    );

    final insights = benchmarkArtifactInsights(artifact);
    expect(
      insights.map((insight) => insight.id),
      containsAll([
        'compare_trace_health',
        'compare_noisy_measurements',
        'sqlite_dominated',
      ]),
    );
    expect(insights.first.severity, 'critical');
  });

  test('decision insights explain rejected primary evidence', () {
    final artifact = {
      'schema': 'tracelite.decision.v1',
      'decision': 'rejected',
      'policy': const {
        'expectation': 'no_regression',
        'primary_peer': 'sqlite3',
        'primary_metric': 'elapsed_ns',
      },
      'gates': {
        'trace_health': const {
          'status': 'passed',
          'issues': <Object?>[],
        },
        'primary': {
          'status': 'rejected',
          'comparisons': [
            {
              'scenario': 'point-select',
              'peer': 'sqlite3',
              'metric': 'elapsed_ns',
              'status': 'regressed',
              'gate_effect': 'reject',
              'change_percent': 18.5,
              'max_cv_percent': 22.75,
              'nonparametric_p_value': 0.519,
              'delta_ci95_low': -42600000,
              'delta_ci95_high': 38500000,
            },
          ],
        },
        'guardrails': const {
          'status': 'passed',
          'comparisons': <Object?>[],
        },
      },
    };

    final insights = benchmarkArtifactInsights(artifact);
    expect(insights.first.id, 'decision_outcome');
    expect(insights.first.severity, 'critical');
    expect(
      insights.map((insight) => insight.id),
      contains('decision_primary.regressed'),
    );
    final primary = insights.singleWhere(
      (insight) => insight.id == 'decision_primary.regressed',
    );
    expect(primary.body, contains('max CV 22.8%'));
    expect(primary.body, contains('p=0.519'));
    expect(primary.body, contains('95% delta CI -42.6ms..38.5ms'));
  });

  test('decision noise guidance uses calibrated policy gate', () {
    final artifact = {
      'schema': 'tracelite.decision.v1',
      'decision': 'inconclusive',
      'policy': const {
        'expectation': 'improvement',
        'primary_peer': 'resqlite',
        'primary_metric': 'measured_elapsed_ns',
        'max_cv_percent': 24.0,
      },
      'gates': {
        'trace_health': const {
          'status': 'passed',
          'issues': <Object?>[],
        },
        'primary': {
          'status': 'inconclusive',
          'comparisons': [
            {
              'scenario': 'narrow-batch-insert',
              'peer': 'resqlite',
              'metric': 'measured_elapsed_ns',
              'status': 'too_noisy',
              'gate_effect': 'inconclusive',
              'change_percent': 27.7,
              'max_cv_percent': 33.0,
            },
          ],
        },
        'guardrails': const {
          'status': 'passed',
          'comparisons': <Object?>[],
        },
      },
    };

    final insights = benchmarkArtifactInsights(artifact);
    final noise = insights.singleWhere(
      (insight) => insight.id == 'decision_noise_next_step',
    );
    expect(noise.body, contains('24.0% CV gate'));
    expect(noise.body, isNot(contains('15.0%')));
  });

  test('compare insights warn when runner overhead dominates tiny workloads',
      () {
    final artifact = _compareArtifact(
      measured: [10000000, 11000000, 9000000],
      sqliteStepTotal: [5000000, 5100000, 4900000],
      childElapsed: [250000000, 260000000, 255000000],
    );

    final insights = benchmarkArtifactInsights(artifact);
    final ids = insights.map((insight) => insight.id);
    expect(ids, contains('harness_overhead_dominates'));
    final overhead = insights.singleWhere(
      (insight) => insight.id == 'harness_overhead_dominates',
    );
    expect(overhead.severity, 'warning');
    expect(overhead.body, contains('Child-process wall time'));
  });

  test('compare insights flag top traced span outside sqlite3_step', () {
    final artifact = _compareArtifact(
      measured: [1000000, 1010000, 990000],
      sqliteStepTotal: [100000, 101000, 99000],
      nonStepSpanName: 'sqlite3_open_v2',
      nonStepTotal: [700000, 707000, 693000],
    );

    final insights = benchmarkArtifactInsights(artifact);
    final topSpan = insights.singleWhere(
      (insight) => insight.id == 'top_non_step_span_dominates',
    );
    expect(topSpan.body, contains('sqlite3_open_v2'));
    expect(topSpan.body, contains('not sqlite3_step'));
  });

  test('insight markdown renders an actionable table', () {
    final markdown = benchmarkArtifactInsightsMarkdown(
      _compareArtifact(
        measured: [100000, 101000, 99000],
        sqliteStepTotal: [70000, 71000, 69000],
      ),
    );

    expect(markdown, contains('| severity | finding | detail |'));
    expect(markdown, contains('SQLite-step dominated'));
  });

  test('suite insight does not hide peer-level unsupported lanes', () {
    final insights = benchmarkArtifactInsights({
      'schema': 'tracelite.suite.v1',
      'profile': 'ci',
      'runs': [
        {
          'scenario': 'keyed-pk-subscriptions',
          'status': 'ok',
          'artifact': 'keyed-pk-subscriptions.json',
        },
      ],
    });

    final suiteStatus = insights.singleWhere(
      (insight) => insight.id == 'suite_status',
    );
    expect(suiteStatus.body, contains('failed/non-ok run commands'));
    expect(suiteStatus.body, contains('linked compare artifacts'));
    expect(suiteStatus.body, isNot(contains('0 unsupported')));
  });

  test('workload summary insights are generic and field-driven', () {
    final insights = benchmarkArtifactInsights({
      'schema': 'tracelite.workload_summary.v1',
      'trace': {
        'diagnostics': {
          'dropped_events': 0,
          'unmatched_begin_events': 0,
          'unmatched_end_events': 0,
        },
      },
      'noop_floors': {
        'reader_us': 12,
        'writer_us': 16,
      },
      'workloads': {
        'point_query': {
          'summary': {
            'select': {
              'count': 50000,
              'median_us': 11,
              'p99_us': 78,
              'max_us': 2048,
              'work_us_median': 0,
              'dispatch_floor_us': 12,
            },
          },
          'memory': {
            'rss_delta_mb': 18.297,
            'allocation_delta': {
              'rows_decoded': 50000,
              'cells_decoded': 300000,
            },
            'diagnostics_delta': {
              'wal_bytes_delta': 0,
            },
          },
        },
        'merge_rounds': {
          'summary': {
            'executeBatch': {
              'count': 1000,
              'median_us': 93,
              'p99_us': 890,
              'max_us': 4136,
              'work_us_median': 77,
              'dispatch_floor_us': 16,
            },
          },
          'memory': {
            'rss_delta_mb': 0.485,
            'diagnostics_delta': {
              'wal_bytes_delta': 8240,
            },
          },
        },
      },
    });

    final ids = insights.map((insight) => insight.id);
    expect(ids, contains('workload_dispatch_floors'));
    expect(ids, contains('workload_dispatch_bound'));
    expect(ids, contains('workload_work_bound'));
    expect(ids, contains('workload_tail_spread'));
    expect(ids, contains('workload_rss_signal'));
    expect(ids, contains('workload_allocation_signal'));
    expect(ids, contains('workload_wal_signal'));

    expect(
      insights
          .singleWhere((insight) => insight.id == 'workload_dispatch_bound')
          .body,
      contains('point_query/select'),
    );
    expect(
      insights
          .singleWhere((insight) => insight.id == 'workload_work_bound')
          .body,
      contains('merge_rounds/executeBatch'),
    );
  });
}

Map<String, Object?> _compareArtifact({
  required List<int> measured,
  required List<int> sqliteStepTotal,
  List<int>? childElapsed,
  String? nonStepSpanName,
  List<int>? nonStepTotal,
  int droppedEvents = 0,
}) {
  final childElapsedValues = childElapsed ?? measured;
  final traceSpanTotal = [
    for (var i = 0; i < sqliteStepTotal.length; i++)
      sqliteStepTotal[i] + (nonStepTotal?[i] ?? 0),
  ];
  return {
    'schema': 'tracelite.compare.v1',
    'scenario': 'point-select',
    'rows': 1,
    'repetitions': measured.length,
    'peers': [
      {
        'peer': 'sqlite3',
        'status': 'ok',
        'successful_repetitions': measured.length,
        'failed_repetitions': 0,
        'unsupported_repetitions': 0,
        'summary': {
          'measured_elapsed_ns': _stats(measured),
          'child_elapsed_ns': _stats(childElapsedValues),
          'elapsed_ns': _stats(measured),
          'sqlite3_step_total_ns': _stats(sqliteStepTotal),
          'sqlite3_step_count': _stats(List.filled(measured.length, 3)),
          'trace_span_total_ns': _stats(traceSpanTotal),
          'dropped_events': _stats(List.filled(measured.length, droppedEvents)),
          'unmatched_begin_events': _stats(List.filled(measured.length, 0)),
          'unmatched_end_events': _stats(List.filled(measured.length, 0)),
        },
        'samples': [
          for (var i = 0; i < measured.length; i++)
            {
              'repetition': i + 1,
              'status': 'ok',
              'measured_elapsed_ns': measured[i],
              'child_elapsed_ns': childElapsedValues[i],
              'elapsed_ns': measured[i],
              'diagnostics': {
                'dropped_events': droppedEvents,
                'unmatched_begin_events': 0,
                'unmatched_end_events': 0,
              },
              'span_groups': [
                {
                  'span_name': 'sqlite3_step',
                  'count': 3,
                  'total_ns': sqliteStepTotal[i],
                  'p50_ns': sqliteStepTotal[i] ~/ 3,
                  'p90_ns': sqliteStepTotal[i] ~/ 2,
                  'p99_ns': sqliteStepTotal[i],
                },
                if (nonStepSpanName != null && nonStepTotal != null)
                  {
                    'span_name': nonStepSpanName,
                    'count': 1,
                    'total_ns': nonStepTotal[i],
                    'p50_ns': nonStepTotal[i],
                    'p90_ns': nonStepTotal[i],
                    'p99_ns': nonStepTotal[i],
                  },
              ],
            },
        ],
        'capabilities': ['sql'],
      },
    ],
  };
}

Map<String, Object?> _stats(List<int> values) {
  final sorted = [...values]..sort();
  final total = values.reduce((a, b) => a + b);
  final mean = total / values.length;
  final p90Index =
      (values.length * 0.9).floor().clamp(0, sorted.length - 1).toInt();
  final variance = values.length < 2
      ? 0.0
      : values
              .map((value) => (value - mean) * (value - mean))
              .reduce((a, b) => a + b) /
          (values.length - 1);
  return {
    'count': values.length,
    'total': total,
    'min': sorted.first,
    'max': sorted.last,
    'mean': mean,
    'median': sorted[sorted.length ~/ 2],
    'p90': sorted[p90Index],
    'p99': sorted.last,
    'stddev': math.sqrt(variance),
  };
}
