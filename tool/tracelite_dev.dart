import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:tracelite/src/core_cli.dart';
import 'package:tracelite/src/native_artifacts.dart' as native_artifacts;
import 'package:tracelite/tracelite.dart';

import 'src/peer.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    _usage(exitCode: args.isEmpty ? 64 : 0);
  }

  final command = args.first;
  switch (command) {
    case 'doctor':
      await _doctor(args.skip(1).toList());
    case 'report':
    case 'workload-summary':
    case 'create-region':
    case 'diff':
    case 'decision':
    case 'calibrate-policy':
    case 'export-graph-data':
    case 'validate-graph-data':
      runTraceliteCoreCli(args);
    case 'compare':
      await _compare(args.skip(1).toList());
    case 'visualize':
      await _visualize(args.skip(1).toList());
    case 'suite':
      await _suite(args.skip(1).toList());
    case 'suite-history':
      await _suiteHistory(args.skip(1).toList());
    case 'calibrate':
      await _calibrate(args.skip(1).toList());
    case '_run-peer':
      await _runPeer(args.skip(1).toList());
    default:
      stderr.writeln('unknown command: $command');
      _usage();
  }
}

Future<void> _doctor(List<String> args) async {
  final options = _parseOptions(args);
  final root = Directory(_canonicalDirectoryPath(options['root'] ?? '.'));
  final strict = _boolOption(options, 'strict', false);
  final jsonOut = options['json'];
  final checks = <_DoctorCheck>[];

  void requiredFile(String relativePath) {
    final file = File(_joinPath(root.path, relativePath));
    checks.add(
      file.existsSync()
          ? _DoctorCheck.ok(
              'source file',
              relativePath,
            )
          : _DoctorCheck.fail(
              'source file',
              'missing $relativePath',
              action: 'Run doctor from a tracelite checkout or pass '
                  '--root=/path/to/tracelite.',
            ),
    );
  }

  void requiredDirectory(String relativePath) {
    final directory = Directory(_joinPath(root.path, relativePath));
    checks.add(
      directory.existsSync()
          ? _DoctorCheck.ok(
              'source directory',
              relativePath,
            )
          : _DoctorCheck.fail(
              'source directory',
              'missing $relativePath',
              action: 'Run doctor from a tracelite checkout or pass '
                  '--root=/path/to/tracelite.',
            ),
    );
  }

  requiredFile('pubspec.yaml');
  requiredFile('bin/tracelite.dart');
  requiredFile('tool/tracelite_dev.dart');
  requiredFile('tool/src/peer.dart');
  requiredFile('native/tracelite_runtime.c');
  requiredFile('native/tracelite_runtime.h');
  requiredFile('native/shim_sqlite3.c');
  requiredFile('tool/spans.yaml');
  requiredDirectory('tool/visualizer_app');

  for (final generated in const [
    'lib/src/builtin_spans.g.dart',
    'native/builtin_spans.g.h',
    'doc/format-spec.appendix.md',
    'doc/span-registry.generated.md',
  ]) {
    final file = File(_joinPath(root.path, generated));
    checks.add(
      file.existsSync()
          ? _DoctorCheck.ok('generated file', generated)
          : _DoctorCheck.fail(
              'generated file',
              'missing $generated',
              action: 'Run `dart run tool/generate.dart`.',
            ),
    );
  }

  final packageConfig = File(
    _joinPath(root.path, _joinPath('.dart_tool', 'package_config.json')),
  );
  checks.add(
    packageConfig.existsSync()
        ? _DoctorCheck.ok('dart dependencies', packageConfig.path)
        : _DoctorCheck.warn(
            'dart dependencies',
            'missing ${packageConfig.path}',
            action: 'Run `dart pub get` before suites or visualizer work.',
          ),
  );

  final runtime = File(
    _joinPath(root.path, native_artifacts.defaultRuntimeLibraryPath()),
  );
  checks.add(
    runtime.existsSync()
        ? _DoctorCheck.ok('native runtime', runtime.path)
        : _DoctorCheck.warn(
            'native runtime',
            'missing ${runtime.path}',
            action: native_artifacts.runtimeBuildCommand().trim(),
          ),
  );

  final shimCommand = native_artifacts.sqliteShimBuildCommand();
  if (shimCommand != null) {
    final shim = File(
      _joinPath(root.path, native_artifacts.sqliteShimLibraryPath()),
    );
    checks.add(
      shim.existsSync()
          ? _DoctorCheck.ok('sqlite shim', shim.path)
          : _DoctorCheck.warn(
              'sqlite shim',
              'missing ${shim.path}',
              action: shimCommand.trim(),
            ),
    );
  } else {
    checks.add(
      _DoctorCheck.warn(
        'sqlite shim',
        'sqlite shim build is not implemented for '
            '${Platform.operatingSystem}.',
        action: 'Use macOS or Linux for native shim evidence until '
            'Windows shim validation lands.',
      ),
    );
  }

  final cc = await _commandVersion('cc', const ['--version']);
  checks.add(
    cc == null
        ? _DoctorCheck.warn(
            'c compiler',
            'cc was not found',
            action: 'Install a C compiler before building native artifacts.',
          )
        : _DoctorCheck.ok('c compiler', _firstLine(cc)),
  );

  checks
      .add(_DoctorCheck.ok('dart runtime', Platform.version.split('\n').first));

  final flutter = await _commandVersion('flutter', const ['--version']);
  checks.add(
    flutter == null
        ? _DoctorCheck.warn(
            'visualizer runtime',
            'flutter was not found',
            action: 'Install Flutter before using `tracelite visualize`.',
          )
        : _DoctorCheck.ok('visualizer runtime', _firstLine(flutter)),
  );

  final failures = checks.where((check) => check.status == 'fail').toList();
  final warnings = checks.where((check) => check.status == 'warn').toList();
  final status = failures.isNotEmpty
      ? 'failed'
      : strict && warnings.isNotEmpty
          ? 'failed'
          : warnings.isNotEmpty
              ? 'warning'
              : 'ready';

  final artifact = <String, Object?>{
    'schema': 'tracelite.doctor.v1',
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'status': status,
    'strict': strict,
    'root': root.path,
    'platform': {
      'operating_system': Platform.operatingSystem,
      'version': Platform.operatingSystemVersion,
    },
    'checks': [for (final check in checks) check.toJson()],
  };

  if (jsonOut != null && jsonOut.isNotEmpty) {
    final file = File(jsonOut);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(artifact)}\n',
    );
  }

  _printDoctorReport(artifact, checks);

  if (status == 'failed') {
    if (strict && failures.isEmpty) {
      stderr.writeln('strict mode treats doctor warnings as failures.');
    }
    exit(65);
  }
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
  late final List<_SuiteScenario> scenarios;
  try {
    scenarios = _selectedSuiteScenarios(profile, options['scenarios']);
  } on ArgumentError catch (error) {
    stderr.writeln(error.message);
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
  for (final scenario in scenarios) {
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

Future<void> _suiteHistory(List<String> args) async {
  final options = _parseOptions(args);
  final profileName = options['profile'] ?? 'production';
  late final _SuiteProfile profile;
  try {
    profile = _suiteProfile(profileName);
  } on ArgumentError {
    stderr.writeln('--profile must be ci or production');
    exit(64);
  }
  late final List<_SuiteScenario> scenarios;
  try {
    scenarios = _selectedSuiteScenarios(profile, options['scenarios']);
  } on ArgumentError catch (error) {
    stderr.writeln(error.message);
    exit(64);
  }

  final runCount = _positiveIntOption(options, 'runs', 5);
  final interfaces = options['interfaces'] ?? defaultPeerNames.join(',');
  final outDir = Directory(
    options['out-dir'] ?? 'build/tracelite-$profileName-history',
  );
  outDir.createSync(recursive: true);
  final strict = _boolOption(options, 'strict', true);
  final generatedAt = DateTime.now().toUtc();
  final metrics = _csvOption(
    options['metrics'],
    defaultValue: defaultPolicyCalibrationMetrics,
  );
  final calibrationScenarios = _csvOption(
    options['policy-scenarios'] ?? options['scenarios'],
  );
  final calibrationPeers = _csvOption(
    options['policy-peers'] ?? options['peers'],
  );
  final minHistoryRuns =
      _positiveIntOptionOrNull(options, 'min-history-runs') ?? runCount;
  final calibrationOptions = BenchmarkPolicyCalibrationOptions(
    metrics: metrics,
    scenarios: calibrationScenarios,
    peers: calibrationPeers,
    minHistoryRuns: minHistoryRuns,
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
  );

  final runs = <Map<String, Object?>>[];
  stdout
    ..writeln('# tracelite suite history')
    ..writeln()
    ..writeln('Profile: `$profileName`')
    ..writeln('Runs: $runCount')
    ..writeln('Interfaces: `$interfaces`')
    ..writeln('Out dir: `${outDir.path}`')
    ..writeln('Strict: `$strict`')
    ..writeln()
    ..writeln('| run | status | manifest |')
    ..writeln('|---:|---|---|');

  var suiteFailed = false;
  for (var runIndex = 1; runIndex <= runCount; runIndex++) {
    final runStartedAt = DateTime.now().toUtc();
    final runName = _historyRunName(runIndex, runStartedAt);
    final runDir = Directory('${outDir.path}/$runName')..createSync();
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'suite',
        '--profile=$profileName',
        '--interfaces=$interfaces',
        if (options['scenarios'] != null)
          '--scenarios=${scenarios.map((scenario) => scenario.name).join(',')}',
        '--out-dir=${runDir.path}',
      ],
      workingDirectory: Directory.current.path,
    );
    final logPath = '${runDir.path}/suite.log';
    File(logPath).writeAsStringSync(
      'stdout:\n${result.stdout}\n\nstderr:\n${result.stderr}\n',
    );
    final manifestPath = '${runDir.path}/manifest.json';
    final status = result.exitCode == 0 ? 'ok' : 'failed';
    if (result.exitCode != 0) suiteFailed = true;
    runs.add({
      'run': runIndex,
      'name': runName,
      'started_at': runStartedAt.toIso8601String(),
      'completed_at': DateTime.now().toUtc().toIso8601String(),
      'directory': runDir.path,
      'manifest': manifestPath,
      'log': logPath,
      'exit_code': result.exitCode,
      'status': status,
    });
    stdout.writeln('| $runIndex | `$status` | `$manifestPath` |');
  }

  final seen = <String>{};
  final inputs = <BenchmarkPolicyCalibrationInput>[];
  for (final run in runs) {
    if (run['status'] != 'ok') continue;
    inputs.addAll(_policyHistoryInputs(run['manifest']! as String, seen));
  }

  Map<String, Object?>? calibration;
  if (inputs.isNotEmpty) {
    calibration = benchmarkPolicyCalibrationArtifact(
      compareArtifacts: inputs,
      options: calibrationOptions,
    );
  }

  final policyJsonPath = '${outDir.path}/policy-calibration.json';
  final policyMarkdownPath = '${outDir.path}/policy-calibration.md';
  const encoder = JsonEncoder.withIndent('  ');
  if (calibration != null) {
    File(policyJsonPath).writeAsStringSync('${encoder.convert(calibration)}\n');
    File(policyMarkdownPath)
        .writeAsStringSync(benchmarkPolicyCalibrationMarkdown(calibration));
  }

  final historyManifestPath = '${outDir.path}/history.json';
  final historyManifest = {
    'schema': 'tracelite.suite_history.v1',
    'generated_at': generatedAt.toIso8601String(),
    'profile': profileName,
    'scenarios': scenarios.map((scenario) => scenario.name).toList(),
    'interfaces': interfaces.split(',').map((name) => name.trim()).toList(),
    'requested_runs': runCount,
    'successful_runs':
        runs.where((run) => run['status'] == 'ok').toList().length,
    'strict': strict,
    'calibration_status': calibration?['status'] ?? 'missing',
    if (calibration != null) ...{
      'policy_artifact': policyJsonPath,
      'policy_markdown': policyMarkdownPath,
    },
    'calibration_options': calibrationOptions.toJson(),
    'runs': runs,
  };
  File(historyManifestPath).writeAsStringSync(
    '${encoder.convert(historyManifest)}\n',
  );

  stdout
    ..writeln()
    ..writeln('History: `$historyManifestPath`');
  if (calibration == null) {
    stdout.writeln('Policy calibration: `missing`');
  } else {
    stdout
      ..writeln('Policy calibration: `$policyJsonPath`')
      ..writeln('Policy status: `${calibration['status']}`');
  }

  if (strict &&
      (suiteFailed ||
          calibration == null ||
          !benchmarkPolicyCalibrationPassed(calibration))) {
    exitCode = 65;
  }
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

  final shimBuildCommand = native_artifacts.sqliteShimBuildCommand();
  if (shimBuildCommand == null) {
    stderr.writeln(
      'sqlite shim comparison is not implemented for '
      '${Platform.operatingSystem}.',
    );
    stderr.writeln(
      'Use macOS or Linux for peer-suite evidence until Windows shim '
      'validation lands.',
    );
    exit(66);
  }

  final shim = File(native_artifacts.sqliteShimLibraryPath());
  if (!shim.existsSync()) {
    stderr.writeln('missing ${shim.path}; build it with:');
    stderr.writeln(shimBuildCommand);
    exit(66);
  }
  final resolverShim = File(native_artifacts.sqliteShimLibraryName());
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

Future<void> _visualize(List<String> args) async {
  var release = false;
  var profile = false;
  final paths = <String>[];
  for (final arg in args) {
    switch (arg) {
      case '--release':
        release = true;
      case '--profile':
        profile = true;
      default:
        paths.add(arg);
    }
  }
  if (release && profile) {
    stderr.writeln('visualize accepts only one of --release or --profile');
    _usage();
  }
  if (paths.length != 1) {
    stderr.writeln('visualize expects exactly one path');
    _usage();
  }
  final appDir = Directory('tool/visualizer_app');
  if (!appDir.existsSync()) {
    stderr.writeln('missing visualizer app directory: ${appDir.path}');
    exit(66);
  }
  final target = File(paths.single).absolute.path;
  final device = Platform.isMacOS
      ? 'macos'
      : Platform.isLinux
          ? 'linux'
          : Platform.isWindows
              ? 'windows'
              : null;
  if (device == null) {
    stderr
        .writeln('visualize is currently supported on desktop platforms only');
    exit(66);
  }
  final child = await Process.start(
    'flutter',
    [
      'run',
      '-d',
      device,
      if (release) '--release',
      if (profile) '--profile',
      '-a',
      target,
    ],
    workingDirectory: appDir.path,
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await child.exitCode;
}

Future<void> _calibrate(List<String> args) async {
  final options = _parseOptions(args);
  final iterations = _positiveIntOption(options, 'iterations', 10000);
  final repetitions = _positiveIntOption(options, 'repetitions', 5);
  final outJson = options['out-json'];
  final runtimePath =
      options['runtime'] ?? native_artifacts.defaultRuntimeLibraryPath();
  final runtime = File(runtimePath);
  if (!runtime.existsSync()) {
    stderr.writeln('missing ${runtime.path}; build it with:');
    stderr.writeln(native_artifacts.runtimeBuildCommand());
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

Map<String, String> _parseOptions(
  List<String> args, {
  Set<String> multiValueKeys = const {},
}) {
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
      _setOptionValue(
        result,
        withoutPrefix.substring(0, equals),
        withoutPrefix.substring(equals + 1),
        multiValueKeys: multiValueKeys,
      );
    } else {
      if (i + 1 >= args.length) {
        stderr.writeln('missing value for $arg');
        _usage();
      }
      _setOptionValue(
        result,
        withoutPrefix,
        args[++i],
        multiValueKeys: multiValueKeys,
      );
    }
  }
  return result;
}

void _setOptionValue(
  Map<String, String> result,
  String key,
  String value, {
  required Set<String> multiValueKeys,
}) {
  if (multiValueKeys.contains(key) && result.containsKey(key)) {
    result[key] = '${result[key]},$value';
  } else {
    result[key] = value;
  }
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
      'measured elapsed avg | measured cv | scenario elapsed avg | '
      'scenario cv | traced total avg | diagnostics max |',
    )
    ..writeln('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|');

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
    final measuredElapsed = _metric(summary, 'measured_elapsed_ns');
    final total = _metric(summary, 'trace_span_total_ns');
    final dropped = _metric(summary, 'dropped_events');
    final unmatchedBegin = _metric(summary, 'unmatched_begin_events');
    final unmatchedEnd = _metric(summary, 'unmatched_end_events');
    stdout.writeln(
      '| `${peer['peer']}` | ${peer['status']} | $successful/$repetitions | '
      '${_formatMean(events)} | ${_formatMean(spans)} | '
      '${_formatMean(steps)} | ${_formatDurationMean(measuredElapsed)} | '
      '${_formatCv(measuredElapsed)} | ${_formatDurationMean(elapsed)} | '
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
    BenchmarkPolicyCalibrationInput(
      path: absolutePath,
      artifact: artifact,
    ),
  ];
}

_PeerRunMetrics _readPeerMetrics(String path) {
  final file = File(path);
  if (!file.existsSync()) return const _PeerRunMetrics();
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) return const _PeerRunMetrics();
  return _PeerRunMetrics.fromJson(decoded);
}

_IntStats _metric(Map<String, Object?> summary, String metric) {
  final value = summary[metric];
  if (value is! Map<String, Object?>) {
    throw ArgumentError.value(metric, 'metric', 'not present in summary');
  }
  return _IntStats.fromJson(value);
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

int _positiveIntOption(
  Map<String, String> options,
  String name,
  int defaultValue,
) {
  return _positiveIntOptionOrNull(options, name) ?? defaultValue;
}

int? _positiveIntOptionOrNull(
  Map<String, String> options,
  String name,
) {
  final raw = options[name];
  if (raw == null) return null;
  final value = int.tryParse(raw);
  if (value == null || value <= 0) {
    stderr.writeln('--$name must be a positive integer');
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
    stderr.writeln('--$name must be a positive number');
    exit(64);
  }
  return value;
}

double? _positiveDoubleOptionOrNull(
  Map<String, String> options,
  String name,
) {
  final raw = options[name];
  if (raw == null) return null;
  final value = double.tryParse(raw);
  if (value == null || value <= 0) {
    stderr.writeln('--$name must be a positive number');
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
    stderr.writeln('--$name must be a number');
    exit(64);
  }
  return value;
}

bool _boolOption(
  Map<String, String> options,
  String name,
  bool defaultValue,
) {
  final raw = options[name];
  if (raw == null) return defaultValue;
  final normalized = raw.toLowerCase();
  if (normalized == '1' || normalized == 'true' || normalized == 'yes') {
    return true;
  }
  if (normalized == '0' || normalized == 'false' || normalized == 'no') {
    return false;
  }
  stderr.writeln('--$name must be true or false');
  exit(64);
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

String _joinPath(String first, String second) {
  if (first.isEmpty || first == '.') return second;
  if (second.isEmpty) return first;
  final separator = Platform.pathSeparator;
  if (first.endsWith(separator)) return '$first$second';
  return '$first$separator$second';
}

String _canonicalDirectoryPath(String path) {
  final directory = Directory(path).absolute;
  try {
    return directory.resolveSymbolicLinksSync();
  } on FileSystemException {
    return directory.path;
  }
}

Future<String?> _commandVersion(String executable, List<String> args) async {
  try {
    final result = await Process.run(executable, args);
    if (result.exitCode != 0) return null;
    final output = '${result.stdout}${result.stderr}'.trim();
    return output.isEmpty ? executable : output;
  } on ProcessException {
    return null;
  }
}

String _firstLine(String value) {
  return value.split(RegExp(r'\r?\n')).first.trim();
}

void _printDoctorReport(
  Map<String, Object?> artifact,
  List<_DoctorCheck> checks,
) {
  stdout
    ..writeln('# tracelite doctor')
    ..writeln()
    ..writeln('Status: `${artifact['status']}`')
    ..writeln('Root: `${artifact['root']}`')
    ..writeln('Platform: `${Platform.operatingSystem}`')
    ..writeln()
    ..writeln('| check | status | detail |')
    ..writeln('|---|---|---|');
  for (final check in checks) {
    stdout.writeln(
      '| ${check.name} | `${check.status}` | ${_markdownCell(check.detail)} |',
    );
  }

  final actions = [
    for (final check in checks)
      if (check.status != 'ok' && check.action != null) check.action!,
  ];
  if (actions.isNotEmpty) {
    stdout
      ..writeln()
      ..writeln('Next steps:');
    for (final action in actions.toSet()) {
      stdout.writeln('- $action');
    }
  }
}

String _markdownCell(String value) {
  return value.replaceAll('|', r'\|').replaceAll('\n', '<br>');
}

final class _DoctorCheck {
  const _DoctorCheck._({
    required this.name,
    required this.status,
    required this.detail,
    this.action,
  });

  factory _DoctorCheck.ok(String name, String detail) {
    return _DoctorCheck._(name: name, status: 'ok', detail: detail);
  }

  factory _DoctorCheck.warn(
    String name,
    String detail, {
    required String action,
  }) {
    return _DoctorCheck._(
      name: name,
      status: 'warn',
      detail: detail,
      action: action,
    );
  }

  factory _DoctorCheck.fail(
    String name,
    String detail, {
    required String action,
  }) {
    return _DoctorCheck._(
      name: name,
      status: 'fail',
      detail: detail,
      action: action,
    );
  }

  final String name;
  final String status;
  final String detail;
  final String? action;

  Map<String, Object?> toJson() => {
        'name': name,
        'status': status,
        'detail': detail,
        if (action != null) 'action': action,
      };
}

String _historyRunName(int runIndex, DateTime timestamp) {
  final compact = timestamp
      .toIso8601String()
      .replaceAll('-', '')
      .replaceAll(':', '')
      .replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
  return 'run-${runIndex.toString().padLeft(3, '0')}-$compact';
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
            rows: 500,
            repetitions: 7,
          ),
          _SuiteScenario(
            name: pointSelectScenario,
            rows: 200,
            repetitions: 7,
          ),
          _SuiteScenario(
            name: feedPagingScenario,
            rows: 1000,
            repetitions: 7,
          ),
          _SuiteScenario(
            name: syncBurstScenario,
            rows: 100,
            repetitions: 7,
          ),
          _SuiteScenario(
            name: chatSimScenario,
            rows: 200,
            repetitions: 11,
          ),
          _SuiteScenario(
            name: largeWorkingSetScenario,
            rows: 2500,
            repetitions: 7,
          ),
          _SuiteScenario(
            name: keyedPkSubscriptionsScenario,
            rows: 20,
            repetitions: 7,
          ),
          _SuiteScenario(
            name: highCardinalityFanoutScenario,
            rows: 40,
            repetitions: 11,
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

List<_SuiteScenario> _selectedSuiteScenarios(
  _SuiteProfile profile,
  String? scenarioOption,
) {
  final selectedNames = _csvOption(scenarioOption);
  if (selectedNames.isEmpty) return profile.scenarios;

  final scenariosByName = {
    for (final scenario in profile.scenarios) scenario.name: scenario,
  };
  final unknown = selectedNames
      .where((scenarioName) => !scenariosByName.containsKey(scenarioName))
      .toList();
  if (unknown.isNotEmpty) {
    throw ArgumentError(
      'unknown suite scenario(s): ${unknown.join(', ')}',
    );
  }

  return [
    for (final scenarioName in selectedNames) scenariosByName[scenarioName]!,
  ];
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
  stderr.writeln('  dart run bin/tracelite.dart doctor '
      '[--root=/path/to/tracelite] [--strict=true] [--json=doctor.json]');
  stderr.writeln('  dart run bin/tracelite.dart report <region-path>');
  stderr.writeln('  dart run bin/tracelite.dart workload-summary <region-path> '
      '[--out-json=summary.json]');
  stderr.writeln('  dart run bin/tracelite.dart compare '
      '--scenario=<${defaultScenarioNames.join('|')}> '
      '--interfaces=sqlite3,drift,sqlite_async,resqlite '
      '[--repetitions=5] [--out-json=compare.json]');
  stderr.writeln('  dart run bin/tracelite.dart suite '
      '[--profile=ci|production] [--interfaces=sqlite3,drift,...] '
      '[--scenarios=narrow-batch-insert,...] '
      '[--out-dir=build/tracelite-suite]');
  stderr.writeln('  dart run bin/tracelite.dart suite-history '
      '[--profile=production] [--runs=5] [--interfaces=sqlite3,drift,...] '
      '[--scenarios=narrow-batch-insert,...] '
      '[--metrics=elapsed_ns,...] [--target-rse-percent=2.5] '
      '[--within-run-noise-percentile=0.75] '
      '[--policy-peers=resqlite] [--policy-scenarios=feed-paging,...] '
      '[--threshold-ceiling-percent=50] '
      '[--max-outlier-percent=10] [--max-run-outlier-percent=20] '
      '[--out-dir=build/tracelite-production-history]');
  stderr.writeln('  dart run bin/tracelite.dart diff '
      '--baseline=base.json --candidate=change.json '
      '[--metric=elapsed_ns] [--policy=policy-calibration.json] '
      '[--max-cv-percent=15] [--alpha=0.05]');
  stderr.writeln('  dart run bin/tracelite.dart decision '
      '--baseline=base.json --candidate=change.json '
      '[--expect=improvement|no_regression] '
      '[--primary-peer=resqlite] [--primary-metric=elapsed_ns] '
      '[--policy=policy-calibration.json] [--out-json=decision.json]');
  stderr.writeln('  dart run bin/tracelite.dart calibrate-policy '
      '--history=manifest-or-directory '
      '[--metrics=elapsed_ns,measured_elapsed_ns] '
      '[--peers=resqlite] [--scenarios=feed-paging,...] [--strict=true] '
      '[--within-run-noise-percentile=0.75] '
      '[--threshold-ceiling-percent=50] '
      '[--max-outlier-percent=10] [--max-run-outlier-percent=20] '
      '[--out-json=policy-calibration.json]');
  stderr.writeln('  dart run bin/tracelite.dart export-graph-data '
      '--out=graph-data '
      '[--suite=manifest.json] [--suite-history=history.json] '
      '[--compare=compare.json] '
      '[--decision=decision.json] '
      '[--workload-summary=profile-summary.json] [--run-id=id]');
  stderr.writeln(
    '  dart run bin/tracelite.dart validate-graph-data graph-data',
  );
  stderr.writeln(
    '  dart run bin/tracelite.dart visualize [--release|--profile] '
    '<trace-or-artifact-path>',
  );
  stderr.writeln('  dart run bin/tracelite.dart calibrate '
      '[--iterations=10000] [--repetitions=5] [--out-json=calibration.json]');
  stderr.writeln('  dart run bin/tracelite.dart create-region '
      '--out=trace.tlt-region [--ring-data-words=1048576]');
  exit(exitCode);
}
