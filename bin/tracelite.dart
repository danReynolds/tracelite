import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:tracelite/tracelite.dart';

import 'src/peer.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    _usage(exitCode: args.isEmpty ? 64 : 0);
  }

  final command = args.first;
  switch (command) {
    case 'report':
      _report(args.skip(1).toList());
    case 'workload-summary':
      _workloadSummary(args.skip(1).toList());
    case 'compare':
      await _compare(args.skip(1).toList());
    case 'diff':
      _diff(args.skip(1).toList());
    case 'decision':
      _decision(args.skip(1).toList());
    case 'export-graph-data':
      _exportGraphData(args.skip(1).toList());
    case 'suite':
      await _suite(args.skip(1).toList());
    case 'calibrate':
      await _calibrate(args.skip(1).toList());
    case 'create-region':
      _createRegion(args.skip(1).toList());
    case '_run-peer':
      await _runPeer(args.skip(1).toList());
    default:
      stderr.writeln('unknown command: $command');
      _usage();
  }
}

void _createRegion(List<String> args) {
  final options = _parseOptions(args);
  final out = options['out'];
  if (out == null || out.isEmpty) {
    stderr.writeln('create-region requires --out=path');
    _usage();
  }
  final maxProducers = _positiveIntOption(options, 'max-producers', 8);
  final stringPoolBytes = _positiveIntOption(
    options,
    'string-pool-bytes',
    kDefaultStringPoolSize,
  );
  final ringDataWords = _positivePowerOfTwoOption(
    options,
    'ring-data-words',
    kDefaultRingDataWords,
  );
  File(out).parent.createSync(recursive: true);
  TraceRegion.createFile(
    out,
    maxProducers: maxProducers,
    stringPoolSize: stringPoolBytes,
    ringDataWords: ringDataWords,
  );
  stdout.writeln('Created tracelite region: $out');
  stdout.writeln('  max_producers: $maxProducers');
  stdout.writeln('  string_pool_bytes: $stringPoolBytes');
  stdout.writeln('  ring_data_words: $ringDataWords');
}

void _workloadSummary(List<String> args) {
  if (args.isEmpty || args.first.startsWith('--')) {
    stderr.writeln('workload-summary expects a region or trace path');
    _usage();
  }
  final path = args.first;
  final options = _parseOptions(args.skip(1).toList());
  final trace = Trace.loadRegion(path);
  final artifact = traceWorkloadSummaryArtifact(trace);
  final outJson = options['out-json'];
  if (outJson != null && outJson.isNotEmpty) {
    const encoder = JsonEncoder.withIndent('  ');
    File(outJson)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${encoder.convert(artifact)}\n');
  }
  stdout.write(traceWorkloadSummaryMarkdown(artifact));
}

Future<void> _suite(List<String> args) async {
  final options = _parseOptions(args);
  final profileName = options['profile'] ?? 'ci';
  late final _SuiteProfile profile;
  try {
    profile = _suiteProfile(profileName);
  } on ArgumentError {
    stderr.writeln('--profile must be ci or production');
    exit(64);
  }
  final interfaces = options['interfaces'] ?? defaultPeerNames.join(',');
  final outDir = Directory(options['out-dir'] ?? 'build/tracelite-suite');
  outDir.createSync(recursive: true);

  final runs = <Map<String, Object?>>[];
  stdout
    ..writeln('# tracelite suite')
    ..writeln()
    ..writeln('Profile: `$profileName`')
    ..writeln('Interfaces: `$interfaces`')
    ..writeln('Out dir: `${outDir.path}`')
    ..writeln()
    ..writeln('| scenario | rows | repetitions | status | artifact |')
    ..writeln('|---|---:|---:|---|---|');

  var failed = false;
  for (final scenario in profile.scenarios) {
    final artifactPath = '${outDir.path}/${scenario.name}.json';
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'compare',
        '--scenario=${scenario.name}',
        '--interfaces=$interfaces',
        '--rows=${scenario.rows}',
        '--repetitions=${scenario.repetitions}',
        '--out-json=$artifactPath',
      ],
      workingDirectory: Directory.current.path,
    );
    final status = result.exitCode == 0 ? 'ok' : 'failed';
    if (result.exitCode != 0) failed = true;
    final logPath = '${outDir.path}/${scenario.name}.log';
    File(logPath).writeAsStringSync(
      'stdout:\n${result.stdout}\n\nstderr:\n${result.stderr}\n',
    );
    runs.add({
      'scenario': scenario.name,
      'rows': scenario.rows,
      'repetitions': scenario.repetitions,
      'artifact': artifactPath,
      'log': logPath,
      'exit_code': result.exitCode,
      'status': status,
    });
    stdout.writeln(
      '| `${scenario.name}` | ${scenario.rows} | '
      '${scenario.repetitions} | $status | `$artifactPath` |',
    );
  }

  final manifestPath = '${outDir.path}/manifest.json';
  const encoder = JsonEncoder.withIndent('  ');
  File(manifestPath).writeAsStringSync(
    '${encoder.convert({
          'schema': 'tracelite.suite.v1',
          'generated_at': DateTime.now().toUtc().toIso8601String(),
          'profile': profileName,
          'description': profile.description,
          'interfaces':
              interfaces.split(',').map((name) => name.trim()).toList(),
          'runs': runs,
        })}\n',
  );
  stdout
    ..writeln()
    ..writeln('Manifest: `$manifestPath`');
  if (failed) {
    exitCode = 65;
  }
}

void _report(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('report expects exactly one region or trace path');
    _usage();
  }
  final path = args.single;
  final trace = Trace.loadRegion(path);
  stdout.write(trace.toMarkdownReport());
}

Future<void> _compare(List<String> args) async {
  final options = _parseOptions(args);
  final scenario = options['scenario'] ?? narrowBatchInsertScenario;
  final interfaces = (options['interfaces'] ?? defaultPeerNames.join(','))
      .split(',')
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toList();
  final rows = _positiveIntOption(options, 'rows', 100);
  final repetitions = _positiveIntOption(options, 'repetitions', 1);
  final outJson = options['out-json'];
  final ringDataWords = _ringWordsForScenario(scenario, rows);

  final shim = File('build/libsqlite_traced.dylib');
  if (!shim.existsSync()) {
    stderr.writeln('missing ${shim.path}; build it with:');
    stderr.writeln('  cc -dynamiclib -O2 -Inative native/tracelite_runtime.c '
        'native/shim_sqlite3.c -Wl,-reexport-lsqlite3 '
        '-o build/libsqlite_traced.dylib');
    exit(66);
  }
  final resolverShim = File('libsqlite_traced.dylib');
  resolverShim.writeAsBytesSync(shim.readAsBytesSync());

  final tempRoot = Directory.systemTemp.createTempSync('tracelite-compare-');
  try {
    final results = <_PeerTraceResult>[];
    for (final peer in interfaces) {
      for (var repetition = 1; repetition <= repetitions; repetition++) {
        final regionPath = '${tempRoot.path}/$peer-r$repetition.tlt-region';
        final databasePath = '${tempRoot.path}/$peer-r$repetition.db';
        final metricsPath = '${tempRoot.path}/$peer-r$repetition.metrics.json';
        TraceRegion.createFile(
          regionPath,
          ringDataWords: ringDataWords,
        );

        final stopwatch = Stopwatch()..start();
        final child = await Process.run(
          Platform.resolvedExecutable,
          [
            'run',
            'bin/tracelite.dart',
            '_run-peer',
            '--peer=$peer',
            '--scenario=$scenario',
            '--database=$databasePath',
            '--rows=$rows',
            '--metrics=$metricsPath',
          ],
          environment: {
            'TRACELITE_REGION': regionPath,
            'DYLD_LIBRARY_PATH': Directory.current.absolute.path,
            'LD_LIBRARY_PATH': Directory.current.absolute.path,
          },
        );
        stopwatch.stop();
        final metrics = _readPeerMetrics(metricsPath);
        if (metrics.status == 'unsupported') {
          results.add(
            _PeerTraceResult.unsupported(
              peer: peer,
              repetition: repetition,
              metrics: metrics,
              childElapsedNs: stopwatch.elapsedMicroseconds * 1000,
            ),
          );
          continue;
        }

        if (child.exitCode != 0) {
          results.add(
            _PeerTraceResult.failed(
              peer: peer,
              repetition: repetition,
              elapsedNs: 0,
              childElapsedNs: stopwatch.elapsedMicroseconds * 1000,
              stderr: child.stderr.toString(),
              stdout: child.stdout.toString(),
            ),
          );
          continue;
        }

        final trace = Trace.loadRegion(regionPath);
        results.add(
          _PeerTraceResult(
            peer: peer,
            repetition: repetition,
            trace: trace,
            metrics: _readPeerMetrics(metricsPath),
            childElapsedNs: stopwatch.elapsedMicroseconds * 1000,
          ),
        );
      }
    }

    final artifact = _compareArtifact(
      scenario: scenario,
      rows: rows,
      repetitions: repetitions,
      ringDataWords: ringDataWords,
      results: results,
    );
    if (outJson != null && outJson.isNotEmpty) {
      const encoder = JsonEncoder.withIndent('  ');
      File(outJson)
        ..createSync(recursive: true)
        ..writeAsStringSync('${encoder.convert(artifact)}\n');
    }
    _printCompareReport(artifact);
    if (_hasCompareFailure(artifact)) {
      exitCode = 65;
    }
  } finally {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  }
}

void _diff(List<String> args) {
  final options = _parseOptions(args);
  final baselinePath = options['baseline'];
  final candidatePath = options['candidate'];
  if (baselinePath == null || candidatePath == null) {
    stderr.writeln('diff requires --baseline and --candidate');
    _usage();
  }
  final metric = options['metric'] ?? 'elapsed_ns';
  final thresholdPercent = double.tryParse(
        options['threshold-percent'] ?? '5',
      ) ??
      5;
  final maxCvPercent = double.tryParse(options['max-cv-percent'] ?? '15') ?? 15;
  final alpha = double.tryParse(options['alpha'] ?? '0.05') ?? 0.05;

  final baseline = _readJsonMap(baselinePath);
  final candidate = _readJsonMap(candidatePath);
  _printDiffReport(
    baseline: baseline,
    candidate: candidate,
    metric: metric,
    thresholdPercent: thresholdPercent,
    maxCvPercent: maxCvPercent,
    alpha: alpha,
  );
}

void _decision(List<String> args) {
  final options = _parseOptions(args);
  final baselinePath = options['baseline'];
  final candidatePath = options['candidate'];
  if (baselinePath == null || candidatePath == null) {
    stderr.writeln('decision requires --baseline and --candidate');
    _usage();
  }

  final expectation = options['expect'] ?? 'improvement';
  if (expectation != 'improvement' && expectation != 'no_regression') {
    stderr.writeln('--expect must be improvement or no_regression');
    exit(64);
  }

  final decision = benchmarkDecisionArtifact(
    baselineArtifacts: _readComparableArtifacts(baselinePath),
    candidateArtifacts: _readComparableArtifacts(candidatePath),
    baselinePath: baselinePath,
    candidatePath: candidatePath,
    options: BenchmarkDecisionOptions(
      expectation: expectation,
      primaryPeer: options['primary-peer'] ?? 'resqlite',
      primaryScenarios: _csvOption(options['primary-scenarios']),
      primaryMetric: options['primary-metric'] ?? 'elapsed_ns',
      guardrailPeers: _csvOption(options['guardrail-peers']),
      guardrailScenarios: _csvOption(options['guardrail-scenarios']),
      guardrailMetrics: _csvOption(
        options['guardrail-metrics'],
        defaultValue: defaultGuardrailMetrics,
      ),
      primaryThresholdPercent: double.tryParse(
            options['primary-threshold-percent'] ?? '5',
          ) ??
          5,
      maxRegressionPercent: double.tryParse(
            options['max-regression-percent'] ?? '3',
          ) ??
          3,
      maxCvPercent: double.tryParse(options['max-cv-percent'] ?? '15') ?? 15,
      alpha: double.tryParse(options['alpha'] ?? '0.05') ?? 0.05,
    ),
  );

  final outJson = options['out-json'];
  if (outJson != null && outJson.isNotEmpty) {
    const encoder = JsonEncoder.withIndent('  ');
    File(outJson)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${encoder.convert(decision)}\n');
  }
  stdout.write(benchmarkDecisionMarkdown(decision));
  if (!benchmarkDecisionPassed(decision)) {
    exitCode = 65;
  }
}

void _exportGraphData(List<String> args) {
  final options = _parseOptions(args);
  final out = options['out'];
  if (out == null || out.isEmpty) {
    stderr.writeln('export-graph-data requires --out=directory');
    _usage();
  }

  final compareInputs = <GraphDataInput>[
    for (final path in _csvOption(options['compare'])) _graphInput(path),
    for (final path in _csvOption(options['suite'])) ..._suiteGraphInputs(path),
  ];
  final decisionInputs = [
    for (final path in _csvOption(options['decision'])) _graphInput(path),
  ];
  final workloadInputs = [
    for (final path in _csvOption(options['workload-summary']))
      _graphInput(path),
  ];
  if (compareInputs.isEmpty &&
      decisionInputs.isEmpty &&
      workloadInputs.isEmpty) {
    stderr.writeln(
      'export-graph-data requires at least one of '
      '--compare, --suite, --decision, or --workload-summary',
    );
    _usage();
  }

  final bundle = traceliteGraphDataBundle(
    runId: options['run-id'],
    compareArtifacts: compareInputs,
    decisionArtifacts: decisionInputs,
    workloadSummaries: workloadInputs,
  );
  final files = _writeGraphDataBundle(Directory(out), bundle);
  _printGraphDataReport(
    outDir: out,
    bundle: bundle,
    files: files,
  );
}

Future<void> _calibrate(List<String> args) async {
  final options = _parseOptions(args);
  final iterations = _positiveIntOption(options, 'iterations', 10000);
  final repetitions = _positiveIntOption(options, 'repetitions', 5);
  final outJson = options['out-json'];
  final runtimePath = options['runtime'] ?? _defaultRuntimeLibraryPath();
  final runtime = File(runtimePath);
  if (!runtime.existsSync()) {
    stderr.writeln('missing ${runtime.path}; build it with:');
    stderr.writeln(_runtimeBuildCommand());
    exit(66);
  }

  final samples = <Map<String, Object?>>[];
  final tempRoot = Directory.systemTemp.createTempSync('tracelite-calibrate-');
  try {
    for (var repetition = 1; repetition <= repetitions; repetition++) {
      final bodyOnly = _timeLoop(iterations, (i) => i);

      final disabled = TraceRecorder.disabled();
      final disabledRecorder = _timeLoop(
        iterations,
        (i) => disabled.trace(userSpanIdStart + 0x100, () => i),
      );

      final regionPath = '${tempRoot.path}/active-r$repetition.tlt-region';
      TraceRegion.createFile(
        regionPath,
        ringDataWords: _ringWordsForEvents(iterations * 2 + 16),
      );
      final recorder = TraceRecorder.attach(
        regionPath: regionPath,
        runtimeLibraryPath: runtime.absolute.path,
        processName: 'tracelite_calibrate',
        threadName: 'main',
      );
      if (!recorder.isActive) {
        throw StateError('failed to attach calibration recorder');
      }
      recorder.registerSpan(
        userSpanIdStart + 0x100,
        'tracelite.calibration.sync_span',
        category: 'tracelite',
      );
      final activeRecorder = _timeLoop(iterations, (i) {
        recorder.begin(userSpanIdStart + 0x100);
        recorder.end(userSpanIdStart + 0x100);
        return i;
      });
      recorder.detach();

      final trace = Trace.loadRegion(regionPath);
      samples.add({
        'repetition': repetition,
        'body_only_ns': bodyOnly.elapsedNs,
        'disabled_recorder_ns': disabledRecorder.elapsedNs,
        'active_recorder_ns': activeRecorder.elapsedNs,
        'body_checksum': bodyOnly.checksum,
        'disabled_checksum': disabledRecorder.checksum,
        'active_checksum': activeRecorder.checksum,
        'events': trace.events.length,
        'spans': trace.spans.length,
        'dropped_events': trace.diagnostics.droppedEvents,
        'unmatched_begin_events': trace.diagnostics.unmatchedBeginEvents,
        'unmatched_end_events': trace.diagnostics.unmatchedEndEvents,
      });
    }
  } finally {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  }

  final artifact = _calibrationArtifact(
    iterations: iterations,
    repetitions: repetitions,
    runtimePath: runtime.absolute.path,
    samples: samples,
  );
  if (outJson != null && outJson.isNotEmpty) {
    const encoder = JsonEncoder.withIndent('  ');
    File(outJson)
      ..createSync(recursive: true)
      ..writeAsStringSync('${encoder.convert(artifact)}\n');
  }
  _printCalibrationReport(artifact);
}

Future<void> _runPeer(List<String> args) async {
  final options = _parseOptions(args);
  final peer = options['peer'];
  final scenario = options['scenario'] ?? narrowBatchInsertScenario;
  final database = options['database'];
  final metrics = options['metrics'];
  final rows = int.tryParse(options['rows'] ?? '100') ?? 100;
  if (peer == null || database == null) {
    stderr.writeln('_run-peer requires --peer and --database');
    exit(64);
  }
  final stopwatch = Stopwatch()..start();
  PeerScenarioResult? result;
  UnsupportedPeerScenario? unsupported;
  try {
    result = await runPeerScenario(
      peerName: peer,
      scenarioName: scenario,
      databasePath: database,
      rows: rows,
    );
  } on UnsupportedPeerScenario catch (error) {
    unsupported = error;
  } finally {
    stopwatch.stop();
    if (metrics != null && metrics.isNotEmpty) {
      File(metrics).writeAsStringSync(
        jsonEncode({
          'schema': 'tracelite.peer_metrics.v1',
          'status': unsupported == null ? 'ok' : 'unsupported',
          if (unsupported != null) 'unsupported_reason': unsupported.message,
          'scenario_elapsed_ns': stopwatch.elapsedMicroseconds * 1000,
          if (result != null) ...result.toJson(),
        }),
      );
    }
  }
}

Map<String, String> _parseOptions(List<String> args) {
  final result = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      stderr.writeln('unexpected argument: $arg');
      _usage();
    }
    final withoutPrefix = arg.substring(2);
    final equals = withoutPrefix.indexOf('=');
    if (equals >= 0) {
      result[withoutPrefix.substring(0, equals)] =
          withoutPrefix.substring(equals + 1);
    } else {
      if (i + 1 >= args.length) {
        stderr.writeln('missing value for $arg');
        _usage();
      }
      result[withoutPrefix] = args[++i];
    }
  }
  return result;
}

Map<String, Object?> _compareArtifact({
  required String scenario,
  required int rows,
  required int repetitions,
  required int ringDataWords,
  required List<_PeerTraceResult> results,
}) {
  final peers = <String, List<_PeerTraceResult>>{};
  for (final result in results) {
    peers.putIfAbsent(result.peer, () => <_PeerTraceResult>[]).add(result);
  }

  return {
    'schema': 'tracelite.compare.v1',
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'scenario': scenario,
    'rows': rows,
    'workload': peerScenarioParameters(scenario, rows: rows),
    'environment': _environmentArtifact(),
    'repetitions': repetitions,
    'ring_data_words': ringDataWords,
    'peers': [
      for (final entry in peers.entries)
        _peerArtifact(peer: entry.key, results: entry.value),
    ],
  };
}

Map<String, Object?> _environmentArtifact() {
  return {
    'dart_version': Platform.version,
    'operating_system': Platform.operatingSystem,
    'operating_system_version': Platform.operatingSystemVersion,
    'number_of_processors': Platform.numberOfProcessors,
  };
}

Map<String, Object?> _peerArtifact({
  required String peer,
  required List<_PeerTraceResult> results,
}) {
  final samples = [
    for (final result in results) _sampleArtifact(result),
  ];
  final successful = results.where((result) => result.trace != null).toList();
  final unsupported =
      results.where((result) => result.status == 'unsupported').length;
  final failed = results.where((result) => result.status == 'failed').length;
  final eventCounts = successful.map((result) => result.trace!.events.length);
  final spanCounts = successful.map((result) => result.trace!.spans.length);
  final elapsedNs = successful.map((result) => result.elapsedNs);
  final setupElapsedNs = successful.map((result) => result.setupElapsedNs);
  final warmupElapsedNs = successful.map((result) => result.warmupElapsedNs);
  final measuredElapsedNs = successful.map(
    (result) => result.measuredElapsedNs,
  );
  final childElapsedNs = successful.map((result) => result.childElapsedNs);
  final traceDurations = successful.map(_traceDurationNs);
  final totalSpanNs = successful.map(
    (result) => result.trace!.spans.durationStats().totalNs,
  );
  final stepCounts = successful.map(
    (result) => result.trace!.spans
        .ofType(BuiltinSpans.sqlite3Step)
        .durationStats()
        .count,
  );
  final stepTotalNs = successful.map(
    (result) => result.trace!.spans
        .ofType(BuiltinSpans.sqlite3Step)
        .durationStats()
        .totalNs,
  );
  final droppedEvents = successful.map(
    (result) => result.trace!.diagnostics.droppedEvents,
  );
  final unmatchedBeginEvents = successful.map(
    (result) => result.trace!.diagnostics.unmatchedBeginEvents,
  );
  final unmatchedEndEvents = successful.map(
    (result) => result.trace!.diagnostics.unmatchedEndEvents,
  );

  return {
    'peer': peer,
    'status': _peerStatus(results),
    'successful_repetitions': successful.length,
    'failed_repetitions': failed,
    'unsupported_repetitions': unsupported,
    'summary': {
      'elapsed_ns': _IntStats.fromValues(elapsedNs).toJson(),
      'setup_elapsed_ns': _IntStats.fromValues(setupElapsedNs).toJson(),
      'warmup_elapsed_ns': _IntStats.fromValues(warmupElapsedNs).toJson(),
      'measured_elapsed_ns': _IntStats.fromValues(measuredElapsedNs).toJson(),
      'child_elapsed_ns': _IntStats.fromValues(childElapsedNs).toJson(),
      'trace_duration_ns': _IntStats.fromValues(traceDurations).toJson(),
      'trace_span_total_ns': _IntStats.fromValues(totalSpanNs).toJson(),
      'events': _IntStats.fromValues(eventCounts).toJson(),
      'spans': _IntStats.fromValues(spanCounts).toJson(),
      'sqlite3_step_count': _IntStats.fromValues(stepCounts).toJson(),
      'sqlite3_step_total_ns': _IntStats.fromValues(stepTotalNs).toJson(),
      'dropped_events': _IntStats.fromValues(droppedEvents).toJson(),
      'unmatched_begin_events':
          _IntStats.fromValues(unmatchedBeginEvents).toJson(),
      'unmatched_end_events': _IntStats.fromValues(unmatchedEndEvents).toJson(),
    },
    'samples': samples,
    'capabilities': peerCapabilities(peer),
  };
}

Map<String, Object?> _sampleArtifact(_PeerTraceResult result) {
  final trace = result.trace;
  if (result.status == 'unsupported') {
    return {
      'repetition': result.repetition,
      'status': 'unsupported',
      'elapsed_ns': result.elapsedNs,
      'child_elapsed_ns': result.childElapsedNs,
      'unsupported_reason': result.unsupportedReason,
    };
  }
  if (trace == null) {
    return {
      'repetition': result.repetition,
      'status': 'failed',
      'elapsed_ns': result.elapsedNs,
      'setup_elapsed_ns': result.setupElapsedNs,
      'warmup_elapsed_ns': result.warmupElapsedNs,
      'measured_elapsed_ns': result.measuredElapsedNs,
      'child_elapsed_ns': result.childElapsedNs,
      'stdout': result.stdout,
      'stderr': result.stderr,
    };
  }
  return {
    'repetition': result.repetition,
    'status': trace.events.isEmpty ? 'no_trace' : 'ok',
    'elapsed_ns': result.elapsedNs,
    'setup_elapsed_ns': result.setupElapsedNs,
    'warmup_elapsed_ns': result.warmupElapsedNs,
    'measured_elapsed_ns': result.measuredElapsedNs,
    'child_elapsed_ns': result.childElapsedNs,
    if (result.measurements.isNotEmpty) 'measurements': result.measurements,
    'events': trace.events.length,
    'spans': trace.spans.length,
    'trace_duration_ns': _traceDurationNs(result),
    'diagnostics': {
      'dropped_events': trace.diagnostics.droppedEvents,
      'unmatched_begin_events': trace.diagnostics.unmatchedBeginEvents,
      'unmatched_end_events': trace.diagnostics.unmatchedEndEvents,
    },
    'span_groups': [
      for (final group in trace.spans.groupStatsByType(
        spanNames: trace.spanNames,
      )..sort((a, b) => a.spanName.compareTo(b.spanName)))
        {
          'span_id': group.spanId,
          'span_name': group.spanName,
          'count': group.stats.count,
          'total_ns': group.stats.totalNs,
          'p50_ns': group.stats.p50Ns,
          'p90_ns': group.stats.p90Ns,
          'p99_ns': group.stats.p99Ns,
        },
    ],
    'counter_groups': [
      for (final group in trace.counterEvents.groupCounterStatsByType(
        spanNames: trace.spanNames,
      )..sort((a, b) => a.spanName.compareTo(b.spanName)))
        {
          'counter_id': group.spanId,
          'counter_name': group.spanName,
          'samples': group.stats.count,
          'latest': group.stats.latest,
          'min': group.stats.min,
          'max': group.stats.max,
        },
    ],
  };
}

void _printCompareReport(Map<String, Object?> artifact) {
  final scenario = artifact['scenario'] as String;
  final rows = artifact['rows'] as int;
  final repetitions = artifact['repetitions'] as int;
  final peers = artifact['peers'] as List<Object?>;

  stdout
    ..writeln('# tracelite compare')
    ..writeln()
    ..writeln('Scenario: `$scenario`')
    ..writeln('Rows: $rows')
    ..writeln('Repetitions: $repetitions')
    ..writeln()
    ..writeln(
      '> tracelite compares shared SQL execution paths, not overall '
      'library quality, API ergonomics, type-system coverage, or reactive '
      'feature sets.',
    )
    ..writeln()
    ..writeln(
      '| peer | status | reps | events avg | spans avg | sqlite3_step avg | '
      'scenario elapsed avg | scenario cv | traced total avg | '
      'diagnostics max |',
    )
    ..writeln('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|');

  for (final peerObj in peers) {
    final peer = peerObj! as Map<String, Object?>;
    final summary = peer['summary']! as Map<String, Object?>;
    final successful = peer['successful_repetitions'] as int;
    final failed = peer['failed_repetitions'] as int;
    final unsupported = peer['unsupported_repetitions'] as int;
    final events = _metric(summary, 'events');
    final spans = _metric(summary, 'spans');
    final steps = _metric(summary, 'sqlite3_step_count');
    final elapsed = _metric(summary, 'elapsed_ns');
    final total = _metric(summary, 'trace_span_total_ns');
    final dropped = _metric(summary, 'dropped_events');
    final unmatchedBegin = _metric(summary, 'unmatched_begin_events');
    final unmatchedEnd = _metric(summary, 'unmatched_end_events');
    stdout.writeln(
      '| `${peer['peer']}` | ${peer['status']} | $successful/$repetitions | '
      '${_formatMean(events)} | ${_formatMean(spans)} | '
      '${_formatMean(steps)} | ${_formatDurationMean(elapsed)} | '
      '${_formatCv(elapsed)} | ${_formatDurationMean(total)} | '
      '${dropped.max}/${unmatchedBegin.max}/${unmatchedEnd.max} |',
    );
    if (failed > 0) {
      stdout.writeln();
      stdout.writeln('`${peer['peer']}` had $failed failed repetition(s).');
    }
    if (unsupported > 0) {
      stdout.writeln();
      stdout.writeln('`${peer['peer']}` does not support this scenario.');
    }
  }

  final missingTrace = peers
      .cast<Map<String, Object?>>()
      .where((peer) => peer['status'] == 'no_trace')
      .map((peer) => peer['peer'])
      .toList();
  if (missingTrace.isNotEmpty) {
    stdout
      ..writeln()
      ..writeln('## Trace gaps')
      ..writeln()
      ..writeln(
        'These peers completed the scenario but emitted no SQLite shim events: '
        '${missingTrace.map((peer) => '`$peer`').join(', ')}.',
      )
      ..writeln(
        'That means the current shim is not on their SQLite call path yet.',
      );
  }

  for (final peerObj in peers) {
    final peer = peerObj! as Map<String, Object?>;
    final samples = peer['samples'] as List<Object?>;
    for (final sampleObj in samples) {
      final sample = sampleObj! as Map<String, Object?>;
      if (sample['status'] != 'failed') continue;
      stdout
        ..writeln()
        ..writeln(
            '## ${peer['peer']} repetition ${sample['repetition']} failure')
        ..writeln()
        ..writeln('```text')
        ..write((sample['stderr'] as String).isEmpty
            ? sample['stdout']
            : sample['stderr'])
        ..writeln('```');
    }
  }
}

void _printDiffReport({
  required Map<String, Object?> baseline,
  required Map<String, Object?> candidate,
  required String metric,
  required double thresholdPercent,
  required double maxCvPercent,
  required double alpha,
}) {
  final baselinePeers = _peersByName(baseline);
  final candidatePeers = _peersByName(candidate);
  final names = baselinePeers.keys.where(candidatePeers.containsKey).toList()
    ..sort();

  stdout
    ..writeln('# tracelite diff')
    ..writeln()
    ..writeln('Metric: `$metric`')
    ..writeln('Threshold: ${_trimDouble(thresholdPercent)}%')
    ..writeln('Max CV: ${_trimDouble(maxCvPercent)}%')
    ..writeln('Alpha: ${_trimDouble(alpha)}')
    ..writeln()
    ..writeln(
      '| peer | samples | baseline mean | candidate mean | delta | '
      'delta 95% CI | nonparam p | outliers | change | max cv | verdict |',
    )
    ..writeln('|---|---:|---:|---:|---:|---:|---:|---:|---:|---|');

  for (final name in names) {
    final baselinePeer = baselinePeers[name]!;
    final candidatePeer = candidatePeers[name]!;
    final baselineMetric =
        _metric(baselinePeer['summary']! as Map<String, Object?>, metric);
    final candidateMetric =
        _metric(candidatePeer['summary']! as Map<String, Object?>, metric);
    final baselineSamples = _sampleMetricValues(baselinePeer, metric);
    final candidateSamples = _sampleMetricValues(candidatePeer, metric);
    final delta = candidateMetric.mean - baselineMetric.mean;
    final change =
        baselineMetric.mean == 0 ? 0.0 : delta / baselineMetric.mean * 100.0;
    final baselineCv = _cvPercent(baselineMetric);
    final candidateCv = _cvPercent(candidateMetric);
    final maxCv = math.max(baselineCv, candidateCv);
    final ci = _meanDeltaConfidenceInterval(
      baselineSamples: baselineSamples,
      candidateSamples: candidateSamples,
    );
    final nonParametric = _mannWhitneyTwoSided(
      baselineSamples: baselineSamples,
      candidateSamples: candidateSamples,
    );
    final outliers = _outlierSummary(
      baselineSamples: baselineSamples,
      candidateSamples: candidateSamples,
    );
    final hasSamples =
        baselineSamples.length >= 2 && candidateSamples.length >= 2;
    final statisticallyClear = ci.excludesZero;
    final nonParametricClear = nonParametric.available &&
        nonParametric.pValue <= alpha &&
        nonParametric.directionMatches(change);
    final verdict = !hasSamples
        ? 'insufficient_samples'
        : maxCv > maxCvPercent
            ? 'too_noisy'
            : change.abs() < thresholdPercent
                ? 'neutral'
                : !statisticallyClear || !nonParametricClear
                    ? 'too_noisy'
                    : change < 0
                        ? 'improved'
                        : 'regressed';
    stdout.writeln(
      '| `$name` | ${baselineSamples.length}/${candidateSamples.length} | '
      '${_formatMetricValue(metric, baselineMetric.mean)} | '
      '${_formatMetricValue(metric, candidateMetric.mean)} | '
      '${_formatMetricValue(metric, delta)} | '
      '${_formatConfidenceInterval(metric, ci)} | '
      '${_formatPValue(nonParametric)} | ${outliers.toReportCell()} | '
      '${_trimDouble(change)}% | ${_trimDouble(maxCv)}% | $verdict |',
    );
  }
}

Map<String, Object?> _calibrationArtifact({
  required int iterations,
  required int repetitions,
  required String runtimePath,
  required List<Map<String, Object?>> samples,
}) {
  Iterable<int> values(String key) =>
      samples.map((sample) => sample[key]! as int);
  final body = _IntStats.fromValues(values('body_only_ns'));
  final disabled = _IntStats.fromValues(values('disabled_recorder_ns'));
  final active = _IntStats.fromValues(values('active_recorder_ns'));
  final activeMinusDisabled = [
    for (final sample in samples)
      (sample['active_recorder_ns']! as int) -
          (sample['disabled_recorder_ns']! as int),
  ];
  final activeMinusBody = [
    for (final sample in samples)
      (sample['active_recorder_ns']! as int) - (sample['body_only_ns']! as int),
  ];

  return {
    'schema': 'tracelite.calibration.v1',
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'iterations': iterations,
    'repetitions': repetitions,
    'runtime_path': runtimePath,
    'summary': {
      'body_only_ns': body.toJson(),
      'disabled_recorder_ns': disabled.toJson(),
      'active_recorder_ns': active.toJson(),
      'active_minus_disabled_per_span_ns':
          _perIterationStats(activeMinusDisabled, iterations).toJson(),
      'active_minus_body_per_span_ns':
          _perIterationStats(activeMinusBody, iterations).toJson(),
      'events': _IntStats.fromValues(values('events')).toJson(),
      'spans': _IntStats.fromValues(values('spans')).toJson(),
      'dropped_events': _IntStats.fromValues(values('dropped_events')).toJson(),
      'unmatched_begin_events':
          _IntStats.fromValues(values('unmatched_begin_events')).toJson(),
      'unmatched_end_events':
          _IntStats.fromValues(values('unmatched_end_events')).toJson(),
    },
    'samples': samples,
  };
}

void _printCalibrationReport(Map<String, Object?> artifact) {
  final summary = artifact['summary']! as Map<String, Object?>;
  final activeMinusDisabled = _metric(
    summary,
    'active_minus_disabled_per_span_ns',
  );
  final activeMinusBody = _metric(summary, 'active_minus_body_per_span_ns');
  final events = _metric(summary, 'events');
  final spans = _metric(summary, 'spans');
  final dropped = _metric(summary, 'dropped_events');
  final unmatchedBegin = _metric(summary, 'unmatched_begin_events');
  final unmatchedEnd = _metric(summary, 'unmatched_end_events');

  stdout
    ..writeln('# tracelite calibration')
    ..writeln()
    ..writeln('Iterations: ${artifact['iterations']}')
    ..writeln('Repetitions: ${artifact['repetitions']}')
    ..writeln()
    ..writeln('| metric | mean | p50 | p90 |')
    ..writeln('|---|---:|---:|---:|')
    ..writeln(
      '| active minus disabled per span | '
      '${_formatNs(activeMinusDisabled.mean)} | '
      '${_formatNs(activeMinusDisabled.median.toDouble())} | '
      '${_formatNs(activeMinusDisabled.p90.toDouble())} |',
    )
    ..writeln(
      '| active minus body-only per span | '
      '${_formatNs(activeMinusBody.mean)} | '
      '${_formatNs(activeMinusBody.median.toDouble())} | '
      '${_formatNs(activeMinusBody.p90.toDouble())} |',
    )
    ..writeln()
    ..writeln(
      'Trace validation: events avg ${_formatMean(events)}, '
      'spans avg ${_formatMean(spans)}, diagnostics max '
      '${dropped.max}/${unmatchedBegin.max}/${unmatchedEnd.max}.',
    );
}

_LoopTiming _timeLoop(int iterations, int Function(int) body) {
  var checksum = 0;
  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    checksum += body(i);
  }
  stopwatch.stop();
  return _LoopTiming(
    elapsedNs: stopwatch.elapsedMicroseconds * 1000,
    checksum: checksum,
  );
}

Map<String, Object?> _readJsonMap(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw FormatException('$path does not contain a JSON object');
  }
  return decoded;
}

List<Map<String, Object?>> _readComparableArtifacts(String path) {
  final root = _readJsonMap(path);
  return switch (root['schema']) {
    'tracelite.compare.v1' => [root],
    'tracelite.suite.v1' => _readSuiteCompareArtifacts(path, root),
    _ => throw FormatException(
        '$path is not a tracelite compare artifact or suite manifest',
      ),
  };
}

List<Map<String, Object?>> _readSuiteCompareArtifacts(
  String manifestPath,
  Map<String, Object?> manifest,
) {
  final runs = manifest['runs'];
  if (runs is! List<Object?>) {
    throw FormatException('$manifestPath has no runs list');
  }
  return [
    for (final run in runs.cast<Map<String, Object?>>())
      _readJsonMap(_resolveManifestArtifactPath(
        manifestPath,
        run['artifact']! as String,
      )),
  ];
}

GraphDataInput _graphInput(String path, {String? parentPath}) {
  return GraphDataInput(
    path: path,
    parentPath: parentPath,
    artifact: _readJsonMap(path),
  );
}

List<GraphDataInput> _suiteGraphInputs(String manifestPath) {
  final manifest = _readJsonMap(manifestPath);
  if (manifest['schema'] != 'tracelite.suite.v1') {
    throw FormatException('$manifestPath is not a tracelite suite manifest');
  }
  final runs = manifest['runs'];
  if (runs is! List<Object?>) {
    throw FormatException('$manifestPath has no runs list');
  }
  return [
    for (final run in runs.cast<Map<String, Object?>>())
      _graphInput(
        _resolveManifestArtifactPath(manifestPath, run['artifact']! as String),
        parentPath: manifestPath,
      ),
  ];
}

String _resolveManifestArtifactPath(String manifestPath, String artifactPath) {
  final artifact = File(artifactPath);
  if (artifact.isAbsolute || artifact.existsSync()) return artifact.path;
  return File(manifestPath).parent.uri.resolve(artifactPath).toFilePath();
}

List<String> _csvOption(String? value, {List<String> defaultValue = const []}) {
  if (value == null || value.trim().isEmpty) return defaultValue;
  return value
      .split(',')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
}

Map<String, String> _writeGraphDataBundle(
  Directory outDir,
  Map<String, Object?> bundle,
) {
  outDir.createSync(recursive: true);
  final datasets = bundle['datasets'];
  if (datasets is! Map<String, Object?>) {
    throw const FormatException('graph data bundle has no datasets map');
  }
  const encoder = JsonEncoder.withIndent('  ');
  final files = <String, String>{};
  final counts = <String, int>{};
  for (final entry in datasets.entries) {
    final rows = entry.value;
    if (rows is! List<Object?>) continue;
    final filename = '${entry.key.replaceAll('_', '-')}.json';
    files[entry.key] = filename;
    counts[entry.key] = rows.length;
    File('${outDir.path}/$filename').writeAsStringSync(
      '${encoder.convert({
            'schema': graphDatasetSchema,
            'generated_at': bundle['generated_at'],
            if (bundle['run_id'] != null) 'run_id': bundle['run_id'],
            'dataset': entry.key,
            'rows': rows,
          })}\n',
    );
  }
  final index = <String, Object?>{
    'schema': bundle['schema'],
    'generated_at': bundle['generated_at'],
    if (bundle['run_id'] != null) 'run_id': bundle['run_id'],
    'sources': bundle['sources'],
    'files': files,
    'counts': counts,
  };
  File('${outDir.path}/index.json')
      .writeAsStringSync('${encoder.convert(index)}\n');
  return files;
}

void _printGraphDataReport({
  required String outDir,
  required Map<String, Object?> bundle,
  required Map<String, String> files,
}) {
  final datasets = bundle['datasets'] as Map<String, Object?>;
  stdout
    ..writeln('# tracelite graph data')
    ..writeln()
    ..writeln('Out dir: `$outDir`')
    ..writeln()
    ..writeln('| dataset | rows | file |')
    ..writeln('|---|---:|---|');
  for (final entry in files.entries) {
    final rows = datasets[entry.key] as List<Object?>? ?? const [];
    stdout.writeln('| `${entry.key}` | ${rows.length} | `${entry.value}` |');
  }
  stdout
    ..writeln()
    ..writeln('Index: `$outDir/index.json`');
}

_PeerRunMetrics _readPeerMetrics(String path) {
  final file = File(path);
  if (!file.existsSync()) return const _PeerRunMetrics();
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) return const _PeerRunMetrics();
  return _PeerRunMetrics.fromJson(decoded);
}

Map<String, Map<String, Object?>> _peersByName(Map<String, Object?> artifact) {
  final peers = artifact['peers'];
  if (peers is! List<Object?>) {
    throw const FormatException('artifact has no peers list');
  }
  return {
    for (final peer in peers.cast<Map<String, Object?>>())
      peer['peer']! as String: peer,
  };
}

_IntStats _metric(Map<String, Object?> summary, String metric) {
  final value = summary[metric];
  if (value is! Map<String, Object?>) {
    throw ArgumentError.value(metric, 'metric', 'not present in summary');
  }
  return _IntStats.fromJson(value);
}

List<int> _sampleMetricValues(Map<String, Object?> peer, String metric) {
  final samples = peer['samples'];
  if (samples is! List<Object?>) return const [];
  return [
    for (final sampleObj in samples)
      if (sampleObj is Map<String, Object?> && sampleObj['status'] == 'ok')
        if (_sampleMetricValue(sampleObj, metric) case final value?) value,
  ];
}

int? _sampleMetricValue(Map<String, Object?> sample, String metric) {
  final direct = sample[metric];
  if (direct is int) return direct;

  final diagnostics = sample['diagnostics'];
  if (diagnostics is Map<String, Object?>) {
    final diagnostic = diagnostics[metric];
    if (diagnostic is int) return diagnostic;
  }

  final spanGroups = sample['span_groups'];
  if (spanGroups is List<Object?>) {
    if (metric == 'trace_span_total_ns') {
      var total = 0;
      for (final group in spanGroups) {
        if (group is Map<String, Object?> && group['total_ns'] is int) {
          total += group['total_ns']! as int;
        }
      }
      return total;
    }

    for (final group in spanGroups) {
      if (group is! Map<String, Object?>) continue;
      if (group['span_name'] != 'sqlite3_step') continue;
      return switch (metric) {
        'sqlite3_step_count' => group['count'] as int?,
        'sqlite3_step_total_ns' => group['total_ns'] as int?,
        _ => null,
      };
    }
  }

  return null;
}

_ConfidenceInterval _meanDeltaConfidenceInterval({
  required List<int> baselineSamples,
  required List<int> candidateSamples,
}) {
  if (baselineSamples.length < 2 || candidateSamples.length < 2) {
    return const _ConfidenceInterval.unavailable();
  }

  final baseline = _DoubleSample.fromInts(baselineSamples);
  final candidate = _DoubleSample.fromInts(candidateSamples);
  final delta = candidate.mean - baseline.mean;
  final baselineTerm = baseline.variance / baseline.count;
  final candidateTerm = candidate.variance / candidate.count;
  final standardError = math.sqrt(baselineTerm + candidateTerm);
  if (standardError == 0) {
    return _ConfidenceInterval(lower: delta, upper: delta);
  }

  final numerator = math.pow(baselineTerm + candidateTerm, 2).toDouble();
  final denominator = math.pow(baselineTerm, 2) / (baseline.count - 1) +
      math.pow(candidateTerm, 2) / (candidate.count - 1);
  final degreesOfFreedom = denominator == 0 ? 1.0 : numerator / denominator;
  final margin = _tCritical95(degreesOfFreedom) * standardError;
  return _ConfidenceInterval(lower: delta - margin, upper: delta + margin);
}

_MannWhitneyResult _mannWhitneyTwoSided({
  required List<int> baselineSamples,
  required List<int> candidateSamples,
}) {
  if (baselineSamples.length < 3 || candidateSamples.length < 3) {
    return const _MannWhitneyResult.unavailable();
  }

  final combined = <_RankedValue>[
    for (final value in baselineSamples) _RankedValue(value, true),
    for (final value in candidateSamples) _RankedValue(value, false),
  ]..sort((a, b) => a.value.compareTo(b.value));

  final hasTies = _assignAverageRanks(combined);
  final baselineCount = baselineSamples.length;
  final candidateCount = candidateSamples.length;
  final baselineRankSum = combined
      .where((value) => value.isBaseline)
      .fold<double>(0, (sum, value) => sum + value.rank);
  final baselineU = baselineRankSum - baselineCount * (baselineCount + 1) / 2.0;
  final maxU = baselineCount * candidateCount.toDouble();
  final observedMinU = math.min(baselineU, maxU - baselineU);

  final exactPValue = hasTies
      ? null
      : _exactMannWhitneyTwoSidedPValue(
          totalCount: combined.length,
          baselineCount: baselineCount,
          observedMinU: observedMinU,
        );
  final pValue = exactPValue ??
      _approximateMannWhitneyTwoSidedPValue(
        u: baselineU,
        baselineCount: baselineCount,
        candidateCount: candidateCount,
      );
  final direction = candidateSamples.average - baselineSamples.average;
  return _MannWhitneyResult(
    pValue: pValue.clamp(0.0, 1.0).toDouble(),
    direction: direction,
    exact: exactPValue != null,
  );
}

bool _assignAverageRanks(List<_RankedValue> values) {
  var hasTies = false;
  var index = 0;
  while (index < values.length) {
    var end = index + 1;
    while (end < values.length && values[end].value == values[index].value) {
      end++;
    }
    if (end - index > 1) {
      hasTies = true;
    }
    final rank = (index + 1 + end) / 2.0;
    for (var i = index; i < end; i++) {
      values[i].rank = rank;
    }
    index = end;
  }
  return hasTies;
}

double? _exactMannWhitneyTwoSidedPValue({
  required int totalCount,
  required int baselineCount,
  required double observedMinU,
}) {
  final candidateCount = totalCount - baselineCount;
  final totalCombinations = _combinationCount(totalCount, baselineCount);
  if (totalCombinations > 1000000) return null;

  var extreme = 0;
  var combinations = 0;

  void visit(int nextRank, int chosen, int rankSum) {
    if (chosen == baselineCount) {
      combinations++;
      final u = rankSum - baselineCount * (baselineCount + 1) / 2.0;
      final minU = math.min(u, baselineCount * candidateCount - u);
      if (minU <= observedMinU + 1e-9) {
        extreme++;
      }
      return;
    }
    final remainingNeeded = baselineCount - chosen;
    for (var rank = nextRank;
        rank <= totalCount - remainingNeeded + 1;
        rank++) {
      visit(rank + 1, chosen + 1, rankSum + rank);
    }
  }

  visit(1, 0, 0);
  return combinations == 0 ? null : extreme / combinations;
}

int _combinationCount(int n, int k) {
  final r = math.min(k, n - k);
  var result = 1;
  for (var i = 1; i <= r; i++) {
    result = result * (n - r + i) ~/ i;
  }
  return result;
}

double _approximateMannWhitneyTwoSidedPValue({
  required double u,
  required int baselineCount,
  required int candidateCount,
}) {
  final mean = baselineCount * candidateCount / 2.0;
  final variance = baselineCount *
      candidateCount *
      (baselineCount + candidateCount + 1) /
      12.0;
  if (variance <= 0) return 1;
  final continuity = u > mean
      ? -0.5
      : u < mean
          ? 0.5
          : 0.0;
  final z = (u - mean + continuity) / math.sqrt(variance);
  final oneTail = math.min(_normalCdf(z), 1.0 - _normalCdf(z));
  return math.min(1.0, oneTail * 2.0);
}

double _normalCdf(double z) {
  final sign = z < 0 ? -1.0 : 1.0;
  final x = z.abs();
  final t = 1.0 / (1.0 + 0.2316419 * x);
  final y = 1.0 -
      0.3989422804014327 *
          math.exp(-x * x / 2.0) *
          t *
          (0.319381530 +
              t *
                  (-0.356563782 +
                      t *
                          (1.781477937 +
                              t * (-1.821255978 + 1.330274429 * t))));
  return sign == 1.0 ? y : 1.0 - y;
}

_OutlierSummary _outlierSummary({
  required List<int> baselineSamples,
  required List<int> candidateSamples,
}) {
  return _OutlierSummary(
    baseline: _tukeyOutlierCount(baselineSamples),
    candidate: _tukeyOutlierCount(candidateSamples),
  );
}

int _tukeyOutlierCount(List<int> samples) {
  if (samples.length < 4) return 0;
  final sorted = samples.toList()..sort();
  final q1 = _percentileInterpolated(sorted, 0.25);
  final q3 = _percentileInterpolated(sorted, 0.75);
  final iqr = q3 - q1;
  if (iqr == 0) return 0;
  final low = q1 - 1.5 * iqr;
  final high = q3 + 1.5 * iqr;
  return sorted.where((value) => value < low || value > high).length;
}

double _percentileInterpolated(List<int> values, double percentile) {
  if (values.isEmpty) return 0;
  final position = (values.length - 1) * percentile;
  final lower = position.floor();
  final upper = position.ceil();
  if (lower == upper) return values[lower].toDouble();
  final weight = position - lower;
  return values[lower] * (1 - weight) + values[upper] * weight;
}

double _tCritical95(double degreesOfFreedom) {
  if (degreesOfFreedom >= 120) return 1.98;
  if (degreesOfFreedom >= 60) return 2.00;
  if (degreesOfFreedom >= 40) return 2.02;
  if (degreesOfFreedom >= 30) return 2.04;
  if (degreesOfFreedom >= 20) return 2.09;
  if (degreesOfFreedom >= 15) return 2.13;
  if (degreesOfFreedom >= 10) return 2.23;
  if (degreesOfFreedom >= 8) return 2.31;
  if (degreesOfFreedom >= 6) return 2.45;
  if (degreesOfFreedom >= 5) return 2.57;
  if (degreesOfFreedom >= 4) return 2.78;
  if (degreesOfFreedom >= 3) return 3.18;
  if (degreesOfFreedom >= 2) return 4.30;
  return 12.71;
}

String _peerStatus(List<_PeerTraceResult> results) {
  if (results.every((result) => result.status == 'unsupported')) {
    return 'unsupported';
  }
  if (results.any((result) => result.status == 'failed')) {
    return 'failed';
  }
  final successful = results.where((result) => result.trace != null).toList();
  if (successful.isEmpty) return 'failed';
  if (successful.any((result) => result.trace!.events.isEmpty)) {
    return 'no_trace';
  }
  if (successful.any((result) => _hasTraceDiagnostics(result.trace!))) {
    return 'trace_diagnostics';
  }
  if (successful.length != results.length) return 'partial';
  return 'ok';
}

bool _hasCompareFailure(Map<String, Object?> artifact) {
  final peers = artifact['peers'];
  if (peers is! List<Object?>) return true;
  return peers
      .cast<Map<String, Object?>>()
      .any((peer) => peer['status'] != 'ok' && peer['status'] != 'unsupported');
}

bool _hasTraceDiagnostics(Trace trace) {
  return trace.diagnostics.droppedEvents != 0 ||
      trace.diagnostics.unmatchedBeginEvents != 0 ||
      trace.diagnostics.unmatchedEndEvents != 0;
}

int _traceDurationNs(_PeerTraceResult result) =>
    result.trace!.duration.inMicroseconds * 1000;

int _positiveIntOption(
  Map<String, String> options,
  String name,
  int defaultValue,
) {
  final raw = options[name];
  if (raw == null) return defaultValue;
  final value = int.tryParse(raw);
  if (value == null || value <= 0) {
    stderr.writeln('--$name must be a positive integer');
    exit(64);
  }
  return value;
}

int _positivePowerOfTwoOption(
  Map<String, String> options,
  String name,
  int defaultValue,
) {
  final value = _positiveIntOption(options, name, defaultValue);
  if (value & (value - 1) != 0) {
    stderr.writeln('--$name must be a power of two');
    exit(64);
  }
  return value;
}

int _ringWordsForScenario(String scenario, int rows) {
  final parameters = peerScenarioParameters(scenario, rows: rows);
  final expectedEvents = switch (scenario) {
    narrowBatchInsertScenario => rows * 80 + 4096,
    pointSelectScenario => rows * 120 + 4096,
    feedPagingScenario => rows * 140 + 4096,
    syncBurstScenario => rows * 180 + 4096,
    chatSimScenario => rows * 700 + 8192,
    largeWorkingSetScenario => rows * 260 + 8192,
    keyedPkSubscriptionsScenario => _intParameter(parameters, 'rows') * 40 +
        _intParameter(parameters, 'stream_count') * 800 +
        _intParameter(parameters, 'write_count') * 300 +
        16384,
    highCardinalityFanoutScenario => _intParameter(parameters, 'rows') * 250 +
        _intParameter(parameters, 'stream_count') * 2000 +
        _intParameter(parameters, 'write_count') * 1000 +
        32768,
    manyStreamsWriterThroughputScenario =>
      _intParameter(parameters, 'rows') * 500 +
          _intParameter(parameters, 'stream_count') * 2000 +
          _intParameter(parameters, 'write_count') * 2000 +
          32768,
    sqliteDiagnosticsScenario => rows * 160 + 8192,
    _ => rows * 120 + 4096,
  };
  return _ringWordsForEvents(expectedEvents);
}

int _intParameter(Map<String, Object?> parameters, String name) {
  final value = parameters[name];
  return value is int ? value : 0;
}

int _ringWordsForEvents(int events) {
  // The scenario formulas estimate semantic SQLite wrapper events, but ring
  // capacity is counted in data words and reactive peer adapters can fan out
  // far more SQLite calls than their high-level write count suggests. Keep a
  // generous default so production benchmark artifacts fail on real behavior,
  // not trace-buffer pressure.
  final needed = math.max(8192, events * 12);
  var power = 1;
  while (power < needed) {
    power <<= 1;
  }
  return power;
}

String _defaultRuntimeLibraryPath() {
  final extension = switch (Platform.operatingSystem) {
    'macos' => 'dylib',
    'windows' => 'dll',
    _ => 'so',
  };
  return 'build/libtracelite_runtime.$extension';
}

String _runtimeBuildCommand() {
  final output = _defaultRuntimeLibraryPath();
  return switch (Platform.operatingSystem) {
    'macos' => '  cc -dynamiclib -O2 -Inative native/tracelite_runtime.c '
        '-o $output',
    'windows' => '  cc -shared -O2 -Inative native/tracelite_runtime.c '
        '-o $output',
    _ => '  cc -shared -fPIC -O2 -Inative native/tracelite_runtime.c '
        '-o $output',
  };
}

_IntStats _perIterationStats(List<int> values, int iterations) {
  return _IntStats.fromValues([
    for (final value in values) value ~/ iterations,
  ]);
}

String _formatMean(_IntStats stats) {
  if (stats.count == 0) return '-';
  return _trimDouble(stats.mean);
}

String _formatDurationMean(_IntStats stats) {
  if (stats.count == 0) return '-';
  return formatDurationNs(stats.mean.round());
}

String _formatCv(_IntStats stats) {
  if (stats.count < 2 || stats.mean == 0) return '-';
  return '${_trimDouble(_cvPercent(stats))}%';
}

double _cvPercent(_IntStats stats) {
  if (stats.mean == 0) return 0;
  return stats.stddev / stats.mean * 100;
}

String _formatMetricValue(String metric, double value) {
  if (metric.endsWith('_ns')) {
    final rounded = value.round();
    if (rounded < 0) return '-${formatDurationNs(-rounded)}';
    return formatDurationNs(rounded);
  }
  return _trimDouble(value);
}

String _formatConfidenceInterval(String metric, _ConfidenceInterval interval) {
  if (!interval.available) return '-';
  return '[${_formatMetricValue(metric, interval.lower)}, '
      '${_formatMetricValue(metric, interval.upper)}]';
}

String _formatPValue(_MannWhitneyResult result) {
  if (!result.available) return '-';
  final prefix = result.exact ? '' : '~';
  if (result.pValue < 0.001) return '${prefix}<0.001';
  return '$prefix${_trimDouble(result.pValue)}';
}

String _formatNs(double ns) => formatDurationNs(ns.round());

String _trimDouble(double value) {
  if (!value.isFinite) return value.toString();
  if (value.abs() >= 100) return value.toStringAsFixed(0);
  if (value.abs() >= 10) return value.toStringAsFixed(1);
  return value.toStringAsFixed(2);
}

class _PeerTraceResult {
  _PeerTraceResult({
    required this.peer,
    required this.repetition,
    required this.trace,
    required this.metrics,
    required this.childElapsedNs,
  })  : stdout = '',
        stderr = '';

  _PeerTraceResult.failed({
    required this.peer,
    required this.repetition,
    required int elapsedNs,
    required this.childElapsedNs,
    required this.stdout,
    required this.stderr,
  })  : trace = null,
        metrics = _PeerRunMetrics(
          status: 'failed',
          scenarioElapsedNs: elapsedNs,
        );

  _PeerTraceResult.unsupported({
    required this.peer,
    required this.repetition,
    required this.metrics,
    required this.childElapsedNs,
  })  : trace = null,
        stdout = '',
        stderr = '';

  final String peer;
  final int repetition;
  final Trace? trace;
  final _PeerRunMetrics metrics;
  final int childElapsedNs;
  final String stdout;
  final String stderr;

  int get elapsedNs => metrics.scenarioElapsedNs;
  int get setupElapsedNs => metrics.setupElapsedNs;
  int get warmupElapsedNs => metrics.warmupElapsedNs;
  int get measuredElapsedNs => metrics.measuredElapsedNs;
  String get status => metrics.status;
  String get unsupportedReason => metrics.unsupportedReason;
  Map<String, Object?> get measurements => metrics.measurements;
}

class _ConfidenceInterval {
  const _ConfidenceInterval({
    required this.lower,
    required this.upper,
  }) : available = true;

  const _ConfidenceInterval.unavailable()
      : lower = 0,
        upper = 0,
        available = false;

  final double lower;
  final double upper;
  final bool available;

  bool get excludesZero => available && (upper < 0 || lower > 0);
}

class _MannWhitneyResult {
  const _MannWhitneyResult({
    required this.pValue,
    required this.direction,
    required this.exact,
  }) : available = true;

  const _MannWhitneyResult.unavailable()
      : pValue = 1,
        direction = 0,
        exact = false,
        available = false;

  final double pValue;
  final double direction;
  final bool exact;
  final bool available;

  bool directionMatches(double meanChangePercent) {
    if (direction == 0 || meanChangePercent == 0) return false;
    return direction.sign == meanChangePercent.sign;
  }
}

class _OutlierSummary {
  const _OutlierSummary({
    required this.baseline,
    required this.candidate,
  });

  final int baseline;
  final int candidate;

  String toReportCell() => '$baseline/$candidate';
}

class _RankedValue {
  _RankedValue(this.value, this.isBaseline);

  final int value;
  final bool isBaseline;
  double rank = 0;
}

class _SuiteProfile {
  const _SuiteProfile({
    required this.description,
    required this.scenarios,
  });

  final String description;
  final List<_SuiteScenario> scenarios;
}

class _SuiteScenario {
  const _SuiteScenario({
    required this.name,
    required this.rows,
    required this.repetitions,
  });

  final String name;
  final int rows;
  final int repetitions;
}

_SuiteProfile _suiteProfile(String profileName) {
  return switch (profileName) {
    'ci' => const _SuiteProfile(
        description: 'Small deterministic smoke matrix for pull requests.',
        scenarios: [
          _SuiteScenario(
            name: narrowBatchInsertScenario,
            rows: 3,
            repetitions: 1,
          ),
          _SuiteScenario(
            name: pointSelectScenario,
            rows: 5,
            repetitions: 1,
          ),
          _SuiteScenario(
            name: keyedPkSubscriptionsScenario,
            rows: 4,
            repetitions: 1,
          ),
          _SuiteScenario(
            name: sqliteDiagnosticsScenario,
            rows: 4,
            repetitions: 1,
          ),
        ],
      ),
    'production' => const _SuiteProfile(
        description: 'Production-oriented matrix for benchmark replacement.',
        scenarios: [
          _SuiteScenario(
            name: narrowBatchInsertScenario,
            rows: 100,
            repetitions: 7,
          ),
          _SuiteScenario(
            name: pointSelectScenario,
            rows: 200,
            repetitions: 7,
          ),
          _SuiteScenario(
            name: feedPagingScenario,
            rows: 100,
            repetitions: 7,
          ),
          _SuiteScenario(
            name: syncBurstScenario,
            rows: 100,
            repetitions: 7,
          ),
          _SuiteScenario(
            name: chatSimScenario,
            rows: 100,
            repetitions: 7,
          ),
          _SuiteScenario(
            name: largeWorkingSetScenario,
            rows: 500,
            repetitions: 7,
          ),
          _SuiteScenario(
            name: keyedPkSubscriptionsScenario,
            rows: 20,
            repetitions: 7,
          ),
          _SuiteScenario(
            name: highCardinalityFanoutScenario,
            rows: 20,
            repetitions: 7,
          ),
          _SuiteScenario(
            name: manyStreamsWriterThroughputScenario,
            rows: 20,
            repetitions: 7,
          ),
          _SuiteScenario(
            name: sqliteDiagnosticsScenario,
            rows: 100,
            repetitions: 7,
          ),
        ],
      ),
    _ => throw ArgumentError.value(
        profileName,
        'profile',
        'expected ci or production',
      ),
  };
}

class _DoubleSample {
  _DoubleSample._({
    required this.count,
    required this.mean,
    required this.variance,
  });

  factory _DoubleSample.fromInts(List<int> values) {
    final count = values.length;
    final mean = values.fold<double>(0, (sum, value) => sum + value) / count;
    final variance = count < 2
        ? 0.0
        : values.fold<double>(
              0,
              (sum, value) => sum + math.pow(value - mean, 2),
            ) /
            (count - 1);
    return _DoubleSample._(
      count: count,
      mean: mean,
      variance: variance,
    );
  }

  final int count;
  final double mean;
  final double variance;
}

extension _AverageIntSamples on List<int> {
  double get average {
    if (isEmpty) return 0;
    return fold<double>(0, (sum, value) => sum + value) / length;
  }
}

class _PeerRunMetrics {
  const _PeerRunMetrics({
    this.status = 'ok',
    this.unsupportedReason = '',
    this.scenarioElapsedNs = 0,
    this.setupElapsedNs = 0,
    this.warmupElapsedNs = 0,
    this.measuredElapsedNs = 0,
    this.measurements = const {},
  });

  factory _PeerRunMetrics.fromJson(Map<String, Object?> json) {
    int readInt(String key) {
      final value = json[key];
      return value is int ? value : 0;
    }

    return _PeerRunMetrics(
      status: json['status'] is String ? json['status']! as String : 'ok',
      unsupportedReason: json['unsupported_reason'] is String
          ? json['unsupported_reason']! as String
          : '',
      scenarioElapsedNs: readInt('scenario_elapsed_ns'),
      setupElapsedNs: readInt('setup_elapsed_ns'),
      warmupElapsedNs: readInt('warmup_elapsed_ns'),
      measuredElapsedNs: readInt('measured_elapsed_ns'),
      measurements: json['measurements'] is Map
          ? Map<String, Object?>.from(json['measurements']! as Map)
          : const {},
    );
  }

  final String status;
  final String unsupportedReason;
  final int scenarioElapsedNs;
  final int setupElapsedNs;
  final int warmupElapsedNs;
  final int measuredElapsedNs;
  final Map<String, Object?> measurements;
}

class _LoopTiming {
  _LoopTiming({required this.elapsedNs, required this.checksum});

  final int elapsedNs;
  final int checksum;
}

class _IntStats {
  _IntStats._({
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

  factory _IntStats.fromValues(Iterable<int> values) {
    final sorted = values.toList()..sort();
    if (sorted.isEmpty) {
      return _IntStats._(
        count: 0,
        total: 0,
        min: 0,
        max: 0,
        mean: 0,
        median: 0,
        p90: 0,
        p99: 0,
        stddev: 0,
      );
    }
    final total = sorted.fold<int>(0, (sum, value) => sum + value);
    final mean = total / sorted.length;
    final variance = sorted.fold<double>(
          0,
          (sum, value) => sum + math.pow(value - mean, 2),
        ) /
        sorted.length;
    return _IntStats._(
      count: sorted.length,
      total: total,
      min: sorted.first,
      max: sorted.last,
      mean: mean,
      median: _percentile(sorted, 0.50),
      p90: _percentile(sorted, 0.90),
      p99: _percentile(sorted, 0.99),
      stddev: math.sqrt(variance),
    );
  }

  factory _IntStats.fromJson(Map<String, Object?> json) {
    return _IntStats._(
      count: json['count']! as int,
      total: json['total']! as int,
      min: json['min']! as int,
      max: json['max']! as int,
      mean: (json['mean']! as num).toDouble(),
      median: json['median']! as int,
      p90: json['p90']! as int,
      p99: json['p99']! as int,
      stddev: (json['stddev']! as num).toDouble(),
    );
  }

  final int count;
  final int total;
  final int min;
  final int max;
  final double mean;
  final int median;
  final int p90;
  final int p99;
  final double stddev;

  Map<String, Object?> toJson() => {
        'count': count,
        'total': total,
        'min': min,
        'max': max,
        'mean': mean,
        'median': median,
        'p90': p90,
        'p99': p99,
        'stddev': stddev,
        'cv': mean == 0 ? 0 : stddev / mean,
      };

  static int _percentile(List<int> values, double percentile) {
    final rank = ((values.length - 1) * percentile).ceil();
    return values[rank.clamp(0, values.length - 1)];
  }
}

Never _usage({int exitCode = 64}) {
  stderr.writeln('usage:');
  stderr.writeln('  dart run bin/tracelite.dart report <region-path>');
  stderr.writeln('  dart run bin/tracelite.dart workload-summary <region-path> '
      '[--out-json=summary.json]');
  stderr.writeln('  dart run bin/tracelite.dart compare '
      '--scenario=<${defaultScenarioNames.join('|')}> '
      '--interfaces=sqlite3,drift,sqlite_async,resqlite '
      '[--repetitions=5] [--out-json=compare.json]');
  stderr.writeln('  dart run bin/tracelite.dart suite '
      '[--profile=ci|production] [--interfaces=sqlite3,drift,...] '
      '[--out-dir=build/tracelite-suite]');
  stderr.writeln('  dart run bin/tracelite.dart diff '
      '--baseline=base.json --candidate=change.json '
      '[--metric=elapsed_ns] [--max-cv-percent=15] [--alpha=0.05]');
  stderr.writeln('  dart run bin/tracelite.dart decision '
      '--baseline=base.json --candidate=change.json '
      '[--expect=improvement|no_regression] '
      '[--primary-peer=resqlite] [--primary-metric=elapsed_ns] '
      '[--out-json=decision.json]');
  stderr.writeln('  dart run bin/tracelite.dart export-graph-data '
      '--out=graph-data '
      '[--suite=manifest.json] [--compare=compare.json] '
      '[--decision=decision.json] '
      '[--workload-summary=profile-summary.json] [--run-id=id]');
  stderr.writeln('  dart run bin/tracelite.dart calibrate '
      '[--iterations=10000] [--repetitions=5] [--out-json=calibration.json]');
  stderr.writeln('  dart run bin/tracelite.dart create-region '
      '--out=trace.tlt-region [--ring-data-words=1048576]');
  exit(exitCode);
}
