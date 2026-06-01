import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('published dependencies stay core-only', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    final dependencies = (pubspec['dependencies'] as YamlMap)
        .keys
        .cast<Object?>()
        .map((key) => key.toString())
        .toSet();

    expect(dependencies, containsAll(<String>['ffi', 'yaml']));
    expect(
      dependencies,
      isNot(contains(anyOf('drift', 'sqlite3', 'sqlite_async', 'resqlite'))),
      reason:
          'Peer adapters belong to the source-checkout benchmark CLI until the '
          'companion CLI package split lands. The recorder package must stay '
          'safe for peer libraries to depend on.',
    );
  });

  test('publish archive excludes source-checkout peer adapters', () {
    final pubignoreLines = File('.pubignore')
        .readAsLinesSync()
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toSet();

    expect(pubignoreLines, contains('tool/src/'));
    expect(pubignoreLines, contains('tool/tracelite_dev.dart'));
    expect(pubignoreLines, contains('tool/visualizer_check.dart'));
  });

  test('published launcher keeps core commands available', () async {
    final binSource = File('bin/tracelite.dart').readAsStringSync();
    final coreCliSource = File('lib/src/core_cli.dart').readAsStringSync();
    final diffSource = File('lib/src/diff.dart').readAsStringSync();
    for (final source in [binSource, coreCliSource, diffSource]) {
      expect(source, isNot(contains("package:drift/")));
      expect(source, isNot(contains("package:sqlite3/")));
      expect(source, isNot(contains("package:sqlite_async/")));
      expect(source, isNot(contains("package:resqlite/")));
    }
    expect(
      binSource.split('\n').length,
      lessThan(150),
      reason: 'The published launcher should stay a thin boundary wrapper. '
          'Core artifact commands live in lib/src/core_cli.dart.',
    );

    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-core-cli-boundary-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final regionPath = '${tempDir.path}/core.tlt-region';
    final create = await _runCoreCli([
      'create-region',
      '--out=$regionPath',
      '--ring-data-words=1024',
    ]);
    expect(
      create.exitCode,
      0,
      reason: 'create-region failed.\nstdout:\n${create.stdout}\n'
          'stderr:\n${create.stderr}',
    );
    expect(File(regionPath).existsSync(), isTrue);

    final report = await _runCoreCli(['report', regionPath]);
    expect(
      report.exitCode,
      0,
      reason: 'report failed.\nstdout:\n${report.stdout}\n'
          'stderr:\n${report.stderr}',
    );
    expect(report.stdout.toString(), contains('# tracelite report'));

    final baselinePath = '${tempDir.path}/baseline.json';
    final candidatePath = '${tempDir.path}/candidate.json';
    File(baselinePath).writeAsStringSync(
      jsonEncode(_compareArtifact([1000000, 1010000, 1020000])),
    );
    File(candidatePath).writeAsStringSync(
      jsonEncode(_compareArtifact([900000, 910000, 920000])),
    );

    final diff = await _runCoreCli([
      'diff',
      '--baseline=$baselinePath',
      '--candidate=$candidatePath',
      '--max-cv-percent=1000',
    ]);
    expect(
      diff.exitCode,
      0,
      reason: 'diff failed.\nstdout:\n${diff.stdout}\n'
          'stderr:\n${diff.stderr}',
    );
    expect(diff.stdout.toString(), contains('# tracelite diff'));
    expect(diff.stdout.toString(), contains('| `sqlite3` |'));

    final explain = await _runCoreCli(['explain', baselinePath]);
    expect(
      explain.exitCode,
      0,
      reason: 'explain failed.\nstdout:\n${explain.stdout}\n'
          'stderr:\n${explain.stderr}',
    );
    expect(explain.stdout.toString(), contains('# tracelite insights'));
  });

  test('peer commands stay out of the published core launcher', () async {
    final result = await _runCoreCli([
      'compare',
      '--scenario=narrow-batch-insert',
      '--interfaces=sqlite3',
      '--rows=1',
    ]);
    expect(result.exitCode, 64);
    expect(
      result.stderr.toString(),
      contains('requires a tracelite source checkout'),
    );
  });
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

Future<ProcessResult> _runCoreCli(List<String> args) {
  return Process.run(
    Platform.resolvedExecutable,
    ['bin/tracelite.dart', ...args],
    workingDirectory: Directory.current.path,
    environment: {'TRACELITE_FORCE_CORE_CLI': 'true'},
  );
}
