import 'dart:async';
import 'dart:io';

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
    exitCode = result.exitCode;
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

List<String> _forbiddenArchiveEntries(String stdoutText) {
  return [
    if (stdoutText.contains('tracelite_dev.dart')) 'tool/tracelite_dev.dart',
    if (stdoutText.contains('peer.dart')) 'tool/src/peer.dart',
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
  await Future.wait([
    _tee(process.stdout, stdout, stdoutBuffer),
    _tee(process.stderr, stderr),
  ]);
  return _RunResult(
    exitCode: await process.exitCode,
    stdout: stdoutBuffer.toString(),
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
  });

  final int exitCode;
  final String stdout;
}
