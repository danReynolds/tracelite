import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:tracelite/tracelite.dart';

final class VisualizerWorkspace {
  const VisualizerWorkspace({
    required this.rootPath,
    required this.traces,
    required this.compares,
    required this.suites,
    required this.decisions,
    required this.workloads,
    required this.graphData,
    required this.unknownArtifacts,
    required this.issues,
  });

  final String rootPath;
  final List<TraceDocument> traces;
  final List<CompareDocument> compares;
  final List<SuiteDocument> suites;
  final List<DecisionDocument> decisions;
  final List<WorkloadSummaryDocument> workloads;
  final List<GraphDataDocument> graphData;
  final List<UnknownArtifact> unknownArtifacts;
  final List<LoadIssue> issues;

  bool get isEmpty =>
      traces.isEmpty &&
      compares.isEmpty &&
      suites.isEmpty &&
      decisions.isEmpty &&
      workloads.isEmpty &&
      graphData.isEmpty &&
      unknownArtifacts.isEmpty;

  int get artifactCount =>
      traces.length +
      compares.length +
      suites.length +
      decisions.length +
      workloads.length +
      graphData.length +
      unknownArtifacts.length;

  static Future<VisualizerWorkspace> load(String rawPath) {
    return Future(() => _WorkspaceLoader().load(rawPath));
  }
}

final class TraceDocument {
  TraceDocument({required this.path, required this.trace})
    : completeSpans = trace.spans.where((span) => span.isComplete).toList()
        ..sort((a, b) {
          final byStart = a.startNs.compareTo(b.startNs);
          if (byStart != 0) return byStart;
          return b.durationNs.compareTo(a.durationNs);
        }),
      spanGroups =
          trace.spans
              .groupStatsByType(spanNames: trace.spanNames)
              .where((group) => group.stats.count > 0)
              .toList()
            ..sort((a, b) {
              final byTotal = b.stats.totalNs.compareTo(a.stats.totalNs);
              if (byTotal != 0) return byTotal;
              return a.spanName.compareTo(b.spanName);
            });

  final String path;
  final Trace trace;
  final List<TraceSpan> completeSpans;
  final List<SpanGroupStats> spanGroups;

  late final Map<int, List<TraceSpan>> completeSpansByTrack = _spansByTrack(
    completeSpans,
  );

  String get name => displayNameForPath(path);
  int get durationNs => trace.duration.inMicroseconds * 1000;
  int get sqliteStepCount =>
      trace.spans.ofType(BuiltinSpans.sqlite3Step).durationStats().count;
  int get sqliteStepTotalNs =>
      trace.spans.ofType(BuiltinSpans.sqlite3Step).durationStats().totalNs;
  bool get hasHealthIssues =>
      trace.diagnostics.droppedEvents > 0 ||
      trace.diagnostics.unmatchedBeginEvents > 0 ||
      trace.diagnostics.unmatchedEndEvents > 0;
}

Map<int, List<TraceSpan>> _spansByTrack(List<TraceSpan> spans) {
  final result = <int, List<TraceSpan>>{};
  for (final span in spans) {
    result.putIfAbsent(span.trackId, () => []).add(span);
  }
  return {
    for (final entry in result.entries)
      entry.key: List.unmodifiable(entry.value),
  };
}

final class CompareDocument {
  CompareDocument({
    required this.path,
    required this.scenario,
    required this.rows,
    required this.repetitions,
    required this.generatedAt,
    required this.peers,
  });

  final String path;
  final String scenario;
  final int rows;
  final int repetitions;
  final String? generatedAt;
  final List<PeerSummary> peers;

  String get name => displayNameForPath(path);

  factory CompareDocument.fromJson(String path, Map<String, Object?> json) {
    final peerObjects = _listOfMaps(json['peers']);
    return CompareDocument(
      path: path,
      scenario: _string(json['scenario']) ?? displayNameForPath(path),
      rows: _int(json['rows']) ?? 0,
      repetitions: _int(json['repetitions']) ?? peerObjects.length,
      generatedAt: _string(json['generated_at']),
      peers: [for (final peer in peerObjects) PeerSummary.fromJson(peer)],
    );
  }
}

final class PeerSummary {
  PeerSummary({
    required this.name,
    required this.status,
    required this.successfulRepetitions,
    required this.failedRepetitions,
    required this.unsupportedRepetitions,
    required this.summary,
    required this.samples,
    required this.capabilities,
  });

  final String name;
  final String status;
  final int successfulRepetitions;
  final int failedRepetitions;
  final int unsupportedRepetitions;
  final Map<String, MetricStats> summary;
  final List<PeerSample> samples;
  final List<String> capabilities;

  MetricStats? metric(String name) => summary[name];

  int get traceHealthMax {
    final dropped = metric('dropped_events')?.max ?? 0;
    final unmatchedBegin = metric('unmatched_begin_events')?.max ?? 0;
    final unmatchedEnd = metric('unmatched_end_events')?.max ?? 0;
    return math.max(dropped, math.max(unmatchedBegin, unmatchedEnd));
  }

  factory PeerSummary.fromJson(Map<String, Object?> json) {
    final summaryJson = _map(json['summary']);
    final metrics = <String, MetricStats>{};
    for (final entry in summaryJson.entries) {
      final metricJson = _map(entry.value);
      if (metricJson.isNotEmpty) {
        metrics[entry.key] = MetricStats.fromJson(metricJson);
      }
    }
    return PeerSummary(
      name: _string(json['peer']) ?? 'unknown',
      status: _string(json['status']) ?? 'unknown',
      successfulRepetitions: _int(json['successful_repetitions']) ?? 0,
      failedRepetitions: _int(json['failed_repetitions']) ?? 0,
      unsupportedRepetitions: _int(json['unsupported_repetitions']) ?? 0,
      summary: metrics,
      samples: [
        for (final sample in _listOfMaps(json['samples']))
          PeerSample.fromJson(sample),
      ],
      capabilities: [
        for (final capability in _list(json['capabilities']))
          if (capability is String) capability,
      ],
    );
  }
}

final class MetricStats {
  const MetricStats({
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

  final int count;
  final int total;
  final int min;
  final int max;
  final double mean;
  final int median;
  final int p90;
  final int p99;
  final double stddev;

  double get cvPercent => mean <= 0 ? 0 : (stddev / mean) * 100;

  factory MetricStats.fromJson(Map<String, Object?> json) {
    return MetricStats(
      count: _int(json['count']) ?? 0,
      total: _int(json['total']) ?? 0,
      min: _int(json['min']) ?? 0,
      max: _int(json['max']) ?? 0,
      mean: _double(json['mean']) ?? 0,
      median: _int(json['median']) ?? 0,
      p90: _int(json['p90']) ?? 0,
      p99: _int(json['p99']) ?? 0,
      stddev: _double(json['stddev']) ?? 0,
    );
  }
}

final class PeerSample {
  const PeerSample({
    required this.repetition,
    required this.status,
    required this.measuredElapsedNs,
    required this.elapsedNs,
    required this.events,
    required this.spans,
    required this.diagnostics,
    required this.spanGroups,
  });

  final int repetition;
  final String status;
  final int measuredElapsedNs;
  final int elapsedNs;
  final int events;
  final int spans;
  final TraceHealth diagnostics;
  final List<SampleSpanGroup> spanGroups;

  factory PeerSample.fromJson(Map<String, Object?> json) {
    return PeerSample(
      repetition: _int(json['repetition']) ?? 0,
      status: _string(json['status']) ?? 'unknown',
      measuredElapsedNs: _int(json['measured_elapsed_ns']) ?? 0,
      elapsedNs: _int(json['elapsed_ns']) ?? 0,
      events: _int(json['events']) ?? 0,
      spans: _int(json['spans']) ?? 0,
      diagnostics: TraceHealth.fromJson(_map(json['diagnostics'])),
      spanGroups:
          [
            for (final group in _listOfMaps(json['span_groups']))
              SampleSpanGroup.fromJson(group),
          ]..sort((a, b) {
            final byTotal = b.totalNs.compareTo(a.totalNs);
            if (byTotal != 0) return byTotal;
            return a.name.compareTo(b.name);
          }),
    );
  }
}

final class TraceHealth {
  const TraceHealth({
    required this.droppedEvents,
    required this.unmatchedBeginEvents,
    required this.unmatchedEndEvents,
  });

  final int droppedEvents;
  final int unmatchedBeginEvents;
  final int unmatchedEndEvents;

  int get maxValue => math.max(
    droppedEvents,
    math.max(unmatchedBeginEvents, unmatchedEndEvents),
  );

  factory TraceHealth.fromJson(Map<String, Object?> json) {
    return TraceHealth(
      droppedEvents: _int(json['dropped_events']) ?? 0,
      unmatchedBeginEvents: _int(json['unmatched_begin_events']) ?? 0,
      unmatchedEndEvents: _int(json['unmatched_end_events']) ?? 0,
    );
  }
}

final class SampleSpanGroup {
  const SampleSpanGroup({
    required this.name,
    required this.count,
    required this.totalNs,
    required this.p50Ns,
    required this.p90Ns,
    required this.p99Ns,
  });

  final String name;
  final int count;
  final int totalNs;
  final int p50Ns;
  final int p90Ns;
  final int p99Ns;

  factory SampleSpanGroup.fromJson(Map<String, Object?> json) {
    return SampleSpanGroup(
      name: _string(json['span_name']) ?? 'unknown',
      count: _int(json['count']) ?? 0,
      totalNs: _int(json['total_ns']) ?? 0,
      p50Ns: _int(json['p50_ns']) ?? 0,
      p90Ns: _int(json['p90_ns']) ?? 0,
      p99Ns: _int(json['p99_ns']) ?? 0,
    );
  }
}

final class SuiteDocument {
  const SuiteDocument({
    required this.path,
    required this.profile,
    required this.runs,
  });

  final String path;
  final String profile;
  final List<SuiteRun> runs;

  String get name => displayNameForPath(path);

  factory SuiteDocument.fromJson(String path, Map<String, Object?> json) {
    return SuiteDocument(
      path: path,
      profile: _string(json['profile']) ?? 'unknown',
      runs: [
        for (final run in _listOfMaps(json['runs'])) SuiteRun.fromJson(run),
      ],
    );
  }
}

final class SuiteRun {
  const SuiteRun({
    required this.scenario,
    required this.status,
    required this.artifact,
    required this.log,
  });

  final String scenario;
  final String status;
  final String? artifact;
  final String? log;

  factory SuiteRun.fromJson(Map<String, Object?> json) {
    return SuiteRun(
      scenario: _string(json['scenario']) ?? 'unknown',
      status: _string(json['status']) ?? 'unknown',
      artifact: _string(json['artifact']),
      log: _string(json['log']),
    );
  }
}

final class DecisionDocument {
  const DecisionDocument({
    required this.path,
    required this.verdict,
    required this.expectation,
    required this.summary,
  });

  final String path;
  final String verdict;
  final String expectation;
  final Map<String, Object?> summary;

  String get name => displayNameForPath(path);

  factory DecisionDocument.fromJson(String path, Map<String, Object?> json) {
    return DecisionDocument(
      path: path,
      verdict:
          _string(json['verdict']) ??
          _string(json['decision']) ??
          _string(json['status']) ??
          'unknown',
      expectation: _string(json['expectation']) ?? 'unknown',
      summary: _map(json['summary']),
    );
  }
}

final class WorkloadSummaryDocument {
  const WorkloadSummaryDocument({
    required this.path,
    required this.sourcePath,
    required this.traceHealth,
    required this.workloads,
  });

  final String path;
  final String? sourcePath;
  final TraceHealth traceHealth;
  final List<WorkloadRow> workloads;

  String get name => displayNameForPath(path);

  factory WorkloadSummaryDocument.fromJson(
    String path,
    Map<String, Object?> json,
  ) {
    final trace = _map(json['trace']);
    return WorkloadSummaryDocument(
      path: path,
      sourcePath: _string(json['source_path']),
      traceHealth: TraceHealth.fromJson(_map(trace['diagnostics'])),
      workloads: [
        for (final entry in _map(json['workloads']).entries)
          WorkloadRow.fromJson(entry.key, _map(entry.value)),
      ],
    );
  }
}

final class WorkloadRow {
  const WorkloadRow({
    required this.name,
    required this.iterations,
    required this.sampleCount,
    required this.operations,
    required this.hasMemory,
    required this.hasFanout,
  });

  final String name;
  final int iterations;
  final int sampleCount;
  final int operations;
  final bool hasMemory;
  final bool hasFanout;

  factory WorkloadRow.fromJson(String name, Map<String, Object?> json) {
    final samples = json['samples'];
    return WorkloadRow(
      name: name,
      iterations: _int(json['iterations']) ?? 0,
      sampleCount:
          _int(json['sample_count']) ??
          (samples is List<Object?> ? samples.length : 0),
      operations: _map(json['summary']).length,
      hasMemory: _map(json['memory']).isNotEmpty,
      hasFanout: _map(json['fanout_summary']).isNotEmpty,
    );
  }
}

final class GraphDataDocument {
  const GraphDataDocument({
    required this.path,
    required this.runId,
    required this.counts,
    required this.validationErrors,
  });

  final String path;
  final String? runId;
  final Map<String, int> counts;
  final List<String> validationErrors;

  String get name => displayNameForPath(path);

  factory GraphDataDocument.fromDirectory(String path) {
    final indexFile = File('$path/index.json');
    final decoded = _readJsonMap(indexFile);
    final counts = <String, int>{};
    for (final entry in _map(decoded['counts']).entries) {
      counts[entry.key] = _int(entry.value) ?? 0;
    }
    return GraphDataDocument(
      path: path,
      runId: _string(decoded['run_id']),
      counts: counts,
      validationErrors: validateGraphDataDirectory(path),
    );
  }
}

final class UnknownArtifact {
  const UnknownArtifact({required this.path, required this.schema});

  final String path;
  final String schema;

  String get name => displayNameForPath(path);
}

final class LoadIssue {
  const LoadIssue({required this.path, required this.message});

  final String path;
  final String message;
}

final class _WorkspaceLoader {
  final List<TraceDocument> _traces = [];
  final List<CompareDocument> _compares = [];
  final List<SuiteDocument> _suites = [];
  final List<DecisionDocument> _decisions = [];
  final List<WorkloadSummaryDocument> _workloads = [];
  final List<GraphDataDocument> _graphData = [];
  final List<UnknownArtifact> _unknownArtifacts = [];
  final List<LoadIssue> _issues = [];
  final Set<String> _seen = {};

  VisualizerWorkspace load(String rawPath) {
    final path = _absolutePath(rawPath);
    if (!FileSystemEntity.isFileSync(path) &&
        !FileSystemEntity.isDirectorySync(path)) {
      return VisualizerWorkspace(
        rootPath: path,
        traces: const [],
        compares: const [],
        suites: const [],
        decisions: const [],
        workloads: const [],
        graphData: const [],
        unknownArtifacts: const [],
        issues: [LoadIssue(path: path, message: 'Path does not exist')],
      );
    }

    _loadPath(path);
    return VisualizerWorkspace(
      rootPath: path,
      traces: List.unmodifiable(_traces),
      compares: List.unmodifiable(_compares),
      suites: List.unmodifiable(_suites),
      decisions: List.unmodifiable(_decisions),
      workloads: List.unmodifiable(_workloads),
      graphData: List.unmodifiable(_graphData),
      unknownArtifacts: List.unmodifiable(_unknownArtifacts),
      issues: List.unmodifiable(_issues),
    );
  }

  void _loadPath(String path) {
    if (FileSystemEntity.isDirectorySync(path)) {
      if (!_seen.add('dir:$path')) return;
      _loadDirectory(Directory(path));
    } else if (FileSystemEntity.isFileSync(path)) {
      _loadFile(File(path));
    }
  }

  void _loadDirectory(Directory directory) {
    final index = File('${directory.path}/index.json');
    if (index.existsSync()) {
      try {
        final decoded = _readJsonMap(index);
        if (decoded['schema'] == graphDataSchema) {
          _graphData.add(GraphDataDocument.fromDirectory(directory.path));
          return;
        }
      } on Object catch (error) {
        _issues.add(LoadIssue(path: index.path, message: error.toString()));
      }
    }

    final children = directory.listSync().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final child in children.whereType<Directory>()) {
      final childIndex = File('${child.path}/index.json');
      if (childIndex.existsSync()) {
        _loadPath(child.absolute.path);
      }
    }
    for (final child in children.whereType<File>()) {
      final path = child.path;
      if (path.endsWith('.json') ||
          path.endsWith('.tlt-region') ||
          path.endsWith('.tlt')) {
        _loadFile(child);
      }
    }
  }

  void _loadFile(File file) {
    final path = file.absolute.path;
    if (!_seen.add('file:$path')) return;
    try {
      if (path.endsWith('.tlt-region') || path.endsWith('.tlt')) {
        _traces.add(TraceDocument(path: path, trace: Trace.loadRegion(path)));
        return;
      }
      if (!path.endsWith('.json')) return;
      final json = _readJsonMap(file);
      switch (json['schema']) {
        case 'tracelite.compare.v1':
          _compares.add(CompareDocument.fromJson(path, json));
        case 'tracelite.suite.v1':
          final suite = SuiteDocument.fromJson(path, json);
          _suites.add(suite);
          _loadSuiteArtifacts(file.parent.path, suite);
        case benchmarkDecisionSchema:
          _decisions.add(DecisionDocument.fromJson(path, json));
        case 'tracelite.workload_summary.v1':
          _workloads.add(WorkloadSummaryDocument.fromJson(path, json));
        case graphDataSchema:
          _graphData.add(GraphDataDocument.fromDirectory(file.parent.path));
        case graphDatasetSchema:
          _unknownArtifacts.add(
            UnknownArtifact(path: path, schema: graphDatasetSchema),
          );
        case final String schema:
          _unknownArtifacts.add(UnknownArtifact(path: path, schema: schema));
        default:
          _unknownArtifacts.add(UnknownArtifact(path: path, schema: 'unknown'));
      }
    } on Object catch (error) {
      _issues.add(LoadIssue(path: path, message: error.toString()));
    }
  }

  void _loadSuiteArtifacts(String suiteDir, SuiteDocument suite) {
    for (final run in suite.runs) {
      final artifact = run.artifact;
      if (artifact == null || artifact.isEmpty) continue;
      final artifactPath = File(artifact).isAbsolute
          ? artifact
          : '$suiteDir/$artifact';
      if (FileSystemEntity.isFileSync(artifactPath)) {
        _loadPath(File(artifactPath).absolute.path);
      } else {
        _issues.add(
          LoadIssue(
            path: artifactPath,
            message: 'Suite artifact does not exist',
          ),
        );
      }
    }
  }
}

String displayNameForPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/').where((part) => part.isNotEmpty);
  return segments.isEmpty ? path : segments.last;
}

String formatNs(int ns) => formatDurationNs(ns);

String formatMeanNs(MetricStats? metric) {
  if (metric == null || metric.count == 0) return '-';
  return formatDurationNs(metric.mean.round());
}

String formatCountMean(MetricStats? metric) {
  if (metric == null || metric.count == 0) return '-';
  return _trim(metric.mean);
}

String formatCv(MetricStats? metric) {
  if (metric == null || metric.count == 0) return '-';
  return '${_trim(metric.cvPercent)}%';
}

String _absolutePath(String path) {
  if (path.trim().isEmpty) return Directory.current.absolute.path;
  final file = File(path);
  if (file.isAbsolute) return path;
  return file.absolute.path;
}

Map<String, Object?> _readJsonMap(File file) {
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map) {
    throw const FormatException('JSON root must be an object');
  }
  return Map<String, Object?>.from(decoded);
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

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return null;
}

double? _double(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return null;
}

String _trim(double value) {
  if (value >= 100) return value.toStringAsFixed(0);
  if (value >= 10) return value.toStringAsFixed(1);
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value.toStringAsFixed(2);
}
