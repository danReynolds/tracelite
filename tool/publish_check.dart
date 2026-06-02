import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

Future<void> main(List<String> args) async {
  final allowDirty = args.contains('--allow-dirty');
  final root = await _gitRoot();
  final dirty = await _gitStatus(root);
  if (dirty.isNotEmpty && !allowDirty) {
    stderr.writeln('Working tree is dirty; commit or pass --allow-dirty.');
    stderr.writeln(dirty);
    exitCode = 65;
    return;
  } else if (dirty.isNotEmpty) {
    stderr.writeln(
      'Warning: --allow-dirty builds the archive from git-tracked paths; '
      'untracked files are omitted unless staged.',
    );
  }

  final temp = await Directory.systemTemp.createTemp('tracelite-publish-');
  try {
    await _copyTrackedFiles(root, temp.path);
    stdout.writeln('Checking clean archive in ${temp.path}');
    final result = await _runStreaming(
      Platform.resolvedExecutable,
      const ['pub', 'publish', '--dry-run'],
      workingDirectory: temp.path,
    );
    if (result.exitCode == 0) {
      final forbidden = _forbiddenArchiveEntries(result.stdout);
      if (forbidden.isNotEmpty) {
        stderr.writeln(
          'Publish archive contains source-checkout-only files: '
          '${forbidden.join(', ')}',
        );
        exitCode = 65;
        return;
      }
    }
    if (result.exitCode != 0) {
      exitCode = result.exitCode;
      return;
    }

    await _applyPubIgnore(temp.path);
    final smokeExitCode = await _runPublishedCoreSmoke(temp.path);
    exitCode = smokeExitCode;
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<String> _gitRoot() async {
  final result = await Process.run('git', const [
    'rev-parse',
    '--show-toplevel',
  ]);
  if (result.exitCode != 0) {
    stderr.writeln(result.stderr);
    exit(result.exitCode);
  }
  return (result.stdout as String).trim();
}

Future<String> _gitStatus(String root) async {
  final result = await Process.run(
    'git',
    const ['status', '--porcelain', '--untracked-files=all'],
    workingDirectory: root,
  );
  if (result.exitCode != 0) {
    stderr.writeln(result.stderr);
    exit(result.exitCode);
  }
  return (result.stdout as String).trim();
}

Future<void> _copyTrackedFiles(String root, String targetRoot) async {
  final result = await Process.run(
    'git',
    const ['ls-files', '-z'],
    workingDirectory: root,
  );
  if (result.exitCode != 0) {
    stderr.writeln(result.stderr);
    exit(result.exitCode);
  }
  final files = (result.stdout as String)
      .split('\u0000')
      .where((path) => path.isNotEmpty);
  for (final relativePath in files) {
    final source = File(_join(root, relativePath));
    if (!source.existsSync()) continue;
    final target = File(_join(targetRoot, relativePath));
    await target.parent.create(recursive: true);
    await source.copy(target.path);
  }
}

Future<void> _applyPubIgnore(String root) async {
  final pubignore = File(_join(root, '.pubignore'));
  if (!pubignore.existsSync()) return;
  final lines = pubignore
      .readAsLinesSync()
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('#'));
  for (final pattern in lines) {
    if (pattern.endsWith('/')) {
      await _deleteIfExists(
        _join(root, pattern.substring(0, pattern.length - 1)),
      );
    } else if (pattern.contains('*')) {
      await _deleteGlob(root, pattern);
    } else {
      await _deleteIfExists(_join(root, pattern));
    }
  }
}

Future<void> _deleteGlob(String root, String pattern) async {
  final slash = pattern.lastIndexOf('/');
  final directoryPath =
      slash < 0 ? root : _join(root, pattern.substring(0, slash));
  final glob = slash < 0 ? pattern : pattern.substring(slash + 1);
  final star = glob.indexOf('*');
  if (star < 0) {
    await _deleteIfExists(_join(root, pattern));
    return;
  }
  final prefix = glob.substring(0, star);
  final suffix = glob.substring(star + 1);
  final directory = Directory(directoryPath);
  if (!directory.existsSync()) return;
  await for (final entity in directory.list()) {
    final name = entity.uri.pathSegments.last;
    if (name.startsWith(prefix) && name.endsWith(suffix)) {
      await _deleteEntity(entity);
    }
  }
}

Future<void> _deleteIfExists(String path) async {
  final file = File(path);
  if (file.existsSync()) {
    await file.delete();
    return;
  }
  final directory = Directory(path);
  if (directory.existsSync()) {
    await directory.delete(recursive: true);
  }
}

Future<void> _deleteEntity(FileSystemEntity entity) async {
  if (entity is Directory) {
    await entity.delete(recursive: true);
  } else {
    await entity.delete();
  }
}

Future<int> _runPublishedCoreSmoke(String root) async {
  stdout.writeln('Running published core CLI smoke in archive-shaped tree');
  final get = await _runStreaming(
    Platform.resolvedExecutable,
    const ['pub', 'get'],
    workingDirectory: root,
  );
  if (!_expectExit(
    get,
    expectedExitCode: 0,
    label: 'dart pub get',
  )) {
    return 65;
  }

  final artifactDir = Directory(_join(root, 'build/publish-smoke'));
  await artifactDir.create(recursive: true);
  final regionPath = _join(artifactDir.path, 'core.tlt-region');
  final baselinePath = _join(artifactDir.path, 'baseline.json');
  final candidatePath = _join(artifactDir.path, 'candidate.json');
  File(baselinePath).writeAsStringSync(
    jsonEncode(_compareArtifact([1000000, 1010000, 1020000])),
  );
  File(candidatePath).writeAsStringSync(
    jsonEncode(_compareArtifact([900000, 910000, 920000])),
  );

  final checks = [
    _CoreSmokeCheck(
      label: 'help',
      args: const ['bin/tracelite.dart', 'help'],
      stdoutContains: 'tracelite',
    ),
    _CoreSmokeCheck(
      label: 'create-region',
      args: [
        'bin/tracelite.dart',
        'create-region',
        '--out=$regionPath',
        '--ring-data-words=1024',
      ],
      stdoutContains: 'Created tracelite region',
    ),
    _CoreSmokeCheck(
      label: 'report',
      args: ['bin/tracelite.dart', 'report', regionPath],
      stdoutContains: '# tracelite report',
    ),
    _CoreSmokeCheck(
      label: 'diff',
      args: [
        'bin/tracelite.dart',
        'diff',
        '--baseline=$baselinePath',
        '--candidate=$candidatePath',
        '--max-cv-percent=1000',
      ],
      stdoutContains: '# tracelite diff',
    ),
    _CoreSmokeCheck(
      label: 'explain',
      args: ['bin/tracelite.dart', 'explain', baselinePath],
      stdoutContains: '# tracelite insights',
    ),
    _CoreSmokeCheck(
      label: 'peer command boundary',
      args: const [
        'bin/tracelite.dart',
        'compare',
        '--scenario=narrow-batch-insert',
        '--interfaces=sqlite3',
      ],
      expectedExitCode: 64,
      stderrContains: 'requires a tracelite source checkout',
    ),
  ];

  for (final check in checks) {
    final result = await _runStreaming(
      Platform.resolvedExecutable,
      check.args,
      workingDirectory: root,
    );
    if (!_expectExit(
      result,
      expectedExitCode: check.expectedExitCode,
      label: check.label,
      stdoutContains: check.stdoutContains,
      stderrContains: check.stderrContains,
    )) {
      return 65;
    }
  }
  return 0;
}

bool _expectExit(
  _RunResult result, {
  required int expectedExitCode,
  required String label,
  String? stdoutContains,
  String? stderrContains,
}) {
  final stdoutOk =
      stdoutContains == null || result.stdout.contains(stdoutContains);
  final stderrOk =
      stderrContains == null || result.stderr.contains(stderrContains);
  if (result.exitCode == expectedExitCode && stdoutOk && stderrOk) {
    return true;
  }

  stderr.writeln('Publish archive core smoke failed: $label');
  stderr.writeln('expected exit: $expectedExitCode');
  stderr.writeln('actual exit: ${result.exitCode}');
  if (stdoutContains != null) {
    stderr.writeln('expected stdout to contain: $stdoutContains');
  }
  if (stderrContains != null) {
    stderr.writeln('expected stderr to contain: $stderrContains');
  }
  stderr.writeln('stdout:\n${result.stdout}');
  stderr.writeln('stderr:\n${result.stderr}');
  return false;
}

List<String> _forbiddenArchiveEntries(String stdoutText) {
  return [
    if (stdoutText.contains('dart_test.yaml')) 'dart_test.yaml',
    if (stdoutText.contains('runtime-protocol.feedback.md'))
      'doc/*.feedback.md',
    if (stdoutText.contains('test_producer.c')) 'native/test_producer.c',
    if (stdoutText.contains('package_boundary_test.dart')) 'test/',
    if (stdoutText.contains('tracelite_dev.dart')) 'tool/tracelite_dev.dart',
    if (stdoutText.contains('peer.dart')) 'tool/src/peer.dart',
    if (stdoutText.contains('native_runtime_smoke.dart'))
      'tool/native_runtime_smoke.dart',
    if (stdoutText.contains('platform_core_smoke.dart'))
      'tool/platform_core_smoke.dart',
    if (stdoutText.contains('publish_check.dart')) 'tool/publish_check.dart',
    if (stdoutText.contains('spans.yaml')) 'tool/spans.yaml',
  ];
}

Future<_RunResult> _runStreaming(
  String executable,
  List<String> args, {
  required String workingDirectory,
}) async {
  final process = await Process.start(
    executable,
    args,
    workingDirectory: workingDirectory,
  );
  final stdoutBuffer = StringBuffer();
  final stderrBuffer = StringBuffer();
  await Future.wait([
    _tee(process.stdout, stdout, stdoutBuffer),
    _tee(process.stderr, stderr, stderrBuffer),
  ]);
  return _RunResult(
    exitCode: await process.exitCode,
    stdout: stdoutBuffer.toString(),
    stderr: stderrBuffer.toString(),
  );
}

Future<void> _tee(
  Stream<List<int>> source,
  IOSink sink, [
  StringBuffer? buffer,
]) async {
  await for (final chunk in source) {
    sink.add(chunk);
    buffer?.write(String.fromCharCodes(chunk));
  }
}

String _join(String parent, String child) {
  if (child.isEmpty) return parent;
  return parent.endsWith(Platform.pathSeparator)
      ? '$parent$child'
      : '$parent${Platform.pathSeparator}$child';
}

final class _RunResult {
  const _RunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

final class _CoreSmokeCheck {
  const _CoreSmokeCheck({
    required this.label,
    required this.args,
    this.expectedExitCode = 0,
    this.stdoutContains,
    this.stderrContains,
  });

  final String label;
  final List<String> args;
  final int expectedExitCode;
  final String? stdoutContains;
  final String? stderrContains;
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
