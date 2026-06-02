// Lightweight cross-platform smoke for the published/core Dart surface.
//
// This intentionally runs with `dart --packages=... tool/platform_core_smoke.dart`
// in CI so source-checkout dev-dependency native hooks are not invoked on
// platforms where the SQLite shim is not yet supported.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:tracelite/src/native_artifacts.dart' as native_artifacts;
import 'package:tracelite/tracelite.dart';

void main() {
  _checkNativeSupportBoundary();
  _checkTraceRegionRoundTrip();
  _checkDiffAndInsights();
  stdout.writeln('tracelite core platform smoke passed');
}

void _checkNativeSupportBoundary() {
  _expect(
    native_artifacts.runtimeBuildCommand(operatingSystem: 'windows') != null,
    'Windows native runtime build command missing',
  );
  _expect(
    native_artifacts.sqliteShimBuildCommand(operatingSystem: 'windows') == null,
    'Windows SQLite shim build must stay explicitly unsupported until the shim '
    'has a real Windows resolver strategy.',
  );
  _expect(
    native_artifacts.runtimeBuildCommand(operatingSystem: 'macos') != null,
    'macOS runtime build command missing',
  );
  _expect(
    native_artifacts.sqliteShimBuildCommand(operatingSystem: 'linux') != null,
    'Linux shim build command missing',
  );
}

void _checkTraceRegionRoundTrip() {
  final temp = Directory.systemTemp.createTempSync('tracelite-core-smoke-');
  try {
    final regionPath = '${temp.path}/core.tlt-region';
    TraceRegion.createFile(regionPath, ringDataWords: 1024);
    final trace = Trace.loadRegion(regionPath);
    final report = trace.toMarkdownReport();
    _expect(report.contains('# tracelite report'), 'report header missing');
    _expect(trace.events.isEmpty, 'new region should not contain events');
  } finally {
    temp.deleteSync(recursive: true);
  }
}

void _checkDiffAndInsights() {
  final baseline = _compareArtifact([1000000, 1010000, 1020000]);
  final candidate = _compareArtifact([900000, 910000, 920000]);
  final diff = benchmarkDiffArtifact(
    baselineArtifact: jsonDecode(jsonEncode(baseline)) as Map<String, Object?>,
    candidateArtifact:
        jsonDecode(jsonEncode(candidate)) as Map<String, Object?>,
    baselinePath: 'baseline.json',
    candidatePath: 'candidate.json',
    options: const BenchmarkDiffOptions(maxCvPercent: 1000),
  );
  _expect(diff['schema'] == 'tracelite.diff.v1', 'diff schema mismatch');
  final insights = benchmarkArtifactInsights(diff);
  _expect(insights.isNotEmpty, 'diff insights should not be empty');
}

Map<String, Object?> _compareArtifact(List<int> elapsedNs) {
  return {
    'schema': 'tracelite.compare.v1',
    'peers': [
      {
        'peer': 'sqlite3',
        'summary': {
          'elapsed_ns': _stats(elapsedNs),
        },
        'samples': [
          for (var index = 0; index < elapsedNs.length; index++)
            {
              'repetition': index + 1,
              'status': 'ok',
              'elapsed_ns': elapsedNs[index],
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
    'p90': sorted.last,
    'p99': sorted.last,
    'stddev': math.sqrt(variance),
  };
}

void _expect(bool condition, String message) {
  if (!condition) {
    stderr.writeln(message);
    exitCode = 1;
    throw StateError(message);
  }
}
