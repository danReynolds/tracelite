import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

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
    final runs = manifest['runs']! as List<Object?>;
    expect(runs, hasLength(4));
    for (final run in runs.cast<Map<String, Object?>>()) {
      expect(run['status'], 'ok');
      expect(File(run['artifact']! as String).existsSync(), isTrue);
      expect(File(run['log']! as String).existsSync(), isTrue);
    }
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
    final run = runs.single as Map<String, Object?>;
    expect(run['scenario'], 'narrow-batch-insert');
    expect(run['rows'], 100);
    expect(run['repetitions'], 5);
    expect(run['status'], 'ok');
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

    final history = jsonDecode(
      File('${tempDir.path}/history.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(history['schema'], 'tracelite.suite_history.v1');
    expect(history['profile'], 'ci');
    expect(history['requested_runs'], 2);
    expect(history['successful_runs'], 2);
    expect(history['calibration_status'], 'ready');
    final calibrationOptions =
        history['calibration_options']! as Map<String, Object?>;
    expect(calibrationOptions['peers'], ['sqlite3']);

    final runs = history['runs']! as List<Object?>;
    expect(runs, hasLength(2));
    for (final run in runs.cast<Map<String, Object?>>()) {
      expect(run['status'], 'ok');
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

  test('suite-history forwards --scenarios into each suite run', () async {
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
  }, timeout: const Timeout(Duration(minutes: 3)));
}
