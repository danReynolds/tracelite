import 'dart:convert';
import 'dart:io';

const String graphDataSchema = 'tracelite.graph_data.v1';
const String graphDatasetSchema = 'tracelite.graph_dataset.v1';

const List<String> graphDataDatasetNames = [
  'scenario_series',
  'peer_summary',
  'decision_summary',
  'decision_comparisons',
  'workload_summary',
  'workload_operations',
  'workload_memory',
  'workload_fanout',
];

final class GraphDataInput {
  const GraphDataInput({
    required this.path,
    required this.artifact,
    this.parentPath,
  });

  final String path;
  final String? parentPath;
  final Map<String, Object?> artifact;

  String get schema =>
      artifact['schema'] is String ? artifact['schema']! as String : 'unknown';

  Map<String, Object?> toJson() => {
        'path': path,
        if (parentPath != null) 'parent_path': parentPath,
        'schema': schema,
      };
}

Map<String, Object?> traceliteGraphDataBundle({
  List<GraphDataInput> compareArtifacts = const [],
  List<GraphDataInput> decisionArtifacts = const [],
  List<GraphDataInput> workloadSummaries = const [],
  String? runId,
}) {
  final scenarioSeries = <Map<String, Object?>>[];
  final peerSummary = <Map<String, Object?>>[];
  final decisionSummary = <Map<String, Object?>>[];
  final decisionComparisons = <Map<String, Object?>>[];
  final workloadSummaryRows = <Map<String, Object?>>[];
  final workloadOperations = <Map<String, Object?>>[];
  final workloadMemory = <Map<String, Object?>>[];
  final workloadFanout = <Map<String, Object?>>[];

  for (final input in compareArtifacts) {
    _addCompareRows(
      input: input,
      runId: runId,
      scenarioSeries: scenarioSeries,
      peerSummary: peerSummary,
    );
  }
  for (final input in decisionArtifacts) {
    _addDecisionRows(
      input: input,
      runId: runId,
      decisionSummary: decisionSummary,
      decisionComparisons: decisionComparisons,
    );
  }
  for (final input in workloadSummaries) {
    _addWorkloadRows(
      input: input,
      runId: runId,
      workloadSummaryRows: workloadSummaryRows,
      workloadOperations: workloadOperations,
      workloadMemory: workloadMemory,
      workloadFanout: workloadFanout,
    );
  }

  final sources = [
    for (final input in [
      ...compareArtifacts,
      ...decisionArtifacts,
      ...workloadSummaries,
    ])
      input.toJson(),
  ];

  return {
    'schema': graphDataSchema,
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    if (runId != null && runId.isNotEmpty) 'run_id': runId,
    'sources': sources,
    'datasets': {
      'scenario_series': scenarioSeries,
      'peer_summary': peerSummary,
      'decision_summary': decisionSummary,
      'decision_comparisons': decisionComparisons,
      'workload_summary': workloadSummaryRows,
      'workload_operations': workloadOperations,
      'workload_memory': workloadMemory,
      'workload_fanout': workloadFanout,
    },
  };
}

List<String> validateGraphDataDirectory(String path) {
  final errors = <String>[];
  final dir = Directory(path);
  if (!dir.existsSync()) {
    return ['graph-data directory does not exist: $path'];
  }

  final indexFile = File('${dir.path}/index.json');
  if (!indexFile.existsSync()) {
    return ['missing graph-data index: ${indexFile.path}'];
  }

  final index = _readJsonMap(indexFile, errors);
  if (index == null) return errors;

  _expectEqual(
    errors,
    'index.schema',
    index['schema'],
    graphDataSchema,
  );
  _expectString(errors, 'index.generated_at', index['generated_at']);
  final indexRunId = index['run_id'];
  if (indexRunId != null && indexRunId is! String) {
    errors.add('index.run_id must be a string when present');
  }
  final sources = index['sources'];
  if (sources is! List<Object?>) {
    errors.add('index.sources must be a list');
  } else {
    for (var i = 0; i < sources.length; i++) {
      final source = sources[i];
      if (source is! Map<String, Object?>) {
        errors.add('index.sources[$i] must be an object');
        continue;
      }
      _expectString(errors, 'index.sources[$i].path', source['path']);
      _expectString(errors, 'index.sources[$i].schema', source['schema']);
    }
  }

  final files = index['files'];
  final counts = index['counts'];
  final generatedAt =
      index['generated_at'] is String ? index['generated_at'] as String : null;
  final runId = indexRunId is String ? indexRunId : null;
  if (files is! Map<String, Object?>) {
    errors.add('index.files must be an object');
    return errors;
  }
  if (counts is! Map<String, Object?>) {
    errors.add('index.counts must be an object');
    return errors;
  }

  for (final dataset in graphDataDatasetNames) {
    final fileName = files[dataset];
    if (fileName is! String || fileName.isEmpty) {
      errors.add('index.files.$dataset must be a non-empty string');
      continue;
    }
    final expectedCount = counts[dataset];
    if (expectedCount is! int || expectedCount < 0) {
      errors.add('index.counts.$dataset must be a non-negative integer');
      continue;
    }

    final datasetFile = File('${dir.path}/$fileName');
    if (!datasetFile.existsSync()) {
      errors.add('missing dataset file for $dataset: ${datasetFile.path}');
      continue;
    }
    final artifact = _readJsonMap(datasetFile, errors);
    if (artifact == null) continue;
    _validateDatasetArtifact(
      errors: errors,
      dataset: dataset,
      fileName: fileName,
      artifact: artifact,
      expectedCount: expectedCount,
      expectedGeneratedAt: generatedAt,
      expectedRunId: runId,
    );
  }

  for (final dataset in files.keys) {
    if (!graphDataDatasetNames.contains(dataset)) {
      errors.add('index.files contains unknown dataset: $dataset');
    }
  }
  for (final dataset in counts.keys) {
    if (!graphDataDatasetNames.contains(dataset)) {
      errors.add('index.counts contains unknown dataset: $dataset');
    }
  }

  return errors;
}

void _validateDatasetArtifact({
  required List<String> errors,
  required String dataset,
  required String fileName,
  required Map<String, Object?> artifact,
  required int expectedCount,
  required String? expectedGeneratedAt,
  required String? expectedRunId,
}) {
  final prefix = '$fileName';
  _expectEqual(
      errors, '$prefix.schema', artifact['schema'], graphDatasetSchema);
  _expectEqual(errors, '$prefix.dataset', artifact['dataset'], dataset);
  _expectEqual(
    errors,
    '$prefix.generated_at',
    artifact['generated_at'],
    expectedGeneratedAt,
  );
  if (expectedRunId != null) {
    _expectEqual(errors, '$prefix.run_id', artifact['run_id'], expectedRunId);
  }
  final rows = artifact['rows'];
  if (rows is! List<Object?>) {
    errors.add('$prefix.rows must be a list');
    return;
  }
  if (rows.length != expectedCount) {
    errors.add(
      '$prefix row count ${rows.length} does not match index count '
      '$expectedCount',
    );
  }
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    if (row is! Map<String, Object?>) {
      errors.add('$prefix.rows[$i] must be an object');
      continue;
    }
    _validateGraphDataRow(errors, '$prefix.rows[$i]', dataset, row);
  }
}

void _validateGraphDataRow(
  List<String> errors,
  String prefix,
  String dataset,
  Map<String, Object?> row,
) {
  switch (dataset) {
    case 'scenario_series':
      _expectString(errors, '$prefix.scenario', row['scenario']);
      _expectString(errors, '$prefix.peer', row['peer']);
      _expectString(errors, '$prefix.metric', row['metric']);
      _expectString(errors, '$prefix.statistic', row['statistic']);
      _expectNum(errors, '$prefix.value', row['value']);
    case 'peer_summary':
      _expectString(errors, '$prefix.scenario', row['scenario']);
      _expectString(errors, '$prefix.peer', row['peer']);
      _expectString(errors, '$prefix.peer_status', row['peer_status']);
    case 'decision_summary':
      _expectString(errors, '$prefix.decision', row['decision']);
    case 'decision_comparisons':
      _expectString(errors, '$prefix.gate', row['gate']);
    case 'workload_summary':
      _expectString(errors, '$prefix.workload', row['workload']);
    case 'workload_operations':
      _expectString(errors, '$prefix.workload', row['workload']);
      _expectString(errors, '$prefix.operation', row['operation']);
      _expectString(errors, '$prefix.metric', row['metric']);
      _expectNum(errors, '$prefix.value', row['value']);
    case 'workload_memory':
      _expectString(errors, '$prefix.workload', row['workload']);
      _expectString(errors, '$prefix.metric', row['metric']);
      _expectNum(errors, '$prefix.value', row['value']);
    case 'workload_fanout':
      _expectString(errors, '$prefix.workload', row['workload']);
      _expectString(errors, '$prefix.metric', row['metric']);
      _expectString(errors, '$prefix.statistic', row['statistic']);
      _expectNum(errors, '$prefix.value', row['value']);
  }
}

void _addCompareRows({
  required GraphDataInput input,
  required String? runId,
  required List<Map<String, Object?>> scenarioSeries,
  required List<Map<String, Object?>> peerSummary,
}) {
  final artifact = input.artifact;
  final scenario = artifact['scenario'] as String? ?? 'unknown';
  final rows = artifact['rows'];
  final repetitions = artifact['repetitions'];
  final workload = artifact['workload'];
  final peers = artifact['peers'];
  if (peers is! List<Object?>) return;

  for (final peerObj in peers.whereType<Map<String, Object?>>()) {
    final peer = peerObj['peer'] as String? ?? 'unknown';
    final summary = peerObj['summary'];
    if (summary is! Map<String, Object?>) continue;
    final baseRow = {
      if (runId != null && runId.isNotEmpty) 'run_id': runId,
      'source_path': input.path,
      if (input.parentPath != null) 'source_parent_path': input.parentPath,
      'scenario': scenario,
      if (rows is int) 'rows': rows,
      if (repetitions is int) 'repetitions': repetitions,
      'peer': peer,
      'peer_status': peerObj['status'],
      'successful_repetitions': peerObj['successful_repetitions'],
      'failed_repetitions': peerObj['failed_repetitions'],
      'unsupported_repetitions': peerObj['unsupported_repetitions'],
    };
    final capabilities = peerObj['capabilities'];
    peerSummary.add({
      ...baseRow,
      if (workload is Map<String, Object?>) 'workload': workload,
      if (capabilities is List<Object?>) 'capabilities': capabilities,
      'elapsed_mean_ns': _metricMean(summary, 'elapsed_ns'),
      'measured_elapsed_mean_ns': _metricMean(summary, 'measured_elapsed_ns'),
      'sqlite3_step_total_mean_ns':
          _metricMean(summary, 'sqlite3_step_total_ns'),
      'sqlite3_step_count_mean': _metricMean(summary, 'sqlite3_step_count'),
      'trace_span_total_mean_ns': _metricMean(summary, 'trace_span_total_ns'),
      'events_mean': _metricMean(summary, 'events'),
      'spans_mean': _metricMean(summary, 'spans'),
      'dropped_events_max': _metricValue(summary, 'dropped_events', 'max'),
      'unmatched_begin_events_max':
          _metricValue(summary, 'unmatched_begin_events', 'max'),
      'unmatched_end_events_max':
          _metricValue(summary, 'unmatched_end_events', 'max'),
    });

    for (final metricEntry in summary.entries) {
      final stats = metricEntry.value;
      if (stats is! Map<String, Object?>) continue;
      for (final statEntry in stats.entries) {
        final value = statEntry.value;
        if (value is! num) continue;
        scenarioSeries.add({
          ...baseRow,
          'metric': metricEntry.key,
          'statistic': statEntry.key,
          'value': value,
          'unit': _unitForMetric(metricEntry.key),
        });
      }
    }
  }
}

void _addDecisionRows({
  required GraphDataInput input,
  required String? runId,
  required List<Map<String, Object?>> decisionSummary,
  required List<Map<String, Object?>> decisionComparisons,
}) {
  final artifact = input.artifact;
  final gates = artifact['gates'];
  final policy = artifact['policy'];
  final traceHealth =
      gates is Map<String, Object?> ? gates['trace_health'] : null;
  final primary = gates is Map<String, Object?> ? gates['primary'] : null;
  final guardrails = gates is Map<String, Object?> ? gates['guardrails'] : null;
  final baseRow = {
    if (runId != null && runId.isNotEmpty) 'run_id': runId,
    'source_path': input.path,
    if (input.parentPath != null) 'source_parent_path': input.parentPath,
  };
  decisionSummary.add({
    ...baseRow,
    'decision': artifact['decision'],
    'baseline_path': artifact['baseline_path'],
    'candidate_path': artifact['candidate_path'],
    if (policy is Map<String, Object?>) ...{
      'expectation': policy['expectation'],
      'primary_peer': policy['primary_peer'],
      'primary_metric': policy['primary_metric'],
      'primary_threshold_percent': policy['primary_threshold_percent'],
      'max_regression_percent': policy['max_regression_percent'],
      'max_cv_percent': policy['max_cv_percent'],
    },
    'trace_health_status': _gateStatus(traceHealth),
    'primary_status': _gateStatus(primary),
    'guardrails_status': _gateStatus(guardrails),
  });

  _addDecisionComparisonRows(
    rows: decisionComparisons,
    baseRow: baseRow,
    gate: 'primary',
    entries: _gateList(primary, 'comparisons'),
  );
  _addDecisionComparisonRows(
    rows: decisionComparisons,
    baseRow: baseRow,
    gate: 'guardrails',
    entries: _gateList(guardrails, 'comparisons'),
  );
  _addDecisionComparisonRows(
    rows: decisionComparisons,
    baseRow: baseRow,
    gate: 'trace_health',
    entries: _gateList(traceHealth, 'issues'),
  );
}

void _addDecisionComparisonRows({
  required List<Map<String, Object?>> rows,
  required Map<String, Object?> baseRow,
  required String gate,
  required List<Map<String, Object?>> entries,
}) {
  for (final entry in entries) {
    rows.add({
      ...baseRow,
      'gate': gate,
      'role': entry['role'],
      'scenario': entry['scenario'],
      'peer': entry['peer'],
      'metric': entry['metric'],
      'status': entry['status'],
      'gate_effect': entry['gate_effect'],
      'baseline_status': entry['baseline_status'],
      'candidate_status': entry['candidate_status'],
      'baseline_mean': entry['baseline_mean'],
      'candidate_mean': entry['candidate_mean'],
      'delta': entry['delta'],
      'change_percent': entry['change_percent'],
      'max_cv_percent': entry['max_cv_percent'],
      'nonparametric_p_value': entry['nonparametric_p_value'],
    });
  }
}

void _addWorkloadRows({
  required GraphDataInput input,
  required String? runId,
  required List<Map<String, Object?>> workloadSummaryRows,
  required List<Map<String, Object?>> workloadOperations,
  required List<Map<String, Object?>> workloadMemory,
  required List<Map<String, Object?>> workloadFanout,
}) {
  final workloads = input.artifact['workloads'];
  if (workloads is! Map<String, Object?>) return;
  for (final workloadEntry in workloads.entries) {
    final workload = workloadEntry.value;
    if (workload is! Map<String, Object?>) continue;
    final workloadName = workloadEntry.key;
    final baseRow = {
      if (runId != null && runId.isNotEmpty) 'run_id': runId,
      'source_path': input.path,
      if (input.parentPath != null) 'source_parent_path': input.parentPath,
      'workload': workloadName,
    };
    final summary = workload['summary'];
    workloadSummaryRows.add({
      ...baseRow,
      'iterations': workload['iterations'],
      'sample_count': workload['sample_count'],
      'operation_count': summary is Map ? summary.length : 0,
      'has_memory': workload['memory'] is Map,
      'has_fanout': workload['fanout_summary'] is Map,
    });
    if (summary is Map<String, Object?>) {
      for (final operationEntry in summary.entries) {
        final stats = operationEntry.value;
        if (stats is! Map<String, Object?>) continue;
        for (final statEntry in stats.entries) {
          final value = statEntry.value;
          if (value is! num) continue;
          workloadOperations.add({
            ...baseRow,
            'operation': operationEntry.key,
            'metric': statEntry.key,
            'value': value,
            'unit': _unitForMetric(statEntry.key),
          });
        }
      }
    }
    final memory = workload['memory'];
    if (memory is Map<String, Object?>) {
      _addFlattenedMetricRows(
        rows: workloadMemory,
        baseRow: baseRow,
        values: memory,
      );
    }
    final fanout = workload['fanout_summary'];
    if (fanout is Map<String, Object?>) {
      for (final metricEntry in fanout.entries) {
        final stats = metricEntry.value;
        if (stats is! Map<String, Object?>) continue;
        for (final statEntry in stats.entries) {
          final value = statEntry.value;
          if (value is! num) continue;
          workloadFanout.add({
            ...baseRow,
            'metric': metricEntry.key,
            'statistic': statEntry.key,
            'value': value,
            'unit': _unitForMetric(metricEntry.key),
          });
        }
      }
    }
  }
}

void _addFlattenedMetricRows({
  required List<Map<String, Object?>> rows,
  required Map<String, Object?> baseRow,
  required Map<String, Object?> values,
  String prefix = '',
}) {
  for (final entry in values.entries) {
    final name = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
    final value = entry.value;
    if (value is num) {
      rows.add({
        ...baseRow,
        'metric': name,
        'value': value,
        'unit': _unitForMetric(name),
      });
    } else if (value is Map<String, Object?>) {
      _addFlattenedMetricRows(
        rows: rows,
        baseRow: baseRow,
        values: value,
        prefix: name,
      );
    }
  }
}

String? _gateStatus(Object? gate) =>
    gate is Map<String, Object?> ? gate['status'] as String? : null;

List<Map<String, Object?>> _gateList(Object? gate, String key) {
  if (gate is! Map<String, Object?>) return const [];
  final value = gate[key];
  if (value is! List<Object?>) return const [];
  return value.whereType<Map<String, Object?>>().toList();
}

Object? _metricMean(Map<String, Object?> summary, String metric) =>
    _metricValue(summary, metric, 'mean');

Object? _metricValue(
  Map<String, Object?> summary,
  String metric,
  String statistic,
) {
  final stats = summary[metric];
  if (stats is! Map<String, Object?>) return null;
  return stats[statistic];
}

String _unitForMetric(String metric) {
  if (metric.endsWith('_ns')) return 'ns';
  if (metric.endsWith('_us')) return 'us';
  if (metric.endsWith('_ms')) return 'ms';
  if (metric.endsWith('_mb')) return 'mb';
  if (metric.contains('bytes')) return 'bytes';
  if (metric == 'cv' || metric.endsWith('_percent')) return 'ratio';
  return 'count';
}

Map<String, Object?>? _readJsonMap(File file, List<String> errors) {
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, Object?>) return decoded;
    errors.add('${file.path} must contain a JSON object');
  } on FormatException catch (error) {
    errors.add('${file.path} is not valid JSON: ${error.message}');
  } on IOException catch (error) {
    errors.add('could not read ${file.path}: $error');
  }
  return null;
}

void _expectEqual(
  List<String> errors,
  String field,
  Object? actual,
  Object? expected,
) {
  if (actual != expected) {
    errors.add('$field expected `$expected`, got `$actual`');
  }
}

void _expectString(List<String> errors, String field, Object? value) {
  if (value is! String || value.isEmpty) {
    errors.add('$field must be a non-empty string');
  }
}

void _expectNum(List<String> errors, String field, Object? value) {
  if (value is! num) {
    errors.add('$field must be numeric');
  }
}
