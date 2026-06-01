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
}

Map<String, Object?> _compareArtifact({
  required List<int> measured,
  required List<int> sqliteStepTotal,
  int droppedEvents = 0,
}) {
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
          'elapsed_ns': _stats(measured),
          'sqlite3_step_total_ns': _stats(sqliteStepTotal),
          'sqlite3_step_count': _stats(List.filled(measured.length, 3)),
          'trace_span_total_ns': _stats(sqliteStepTotal),
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
