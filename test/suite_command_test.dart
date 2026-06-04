import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/peer_definitions.dart' show reactiveWriteCount;

void main() {
  test('suite writes a CI manifest and per-scenario artifacts', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-suite-command-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'suite',
        '--profile=ci',
        '--interfaces=sqlite3',
        '--out-dir=${tempDir.path}',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'suite failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );

    final manifest = jsonDecode(
      File('${tempDir.path}/manifest.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(manifest['schema'], 'tracelite.suite.v1');
    expect(manifest['profile'], 'ci');
    final source = manifest['tracelite_source'] as Map<String, Object?>;
    expect(source['kind'], 'git');
    expect(source['revision'], isA<String>());
    final runner = manifest['runner'] as Map<String, Object?>;
    expect(runner['mode'], 'app_jit');
    expect(runner['requested_mode'], 'auto');
    expect(runner['build_elapsed_ns'] as int, greaterThan(0));
    final runs = manifest['runs']! as List<Object?>;
    expect(runs, hasLength(4));
    for (final run in runs.cast<Map<String, Object?>>()) {
      expect(run['status'], 'ok');
      expect(File(run['artifact']! as String).existsSync(), isTrue);
      expect(File(run['log']! as String).existsSync(), isTrue);
      expect(
        File(run['log']! as String).readAsStringSync(),
        contains('# tracelite compare'),
      );
    }

    final firstRun = runs.first as Map<String, Object?>;
    final firstArtifact = jsonDecode(
      File(firstRun['artifact']! as String).readAsStringSync(),
    ) as Map<String, Object?>;
    final artifactRunner = firstArtifact['runner'] as Map<String, Object?>;
    expect(artifactRunner['mode'], 'app_jit');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('suite filters the actual run matrix by --scenarios', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-suite-scenario-filter-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'suite',
        '--profile=ci',
        '--interfaces=sqlite3',
        '--scenarios=narrow-batch-insert',
        '--out-dir=${tempDir.path}',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'suite failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );

    final manifest = jsonDecode(
      File('${tempDir.path}/manifest.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final runs = manifest['runs']! as List<Object?>;
    expect(runs, hasLength(1));
    final runner = manifest['runner'] as Map<String, Object?>;
    expect(runner['mode'], 'script');
    expect(
      runs.single as Map<String, Object?>,
      containsPair('scenario', 'narrow-batch-insert'),
    );
    expect(
      File('${tempDir.path}/narrow-batch-insert.json').existsSync(),
      isTrue,
    );
    expect(File('${tempDir.path}/point-select.json').existsSync(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('experiment profile is a medium repeated preset', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-suite-experiment-profile-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'suite',
        '--profile=experiment',
        '--interfaces=sqlite3',
        '--scenarios=narrow-batch-insert',
        '--out-dir=${tempDir.path}',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'suite failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );

    final manifest = jsonDecode(
      File('${tempDir.path}/manifest.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(manifest['profile'], 'experiment');
    expect(
      manifest['description'],
      contains('day-to-day performance experiments'),
    );
    final runs = manifest['runs']! as List<Object?>;
    expect(runs, hasLength(1));
    final runner = manifest['runner'] as Map<String, Object?>;
    expect(runner['mode'], 'app_jit');
    final run = runs.single as Map<String, Object?>;
    expect(run['scenario'], 'narrow-batch-insert');
    expect(run['rows'], 100);
    expect(run['repetitions'], 5);
    expect(run['status'], 'ok');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('production profile sizes formerly noisy release lanes', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-suite-production-noisy-lanes-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'suite',
        '--profile=production',
        '--interfaces=sqlite3',
        '--scenarios=point-select,keyed-pk-subscriptions',
        '--out-dir=${tempDir.path}',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'suite failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );

    final manifest = jsonDecode(
      File('${tempDir.path}/manifest.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(manifest['profile'], 'production');
    final runs =
        (manifest['runs']! as List<Object?>).cast<Map<String, Object?>>();
    expect(
      runs.singleWhere((run) => run['scenario'] == 'point-select'),
      containsPair('rows', 1000),
    );
    expect(
      runs.singleWhere(
        (run) => run['scenario'] == 'keyed-pk-subscriptions',
      ),
      containsPair('rows', 20),
    );
    expect(reactiveWriteCount(20), 200);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('suite-history writes repeated runs and calibration artifacts',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-suite-history-command-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'suite-history',
        '--profile=ci',
        '--interfaces=sqlite3',
        '--scenarios=narrow-batch-insert',
        '--runs=2',
        '--metrics=elapsed_ns',
        '--policy-peers=sqlite3',
        '--min-repetitions=1',
        '--target-rse-percent=1000',
        '--out-dir=${tempDir.path}',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'suite-history failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    expect(result.stderr.toString(), contains('# tracelite suite'));
    expect(
      result.stderr.toString(),
      contains('| `narrow-batch-insert` |'),
    );

    final history = jsonDecode(
      File('${tempDir.path}/history.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(history['schema'], 'tracelite.suite_history.v1');
    expect(history['profile'], 'ci');
    expect(history['requested_runs'], 2);
    expect(history['successful_runs'], 2);
    expect(history['calibration_status'], 'ready');
    final source = history['tracelite_source'] as Map<String, Object?>;
    expect(source['kind'], 'git');
    expect(source['revision'], isA<String>());
    final calibrationOptions =
        history['calibration_options']! as Map<String, Object?>;
    expect(calibrationOptions['peers'], ['sqlite3']);
    final runner = history['runner'] as Map<String, Object?>;
    expect(runner['requested_mode'], 'auto');
    expect(history['suite_run_timeout_seconds'], 180.0);

    final runs = history['runs']! as List<Object?>;
    expect(runs, hasLength(2));
    for (final run in runs.cast<Map<String, Object?>>()) {
      expect(run['status'], 'ok');
      expect(run['timed_out'], isFalse);
      expect(run['timeout_seconds'], 180.0);
      expect(File(run['manifest']! as String).existsSync(), isTrue);
      expect(File(run['log']! as String).existsSync(), isTrue);
    }

    final policy = jsonDecode(
      File('${tempDir.path}/policy-calibration.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(policy['schema'], 'tracelite.policy_calibration.v1');
    expect(policy['status'], 'ready');
    expect(File('${tempDir.path}/policy-calibration.md').existsSync(), isTrue);

    final recalibrate = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'calibrate-policy',
        '--history=${tempDir.path}/history.json',
        '--metrics=elapsed_ns',
        '--min-repetitions=1',
        '--target-rse-percent=1000',
        '--strict=true',
      ],
      workingDirectory: Directory.current.path,
    );
    expect(
      recalibrate.exitCode,
      0,
      reason: 'recalibrate failed.\nstdout:\n${recalibrate.stdout}\n'
          'stderr:\n${recalibrate.stderr}',
    );
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('suite-history records timed out suite runs', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-suite-history-timeout-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'suite-history',
        '--profile=ci',
        '--interfaces=sqlite3',
        '--scenarios=narrow-batch-insert',
        '--runs=1',
        '--metrics=elapsed_ns',
        '--policy-peers=sqlite3',
        '--min-repetitions=1',
        '--target-rse-percent=1000',
        '--suite-run-timeout-seconds=0.001',
        '--out-dir=${tempDir.path}',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 65);
    expect(result.stdout.toString(), contains('`timed_out`'));

    final history = jsonDecode(
      File('${tempDir.path}/history.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(history['successful_runs'], 0);
    expect(history['calibration_status'], 'missing');
    expect(history['suite_run_timeout_seconds'], 0.001);

    final runs = history['runs']! as List<Object?>;
    expect(runs, hasLength(1));
    final run = runs.single as Map<String, Object?>;
    expect(run['status'], 'timed_out');
    expect(run['timed_out'], isTrue);
    expect(run['timeout_seconds'], 0.001);
    expect(run['elapsed_ns'], isA<int>());
    final log = File(run['log']! as String).readAsStringSync();
    expect(log, contains('suite-history timeout'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('suite-history forwards scenario and repetition floor into suite runs',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-suite-history-scenario-filter-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'suite-history',
        '--profile=ci',
        '--interfaces=sqlite3',
        '--scenarios=narrow-batch-insert',
        '--runs=1',
        '--metrics=elapsed_ns',
        '--policy-peers=sqlite3',
        '--min-repetitions=2',
        '--target-rse-percent=1000',
        '--out-dir=${tempDir.path}',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'suite-history failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );

    final history = jsonDecode(
      File('${tempDir.path}/history.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(history['scenarios'], ['narrow-batch-insert']);

    final runs = history['runs']! as List<Object?>;
    final manifestPath =
        (runs.single as Map<String, Object?>)['manifest']! as String;
    final manifest = jsonDecode(File(manifestPath).readAsStringSync())
        as Map<String, Object?>;
    final suiteRuns = manifest['runs']! as List<Object?>;
    expect(suiteRuns, hasLength(1));
    expect(
      suiteRuns.single as Map<String, Object?>,
      containsPair('scenario', 'narrow-batch-insert'),
    );
    expect(
      suiteRuns.single as Map<String, Object?>,
      containsPair('repetitions', 2),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('suite rejects app-jit for resqlite native-asset peer', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-suite-resqlite-appjit-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'tool/tracelite_dev.dart',
        'suite',
        '--profile=ci',
        '--interfaces=resqlite',
        '--scenarios=narrow-batch-insert',
        '--runner=app-jit',
        '--out-dir=${tempDir.path}',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 64);
    expect(
      result.stderr.toString(),
      contains('--runner=app-jit is not supported here'),
    );
    expect(result.stderr.toString(), contains('resqlite'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
