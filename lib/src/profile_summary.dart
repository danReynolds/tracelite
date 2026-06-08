import 'dart:math' as math;

import 'trace.dart';

Map<String, Object?> traceWorkloadSummaryArtifact(Trace trace) {
  final workloadArtifacts = <String, Map<String, Object?>>{};
  final operationSamplesByWorkload = <String, Map<String, List<int>>>{};

  for (final workload in trace.workloads) {
    final samplesByOp = <String, List<int>>{};
    final profileSamples = workload.spans
        .where(
            (span) => trace.spanName(span.spanId).endsWith('.profile.sample'))
        .toList();
    final sampleSource =
        profileSamples.isEmpty ? workload.spans : profileSamples;
    for (final span in sampleSource) {
      final op = profileSamples.isEmpty
          ? _operationForSpanName(trace.spanName(span.spanId))
          : _profileSampleOperation(trace, span);
      if (op == null) continue;
      final durationUs = profileSamples.isEmpty || span.endArgs.isEmpty
          ? span.durationNs ~/ 1000
          : span.endArgs.first;
      samplesByOp.putIfAbsent(op, () => <int>[]).add(durationUs);
    }
    operationSamplesByWorkload[workload.name] = samplesByOp;
  }

  final noopSummary = _summarizeOperationSamples(
    operationSamplesByWorkload['noop'] ?? const {},
  );
  final readerFloor =
      (noopSummary['select'] as Map<String, Object?>?)?['median_us'] as int?;
  final writerFloor =
      (noopSummary['execute'] as Map<String, Object?>?)?['median_us'] as int?;

  for (final workload in trace.workloads) {
    final isNoop = workload.name == 'noop';
    final profileSamples = _profileSampleArtifacts(trace, workload);
    final summary = _summarizeOperationSamples(
      operationSamplesByWorkload[workload.name] ?? const {},
      readerFloor: isNoop ? null : readerFloor,
      writerFloor: isNoop ? null : writerFloor,
    );
    final artifact = <String, Object?>{
      'iterations': workload.iterations,
      'sample_count': workload.sampleCount,
      'samples': profileSamples.isEmpty ? workload.sampleCount : profileSamples,
      'summary': summary,
    };
    final memory = _memoryArtifact(trace, workload);
    if (memory.isNotEmpty) {
      artifact['memory'] = memory;
    }
    final fanout = _fanoutArtifact(trace, workload);
    if (fanout.isNotEmpty) {
      artifact['fanout_summary'] = fanout;
    }
    workloadArtifacts[workload.name] = artifact;
  }

  return {
    'schema': 'tracelite.workload_summary.v1',
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'source_path': trace.header.sourcePath,
    'trace': {
      'events': trace.events.length,
      'producers': trace.tracks.length,
      'diagnostics': {
        'dropped_events': trace.diagnostics.droppedEvents,
        'unmatched_begin_events': trace.diagnostics.unmatchedBeginEvents,
        'unmatched_end_events': trace.diagnostics.unmatchedEndEvents,
      },
    },
    if (readerFloor != null || writerFloor != null)
      'noop_floors': {
        if (readerFloor != null) 'reader_us': readerFloor,
        if (writerFloor != null) 'writer_us': writerFloor,
      },
    'workloads': workloadArtifacts,
  };
}

String traceWorkloadSummaryMarkdown(Map<String, Object?> artifact) {
  final workloads =
      (artifact['workloads'] as Map<String, Object?>?) ?? const {};
  final buffer = StringBuffer()
    ..writeln('# tracelite workload summary')
    ..writeln()
    ..writeln(
        '| workload | iterations | samples | operations | memory | fanout |')
    ..writeln('|---|---:|---:|---:|---|---|');

  for (final entry in workloads.entries) {
    final workload = entry.value as Map<String, Object?>;
    final summary = workload['summary'] as Map<String, Object?>? ?? const {};
    final memory = workload['memory'] as Map<String, Object?>?;
    final fanout = workload['fanout_summary'] as Map<String, Object?>?;
    final samples = workload['samples'];
    final sampleCount = workload['sample_count'] ??
        (samples is List<Object?> ? samples.length : samples);
    buffer.writeln(
      '| `${_markdownCell(entry.key)}` | '
      '${workload['iterations'] ?? '-'} | '
      '${sampleCount ?? '-'} | '
      '${summary.length} | '
      '${memory == null ? '-' : 'yes'} | '
      '${fanout == null ? '-' : 'yes'} |',
    );
  }

  final floors = artifact['noop_floors'] as Map<String, Object?>?;
  if (floors != null && floors.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Noop Floors')
      ..writeln()
      ..writeln('| floor | value |')
      ..writeln('|---|---:|');
    for (final entry in floors.entries) {
      buffer.writeln('| `${entry.key}` | ${entry.value}us |');
    }
  }

  return buffer.toString();
}

String? _operationForSpanName(String name) {
  if (name.endsWith('.database.select')) return 'select';
  if (name.endsWith('.database.select_bytes')) return 'selectBytes';
  if (name.endsWith('.database.execute')) return 'execute';
  if (name.endsWith('.database.execute_batch')) return 'executeBatch';
  return null;
}

String? _profileSampleOperation(Trace trace, TraceSpan span) {
  if (span.beginArgs.isEmpty) return null;
  return trace.strings[span.beginArgs.first];
}

List<Map<String, Object?>> _profileSampleArtifacts(
  Trace trace,
  TraceWorkload workload,
) {
  final result = <Map<String, Object?>>[];
  for (final span in workload.spans.where(
    (span) => trace.spanName(span.spanId).endsWith('.profile.sample'),
  )) {
    final op = _profileSampleOperation(trace, span);
    if (op == null || span.beginArgs.length < 2) continue;
    final sql = trace.strings[span.beginArgs[1]];
    if (sql == null) continue;
    final paramCount = span.beginArgs.length > 2 ? span.beginArgs[2] : 0;
    final totalUs =
        span.endArgs.isNotEmpty ? span.endArgs.first : span.durationNs ~/ 1000;
    final artifact = <String, Object?>{
      'op': op,
      'sql': _truncateSql(sql),
      'total_us': totalUs,
      'params': paramCount,
    };
    switch (op) {
      case 'select':
      case 'selectBytes':
        if (span.endArgs.length > 1) {
          artifact['rows'] = span.endArgs[1];
        }
      case 'executeBatch':
        if (span.beginArgs.length > 3) {
          artifact['batch_size'] = span.beginArgs[3];
        }
    }
    final tagIndex = op == 'executeBatch' ? 4 : 3;
    if (span.beginArgs.length > tagIndex) {
      final tag = trace.strings[span.beginArgs[tagIndex]];
      if (tag != null && tag.isNotEmpty) {
        artifact['tag'] = tag;
      }
    }
    result.add(artifact);
  }
  return result;
}

Map<String, Object?> _summarizeOperationSamples(
  Map<String, List<int>> samplesByOp, {
  int? readerFloor,
  int? writerFloor,
}) {
  final summary = <String, Object?>{};
  for (final entry in samplesByOp.entries) {
    final sorted = [...entry.value]..sort();
    if (sorted.isEmpty) continue;
    final median = _percentile(sorted, 0.50);
    final floor = switch (entry.key) {
      'select' || 'selectBytes' => readerFloor,
      _ => writerFloor,
    };
    summary[entry.key] = {
      'count': sorted.length,
      'min_us': sorted.first,
      'median_us': median,
      'p90_us': _percentile(sorted, 0.90),
      'p99_us': _percentile(sorted, 0.99),
      'max_us': sorted.last,
      'mean_us': (sorted.reduce((a, b) => a + b) / sorted.length).round(),
      if (floor != null) 'work_us_median': math.max(0, median - floor),
      if (floor != null) 'dispatch_floor_us': floor,
    };
  }
  return summary;
}

Map<String, Object?> _memoryArtifact(Trace trace, TraceWorkload workload) {
  final byName = _counterValuesByName(trace, workload);
  final memory = <String, Object?>{};

  final rssBefore = _first(_counterValuesForSuffix(byName, 'rss_before_bytes'));
  final rssAfter = _first(_counterValuesForSuffix(byName, 'rss_after_bytes'));
  final rssPeak = _first(_counterValuesForSuffix(byName, 'rss_peak_bytes'));
  if (rssBefore != null && rssAfter != null && rssPeak != null) {
    final beforeMb = _mb(rssBefore);
    final afterMb = _mb(rssAfter);
    memory['rss_before_mb'] = beforeMb;
    memory['rss_after_mb'] = afterMb;
    memory['rss_peak_mb'] = _mb(rssPeak);
    memory['rss_delta_mb'] = _roundMb(afterMb - beforeMb);
  }

  final diagnosticsBefore = <String, int>{};
  final diagnosticsAfter = <String, int>{};
  final diagnosticsDelta = <String, int>{};
  for (final metric in _diagnosticMetricSuffixes.entries) {
    final values = _counterValuesForSuffix(byName, metric.key);
    if (values == null || values.isEmpty) continue;
    diagnosticsBefore[metric.value] = values.first;
    diagnosticsAfter[metric.value] = values.last;
    diagnosticsDelta['${metric.value}_delta'] = values.last - values.first;
  }
  if (diagnosticsBefore.isNotEmpty) {
    memory['diagnostics_before'] = diagnosticsBefore;
    memory['diagnostics_after'] = diagnosticsAfter;
    memory['diagnostics_delta'] = diagnosticsDelta;
  }

  final profileDelta = <String, int>{};
  for (final metric in _profileCounterMetricSuffixes.entries) {
    final values = _counterValuesForSuffix(byName, metric.key);
    if (values == null || values.length < 2) continue;
    profileDelta[metric.value] = values.last - values.first;
  }
  if (profileDelta.isNotEmpty) {
    memory['profile_counters_delta'] = profileDelta;
    memory['allocation_delta'] = {
      if (profileDelta.containsKey('rows_decoded'))
        'rows_decoded': profileDelta['rows_decoded'],
      if (profileDelta.containsKey('cells_decoded'))
        'cells_decoded': profileDelta['cells_decoded'],
    };
  }

  return memory;
}

Map<String, Object?> _fanoutArtifact(Trace trace, TraceWorkload workload) {
  final byName = _counterValuesByName(trace, workload);
  final result = <String, Object?>{};
  for (final metric in _fanoutMetricSuffixes.entries) {
    final values = _counterValuesForSuffix(byName, metric.key);
    if (values == null || values.isEmpty) continue;
    result[metric.value] = _summarizeValues(values);
  }
  return result;
}

Map<String, List<int>> _counterValuesByName(
  Trace trace,
  TraceWorkload workload,
) {
  final byName = <String, List<int>>{};
  for (final event in workload.counters) {
    if (event.args.isEmpty) continue;
    final name = trace.spanName(event.spanId);
    byName.putIfAbsent(name, () => <int>[]).add(event.args.first);
  }
  return byName;
}

List<int>? _counterValuesForSuffix(
  Map<String, List<int>> byName,
  String suffix,
) {
  final values = <int>[];
  for (final entry in byName.entries) {
    if (entry.key == suffix || entry.key.endsWith('.$suffix')) {
      values.addAll(entry.value);
    }
  }
  return values.isEmpty ? null : values;
}

Map<String, Object?> _summarizeValues(List<int> values) {
  final sorted = [...values]..sort();
  return {
    'count': sorted.length,
    'min': sorted.first,
    'median': _percentile(sorted, 0.50),
    'p90': _percentile(sorted, 0.90),
    'p99': _percentile(sorted, 0.99),
    'max': sorted.last,
    'mean': (sorted.reduce((a, b) => a + b) / sorted.length).round(),
  };
}

int _percentile(List<int> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final idx = ((sorted.length - 1) * p.clamp(0.0, 1.0)).round();
  return sorted[idx];
}

int? _first(List<int>? values) =>
    values == null || values.isEmpty ? null : values.first;

double _mb(int bytes) => _roundMb(bytes / (1024 * 1024));

double _roundMb(double value) => double.parse(value.toStringAsFixed(3));

String _markdownCell(String value) => value.replaceAll('|', '\\|');

String _truncateSql(String sql) =>
    sql.length > 80 ? '${sql.substring(0, 77)}...' : sql;

const _diagnosticMetricSuffixes = {
  'sqlite_page_cache_bytes': 'sqlite_page_cache_bytes',
  'sqlite_schema_bytes': 'sqlite_schema_bytes',
  'sqlite_stmt_bytes': 'sqlite_stmt_bytes',
  'wal_bytes': 'wal_bytes',
  'stream_count': 'stream_count',
  'reader_busy': 'reader_busy',
};

const _profileCounterMetricSuffixes = {
  'profile.rows_decoded': 'rows_decoded',
  'profile.cells_decoded': 'cells_decoded',
  'profile.invalidate_us': 'invalidate_us',
  'profile.invalidate_count': 'invalidate_count',
  'profile.intersection_us': 'intersection_us',
  'profile.intersection_entries': 'intersection_entries',
  'profile.dispatcher_parked_total': 'dispatcher_parked_total',
  'profile.dispatcher_wake_retry_total': 'dispatcher_wake_retry_total',
  'profile.dispatcher_max_parked_concurrent':
      'dispatcher_max_parked_concurrent',
};

const _fanoutMetricSuffixes = {
  'fanout.writer_us': 'writer_us',
  'fanout.yield_us': 'yield_us',
  'fanout.total_us': 'total_us',
  'fanout.invalidate_us': 'invalidate_us',
  'fanout.intersection_us': 'intersection_us',
  'fanout.intersection_entries': 'intersection_entries',
};
