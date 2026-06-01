import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tracelite/tracelite.dart';
import 'package:tracelite_visualizer/src/workspace.dart';

void main() {
  test('loads generic traces and compare artifacts from a directory', () async {
    final temp = Directory.systemTemp.createTempSync('tracelite-viz-test-');
    try {
      final tracePath = '${temp.path}/empty.tlt-region';
      TraceRegion.createFile(tracePath);
      File('${temp.path}/compare.json').writeAsStringSync(
        jsonEncode({
          'schema': 'tracelite.compare.v1',
          'generated_at': '2026-05-12T00:00:00Z',
          'scenario': 'point-select',
          'rows': 10,
          'repetitions': 1,
          'peers': [
            {
              'peer': 'sqlite3',
              'status': 'ok',
              'successful_repetitions': 1,
              'failed_repetitions': 0,
              'unsupported_repetitions': 0,
              'summary': {
                'measured_elapsed_ns': _stats(1200000),
                'elapsed_ns': _stats(5000000),
                'sqlite3_step_count': _stats(42),
                'sqlite3_step_total_ns': _stats(900000),
                'events': _stats(100),
                'dropped_events': _stats(0),
                'unmatched_begin_events': _stats(0),
                'unmatched_end_events': _stats(0),
              },
              'samples': [
                {
                  'repetition': 1,
                  'status': 'ok',
                  'measured_elapsed_ns': 1200000,
                  'elapsed_ns': 5000000,
                  'events': 100,
                  'spans': 50,
                  'diagnostics': {
                    'dropped_events': 0,
                    'unmatched_begin_events': 0,
                    'unmatched_end_events': 0,
                  },
                  'span_groups': [
                    {
                      'span_name': 'sqlite3_step',
                      'count': 42,
                      'total_ns': 900000,
                      'p50_ns': 1000,
                      'p90_ns': 2000,
                      'p99_ns': 3000,
                    },
                  ],
                  'sql_fingerprint_groups': [
                    {
                      'fingerprint': 'sqlfp:v1:2a1aa0dda20c1116',
                      'normalized_sql':
                          'INSERT INTO TRACELITE_ITEMS(ID, NAME) VALUES (?, ?)',
                      'prepare_count': 10,
                      'prepare_total_ns': 700000,
                      'prepare_p50_ns': 40000,
                      'prepare_p90_ns': 80000,
                      'prepare_p99_ns': 90000,
                    },
                  ],
                },
              ],
              'capabilities': ['sql'],
            },
          ],
        }),
      );

      final workspace = await VisualizerWorkspace.load(temp.path);

      expect(workspace.issues, isEmpty);
      expect(workspace.traces, hasLength(1));
      expect(workspace.compares, hasLength(1));
      expect(workspace.compares.single.peers.single.name, 'sqlite3');
      final sample = workspace.compares.single.peers.single.samples.single;
      expect(sample.sqlFingerprintGroups, hasLength(1));
      expect(
        sample.sqlFingerprintGroups.single.normalizedSql,
        contains('INSERT INTO TRACELITE_ITEMS'),
      );
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
}

Map<String, Object?> _stats(num value) => {
  'count': 1,
  'total': value,
  'min': value,
  'max': value,
  'mean': value,
  'median': value,
  'p90': value,
  'p99': value,
  'stddev': 0,
};
