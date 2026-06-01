import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  final allowDirty = args.contains('--allow-dirty');
  final root = await _gitRoot();
  final dirty = await _gitStatus(root);
  if (dirty.isNotEmpty && !allowDirty) {
    stderr.writeln('Tracked files are dirty; commit or pass --allow-dirty.');
    stderr.writeln(dirty);
    exitCode = 65;
    return;
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
    exitCode = result;
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
    const ['status', '--porcelain', '--untracked-files=no'],
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

Future<int> _runStreaming(
  String executable,
  List<String> args, {
  required String workingDirectory,
}) async {
  final process = await Process.start(
    executable,
    args,
    workingDirectory: workingDirectory,
  );
  await Future.wait([
    stdout.addStream(process.stdout),
    stderr.addStream(process.stderr),
  ]);
  return process.exitCode;
}

String _join(String parent, String child) {
  if (child.isEmpty) return parent;
  return parent.endsWith(Platform.pathSeparator)
      ? '$parent$child'
      : '$parent${Platform.pathSeparator}$child';
}
