import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';

void main() {
  test('explain writes markdown and insight JSON for compare artifacts',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-explain-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final compare = '${tempDir.path}/compare.json';
    final outJson = '${tempDir.path}/insights.json';
    _writeCompare(compare);

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'explain',
        compare,
        '--out-json=$outJson',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'explain failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('# tracelite insights'));
    expect(result.stdout.toString(), contains('SQLite-step dominated'));

    final artifact =
        jsonDecode(File(outJson).readAsStringSync()) as Map<String, Object?>;
    expect(artifact['schema'], 'tracelite.insights.v1');
    final sources = artifact['sources'] as List<Object?>;
    expect(sources, hasLength(1));
    final source = sources.single as Map<String, Object?>;
    expect(source['artifact_schema'], 'tracelite.compare.v1');
    final insights = source['insights'] as List<Object?>;
    expect(
      insights.cast<Map<String, Object?>>().map((insight) => insight['id']),
      contains('sqlite_dominated'),
    );
  });
}

void _writeCompare(String path) {
  final measured = [100000, 101000, 99000];
  final sqliteStepTotal = [70000, 71000, 69000];
  const encoder = JsonEncoder.withIndent('  ');
  File(path).writeAsStringSync(
    '${encoder.convert({
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
                'dropped_events': _stats(List.filled(measured.length, 0)),
                'unmatched_begin_events':
                    _stats(List.filled(measured.length, 0)),
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
                      'dropped_events': 0,
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
        })}\n',
  );
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
