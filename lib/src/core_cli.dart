import 'dart:convert';
import 'dart:io';

import 'package:tracelite/tracelite.dart';

const Set<String> traceliteCoreCommands = {
  'report',
  'workload-summary',
  'create-region',
  'decision',
  'calibrate-policy',
  'export-graph-data',
  'validate-graph-data',
};

bool isTraceliteCoreCommand(String command) =>
    traceliteCoreCommands.contains(command);

void runTraceliteCoreCli(List<String> args) {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    printTraceliteCoreUsage(exitCode: args.isEmpty ? 64 : 0);
  }

  final command = args.first;
  switch (command) {
    case 'report':
      _report(args.skip(1).toList());
    case 'workload-summary':
      _workloadSummary(args.skip(1).toList());
    case 'create-region':
      _createRegion(args.skip(1).toList());
    case 'decision':
      _decision(args.skip(1).toList());
    case 'calibrate-policy':
      _calibratePolicy(args.skip(1).toList());
    case 'export-graph-data':
      _exportGraphData(args.skip(1).toList());
    case 'validate-graph-data':
      _validateGraphData(args.skip(1).toList());
    default:
      stderr.writeln('unknown core command: $command');
      printTraceliteCoreUsage();
  }
}

void _report(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('report expects exactly one region or trace path');
    printTraceliteCoreUsage();
  }
  stdout.write(Trace.loadRegion(args.single).toMarkdownReport());
}

void _workloadSummary(List<String> args) {
  if (args.isEmpty || args.first.startsWith('--')) {
    stderr.writeln('workload-summary expects a region or trace path');
    printTraceliteCoreUsage();
  }
  final path = args.first;
  final options = _parseOptions(args.skip(1).toList());
  final artifact = traceWorkloadSummaryArtifact(Trace.loadRegion(path));
  final outJson = options['out-json'];
  if (outJson != null && outJson.isNotEmpty) {
    _writeJson(outJson, artifact);
  }
  stdout.write(traceWorkloadSummaryMarkdown(artifact));
}

void _createRegion(List<String> args) {
  final options = _parseOptions(args);
  final out = options['out'];
  if (out == null || out.isEmpty) {
    stderr.writeln('create-region requires --out=path');
    printTraceliteCoreUsage();
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
  stdout
    ..writeln('Created tracelite region: $out')
    ..writeln('  max_producers: $maxProducers')
    ..writeln('  string_pool_bytes: $stringPoolBytes')
    ..writeln('  ring_data_words: $ringDataWords');
}

void _decision(List<String> args) {
  final options = _parseOptions(args);
  final baselinePath = options['baseline'];
  final candidatePath = options['candidate'];
  if (baselinePath == null || candidatePath == null) {
    stderr.writeln('decision requires --baseline and --candidate');
    printTraceliteCoreUsage();
  }

  final expectation = options['expect'] ?? 'improvement';
  if (expectation != 'improvement' && expectation != 'no_regression') {
    stderr.writeln('--expect must be improvement or no_regression');
    exit(64);
  }
  final calibrationPolicy = _readPolicyOption(options);
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
      primaryThresholdPercent: _doubleOption(
        options,
        'primary-threshold-percent',
        _policyDouble(calibrationPolicy, 'primary_threshold_percent', 5),
      ),
      maxRegressionPercent: _doubleOption(
        options,
        'max-regression-percent',
        _policyDouble(calibrationPolicy, 'max_regression_percent', 3),
      ),
      maxCvPercent: _doubleOption(
        options,
        'max-cv-percent',
        _policyDouble(calibrationPolicy, 'max_cv_percent', 15),
      ),
      alpha: double.tryParse(options['alpha'] ?? '0.05') ?? 0.05,
    ),
  );

  final outJson = options['out-json'];
  if (outJson != null && outJson.isNotEmpty) {
    _writeJson(outJson, decision);
  }
  stdout.write(benchmarkDecisionMarkdown(decision));
  if (!benchmarkDecisionPassed(decision)) {
    exitCode = 65;
  }
}

void _calibratePolicy(List<String> args) {
  final options = _parseOptions(args, multiValueKeys: const {'history'});
  final historyPaths = _csvOption(options['history']);
  if (historyPaths.isEmpty) {
    stderr.writeln('calibrate-policy requires --history=path');
    printTraceliteCoreUsage();
  }

  final seen = <String>{};
  final inputs = <BenchmarkPolicyCalibrationInput>[];
  try {
    for (final historyPath in historyPaths) {
      inputs.addAll(_policyHistoryInputs(historyPath, seen));
    }
  } on FileSystemException catch (error) {
    stderr.writeln('${error.message}: ${error.path}');
    exit(66);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exit(65);
  }
  if (inputs.isEmpty) {
    stderr.writeln('calibrate-policy found no compare artifacts');
    exit(65);
  }

  final artifact = benchmarkPolicyCalibrationArtifact(
    compareArtifacts: inputs,
    options: BenchmarkPolicyCalibrationOptions(
      metrics: _csvOption(
        options['metrics'],
        defaultValue: defaultPolicyCalibrationMetrics,
      ),
      scenarios: _csvOption(options['scenarios']),
      peers: _csvOption(options['peers']),
      minHistoryRuns: _positiveIntOption(options, 'min-history-runs', 2),
      minRepetitions: _positiveIntOption(options, 'min-repetitions', 5),
      maxRepetitions: _positiveIntOption(options, 'max-repetitions', 30),
      targetRelativeStandardErrorPercent: _positiveDoubleOption(
        options,
        'target-rse-percent',
        2.5,
      ),
      withinRunNoisePercentile: _positiveDoubleOption(
        options,
        'within-run-noise-percentile',
        0.75,
      ),
      thresholdFloorPercent: _positiveDoubleOption(
        options,
        'threshold-floor-percent',
        5,
      ),
      guardrailFloorPercent: _positiveDoubleOption(
        options,
        'guardrail-floor-percent',
        3,
      ),
      noiseGateFloorPercent: _positiveDoubleOption(
        options,
        'noise-gate-floor-percent',
        5,
      ),
      noiseGateMultiplier: _positiveDoubleOption(
        options,
        'noise-gate-multiplier',
        1.5,
      ),
      maxOutlierPercent: _positiveDoubleOption(
        options,
        'max-outlier-percent',
        10,
      ),
      maxRunOutlierPercent: _positiveDoubleOption(
        options,
        'max-run-outlier-percent',
        20,
      ),
      thresholdCeilingPercent: _positiveDoubleOptionOrNull(
        options,
        'threshold-ceiling-percent',
      ),
      guardrailCeilingPercent: _positiveDoubleOptionOrNull(
        options,
        'guardrail-ceiling-percent',
      ),
      noiseGateCeilingPercent: _positiveDoubleOptionOrNull(
        options,
        'noise-gate-ceiling-percent',
      ),
    ),
  );

  final outJson = options['out-json'];
  if (outJson != null && outJson.isNotEmpty) {
    _writeJson(outJson, artifact);
  }
  stdout.write(benchmarkPolicyCalibrationMarkdown(artifact));
  if (_boolOption(options, 'strict', false) &&
      !benchmarkPolicyCalibrationPassed(artifact)) {
    exitCode = 65;
  }
}

void _exportGraphData(List<String> args) {
  final options = _parseOptions(
    args,
    multiValueKeys: const {
      'compare',
      'suite',
      'suite-history',
      'decision',
      'workload-summary',
    },
  );
  final out = options['out'];
  if (out == null || out.isEmpty) {
    stderr.writeln('export-graph-data requires --out=directory');
    printTraceliteCoreUsage();
  }

  final compareInputs = <GraphDataInput>[
    for (final path in _csvOption(options['compare'])) _graphInput(path),
    for (final path in _csvOption(options['suite'])) ..._suiteGraphInputs(path),
    for (final path in _csvOption(options['suite-history']))
      ..._suiteHistoryGraphInputs(path),
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
      'export-graph-data requires at least one of --compare, --suite, '
      '--suite-history, --decision, or --workload-summary',
    );
    printTraceliteCoreUsage();
  }

  final bundle = traceliteGraphDataBundle(
    runId: options['run-id'],
    compareArtifacts: compareInputs,
    decisionArtifacts: decisionInputs,
    workloadSummaries: workloadInputs,
  );
  final files = _writeGraphDataBundle(Directory(out), bundle);
  final validationErrors = validateGraphDataDirectory(out);
  if (validationErrors.isNotEmpty) {
    stderr.writeln('exported graph data failed validation:');
    for (final error in validationErrors) {
      stderr.writeln('- $error');
    }
    exit(65);
  }
  _printGraphDataReport(outDir: out, bundle: bundle, files: files);
}

void _validateGraphData(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('validate-graph-data expects a graph-data directory');
    printTraceliteCoreUsage();
  }
  final errors = validateGraphDataDirectory(args.single);
  if (errors.isEmpty) {
    stdout.writeln('graph data valid: ${args.single}');
    return;
  }
  stderr.writeln('graph data invalid: ${args.single}');
  for (final error in errors) {
    stderr.writeln('- $error');
  }
  exit(65);
}

Map<String, String> _parseOptions(
  List<String> args, {
  Set<String> multiValueKeys = const {},
}) {
  final options = <String, String>{};
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (!arg.startsWith('--')) {
      stderr.writeln('unexpected argument: $arg');
      printTraceliteCoreUsage();
    }
    final eq = arg.indexOf('=');
    if (eq == -1) {
      final key = arg.substring(2);
      if (key.isEmpty) printTraceliteCoreUsage();
      if (index + 1 < args.length && !args[index + 1].startsWith('--')) {
        _setOptionValue(
          options,
          key,
          args[++index],
          append: multiValueKeys.contains(key),
        );
      } else {
        _setOptionValue(
          options,
          key,
          'true',
          append: multiValueKeys.contains(key),
        );
      }
    } else {
      final key = arg.substring(2, eq);
      if (key.isEmpty) printTraceliteCoreUsage();
      _setOptionValue(
        options,
        key,
        arg.substring(eq + 1),
        append: multiValueKeys.contains(key),
      );
    }
  }
  return options;
}

void _setOptionValue(
  Map<String, String> options,
  String key,
  String value, {
  required bool append,
}) {
  if (append && options.containsKey(key) && options[key]!.isNotEmpty) {
    options[key] = '${options[key]},$value';
  } else {
    options[key] = value;
  }
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

Map<String, Object?>? _readPolicyOption(Map<String, String> options) {
  final path = options['policy'];
  if (path == null || path.isEmpty) return null;
  final artifact = _readJsonMap(path);
  if (artifact['schema'] != benchmarkPolicyCalibrationSchema) {
    stderr.writeln('$path is not a tracelite policy calibration artifact');
    exit(65);
  }
  final status = artifact['status'];
  final allowUnready = _boolOption(options, 'allow-unready-policy', false);
  if (!allowUnready && status != 'ready') {
    stderr.writeln(
      '$path has policy calibration status `$status`; collect more history '
      'or pass --allow-unready-policy=true for exploratory use',
    );
    exit(65);
  }
  final policy = artifact['policy'];
  if (policy is! Map<String, Object?>) {
    stderr.writeln('$path has no policy object');
    exit(65);
  }
  return policy;
}

double _policyDouble(
  Map<String, Object?>? policy,
  String name,
  double defaultValue,
) {
  if (policy == null) return defaultValue;
  final value = policy[name];
  if (value is num) return value.toDouble();
  stderr.writeln('policy value `$name` must be numeric');
  exit(65);
}

List<BenchmarkPolicyCalibrationInput> _policyHistoryInputs(
  String path,
  Set<String> seen,
) {
  final directory = Directory(path);
  if (directory.existsSync()) {
    return _policyHistoryDirectoryInputs(directory, seen);
  }
  final file = File(path);
  if (file.existsSync()) {
    return _policyHistoryFileInputs(file, seen, explicit: true);
  }
  throw FileSystemException('policy history path does not exist', path);
}

List<BenchmarkPolicyCalibrationInput> _policyHistoryDirectoryInputs(
  Directory directory,
  Set<String> seen,
) {
  final files = directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final inputs = <BenchmarkPolicyCalibrationInput>[];
  for (final file in files) {
    inputs.addAll(_policyHistoryFileInputs(file, seen, explicit: false));
  }
  return inputs;
}

List<BenchmarkPolicyCalibrationInput> _policyHistoryFileInputs(
  File file,
  Set<String> seen, {
  required bool explicit,
}) {
  late final Map<String, Object?> root;
  try {
    root = _readJsonMap(file.path);
  } on FormatException {
    if (explicit) rethrow;
    return const [];
  }

  return switch (root['schema']) {
    'tracelite.compare.v1' => _dedupPolicyInput(file.path, root, seen),
    'tracelite.suite.v1' => _policyInputsFromSuite(file.path, root, seen),
    'tracelite.suite_history.v1' =>
      _policyInputsFromSuiteHistory(file.path, root, seen),
    _ => explicit
        ? throw FormatException(
            '${file.path} is not a tracelite compare artifact, suite '
            'manifest, or suite history manifest',
          )
        : const <BenchmarkPolicyCalibrationInput>[],
  };
}

List<BenchmarkPolicyCalibrationInput> _policyInputsFromSuite(
  String manifestPath,
  Map<String, Object?> manifest,
  Set<String> seen,
) {
  final runs = manifest['runs'];
  if (runs is! List<Object?>) {
    throw FormatException('$manifestPath has no runs list');
  }
  final inputs = <BenchmarkPolicyCalibrationInput>[];
  for (final run in runs.cast<Map<String, Object?>>()) {
    final artifactPath = _resolveManifestArtifactPath(
      manifestPath,
      run['artifact']! as String,
    );
    inputs.addAll(
      _dedupPolicyInput(artifactPath, _readJsonMap(artifactPath), seen),
    );
  }
  return inputs;
}

List<BenchmarkPolicyCalibrationInput> _policyInputsFromSuiteHistory(
  String historyPath,
  Map<String, Object?> history,
  Set<String> seen,
) {
  final runs = history['runs'];
  if (runs is! List<Object?>) {
    throw FormatException('$historyPath has no runs list');
  }
  final inputs = <BenchmarkPolicyCalibrationInput>[];
  for (final run in runs.cast<Map<String, Object?>>()) {
    if (run['status'] != 'ok') continue;
    final manifest = run['manifest'];
    if (manifest is! String || manifest.isEmpty) continue;
    final manifestPath = _resolveManifestArtifactPath(historyPath, manifest);
    inputs.addAll(_policyHistoryFileInputs(
      File(manifestPath),
      seen,
      explicit: true,
    ));
  }
  return inputs;
}

List<BenchmarkPolicyCalibrationInput> _dedupPolicyInput(
  String path,
  Map<String, Object?> artifact,
  Set<String> seen,
) {
  final absolutePath = File(path).absolute.path;
  if (!seen.add(absolutePath)) return const [];
  return [
    BenchmarkPolicyCalibrationInput(path: absolutePath, artifact: artifact),
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

List<GraphDataInput> _suiteHistoryGraphInputs(String historyPath) {
  final history = _readJsonMap(historyPath);
  if (history['schema'] != 'tracelite.suite_history.v1') {
    throw FormatException('$historyPath is not a tracelite suite history');
  }
  final runs = history['runs'];
  if (runs is! List<Object?>) {
    throw FormatException('$historyPath has no runs list');
  }
  final inputs = <GraphDataInput>[];
  for (final run in runs.cast<Map<String, Object?>>()) {
    if (run['status'] != 'ok') continue;
    final manifest = run['manifest'];
    if (manifest is! String || manifest.isEmpty) continue;
    final manifestPath = _resolveManifestArtifactPath(historyPath, manifest);
    inputs.addAll(_suiteGraphInputs(manifestPath));
  }
  return inputs;
}

String _resolveManifestArtifactPath(String manifestPath, String artifactPath) {
  final artifact = File(artifactPath);
  if (artifact.isAbsolute || artifact.existsSync()) return artifact.path;
  return File(manifestPath).parent.uri.resolve(artifactPath).toFilePath();
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

List<String> _csvOption(String? value, {List<String> defaultValue = const []}) {
  if (value == null || value.trim().isEmpty) return defaultValue;
  return value
      .split(',')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
}

bool _boolOption(Map<String, String> options, String name, bool defaultValue) {
  final value = options[name];
  if (value == null) return defaultValue;
  return value == 'true' || value == '1' || value == 'yes';
}

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
  if ((value & (value - 1)) != 0) {
    stderr.writeln('--$name must be a power of two');
    exit(64);
  }
  return value;
}

double _doubleOption(
  Map<String, String> options,
  String name,
  double defaultValue,
) {
  final raw = options[name];
  if (raw == null) return defaultValue;
  final value = double.tryParse(raw);
  if (value == null) {
    stderr.writeln('--$name must be numeric');
    exit(64);
  }
  return value;
}

double _positiveDoubleOption(
  Map<String, String> options,
  String name,
  double defaultValue,
) {
  final value = _doubleOption(options, name, defaultValue);
  if (value <= 0) {
    stderr.writeln('--$name must be positive');
    exit(64);
  }
  return value;
}

double? _positiveDoubleOptionOrNull(
  Map<String, String> options,
  String name,
) {
  if (!options.containsKey(name)) return null;
  return _positiveDoubleOption(options, name, 0);
}

void _writeJson(String path, Map<String, Object?> artifact) {
  const encoder = JsonEncoder.withIndent('  ');
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('${encoder.convert(artifact)}\n');
}

Never printTraceliteCoreUsage({int exitCode = 64}) {
  stderr.writeln('Usage:');
  stderr.writeln('  dart run bin/tracelite.dart report <region>');
  stderr.writeln('  dart run bin/tracelite.dart workload-summary <region>');
  stderr.writeln('  dart run bin/tracelite.dart create-region --out=path');
  stderr.writeln(
    '  dart run bin/tracelite.dart decision --baseline=base.json '
    '--candidate=change.json',
  );
  stderr
      .writeln('  dart run bin/tracelite.dart calibrate-policy --history=dir');
  stderr.writeln(
    '  dart run bin/tracelite.dart export-graph-data --out=dir '
    '[--compare=compare.json] [--suite=manifest.json] '
    '[--suite-history=history.json] [--decision=decision.json] '
    '[--workload-summary=summary.json]',
  );
  stderr.writeln('  dart run bin/tracelite.dart validate-graph-data <dir>');
  stderr.writeln('');
  stderr.writeln(
    'Source-checkout peer commands: compare, suite, suite-history.',
  );
  exit(exitCode);
}
