import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';

void main() {
  test('diff gates clear changes with nonparametric repetition evidence',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-diff-statistics-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final baselinePath = '${tempDir.path}/baseline.json';
    final candidatePath = '${tempDir.path}/candidate.json';
    File(baselinePath).writeAsStringSync(
      jsonEncode(
        _artifact('sqlite3', [
          1000000,
          1010000,
          1020000,
          1030000,
          1040000,
        ]),
      ),
    );
    File(candidatePath).writeAsStringSync(
      jsonEncode(
        _artifact('sqlite3', [700000, 710000, 720000, 730000, 740000]),
      ),
    );

    final diff = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'diff',
        '--baseline=$baselinePath',
        '--candidate=$candidatePath',
        '--threshold-percent=5',
        '--max-cv-percent=1000',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      diff.exitCode,
      0,
      reason: 'diff failed.\nstdout:\n${diff.stdout}\n'
          'stderr:\n${diff.stderr}',
    );
    final output = diff.stdout.toString();
    expect(output, contains('nonparam p'));
    expect(output, contains('outliers'));
    expect(_lineFor(output, 'sqlite3'), contains('| improved |'));
  });

  test('diff reports per-side outlier counts', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-diff-outlier-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final baselinePath = '${tempDir.path}/baseline.json';
    final candidatePath = '${tempDir.path}/candidate.json';
    File(baselinePath).writeAsStringSync(
      jsonEncode(
        _artifact('sqlite3', [1000000, 1010000, 1020000, 1030000, 5000000]),
      ),
    );
    File(candidatePath).writeAsStringSync(
      jsonEncode(
        _artifact('sqlite3', [
          1000000,
          1010000,
          1020000,
          1030000,
          1040000,
        ]),
      ),
    );

    final diff = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'diff',
        '--baseline=$baselinePath',
        '--candidate=$candidatePath',
        '--max-cv-percent=1000',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      diff.exitCode,
      0,
      reason: 'diff failed.\nstdout:\n${diff.stdout}\n'
          'stderr:\n${diff.stderr}',
    );
    expect(_lineFor(diff.stdout.toString(), 'sqlite3'), contains('| 1/0 |'));
  });
}

Map<String, Object?> _artifact(String peer, List<int> elapsedNs) {
  return {
    'schema': 'tracelite.compare.v1',
    'peers': [
      {
        'peer': peer,
        'summary': {
          'elapsed_ns': _stats(elapsedNs),
        },
        'samples': [
          for (var i = 0; i < elapsedNs.length; i++)
            {
              'repetition': i + 1,
              'status': 'ok',
              'elapsed_ns': elapsedNs[i],
            },
        ],
      },
    ],
  };
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
    'p90': sorted[(sorted.length * 0.9).ceil().clamp(0, sorted.length - 1)],
    'p99': sorted[(sorted.length * 0.99).ceil().clamp(0, sorted.length - 1)],
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
