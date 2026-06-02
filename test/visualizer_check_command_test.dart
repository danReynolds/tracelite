import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('visualizer check help does not require Flutter', () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      ['tool/visualizer_check.dart', '--help'],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 0);
    expect(result.stderr.toString(), contains('visualizer-check'));
    expect(
        result.stderr.toString(), contains('dart tool/visualizer_check.dart'));
    expect(result.stderr.toString(), contains('--build=none|host'));
    expect(result.stderr.toString(), contains('--package=none|host'));
    expect(result.stderr.toString(),
        contains('--out-dir=build/visualizer-release'));
    expect(result.stderr.toString(), contains('--require-clean-source=true'));
    expect(result.stderr.toString(),
        contains('--skip-heavy-visualizer-tests=true'));
    expect(result.stderr.toString(),
        contains('--skip-native-visualizer-tests=true'));
    expect(result.stderr.toString(), contains('root peer native assets'));
  });

  test('visualizer check reports missing Flutter with an action', () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'tool/visualizer_check.dart',
        '--flutter=/definitely/missing/flutter',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 66);
    expect(result.stderr.toString(), contains('Install Flutter'));
    expect(result.stderr.toString(), contains('--flutter=/path/to/flutter'));
  });

  test('visualizer check uses the Windows Flutter batch launcher', () {
    final tool = File('tool/visualizer_check.dart').readAsStringSync();

    expect(tool, contains("Platform.isWindows ? 'flutter.bat' : 'flutter'"));
    expect(tool, contains("fileName == 'flutter.bat'"));
    expect(tool, contains('runInShell: _requiresShellExecutable(executable)'));
    expect(tool, contains("normalized.endsWith('.cmd')"));
  });

  test('visualizer check resolves package archives from checkout root', () {
    final tool = File('tool/visualizer_check.dart').readAsStringSync();

    expect(tool, contains('_resolveOutDir(root.path, options.outDir)'));
    expect(tool, contains("_joinPath(root, 'build/visualizer-release')"));
    expect(tool, contains('archive.absolute.path'));
  });

  test('visualizer check records non-macOS signing as external', () {
    final tool = File('tool/visualizer_check.dart').readAsStringSync();

    expect(tool, contains("device == 'macos' ? 'unsigned' : 'external'"));
    expect(tool, contains("device == 'macos' ? 'not_requested' :"));
    expect(tool, contains("'not_applicable'"));
  });

  test('visualizer check rejects invalid package mode before Flutter',
      () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      ['tool/visualizer_check.dart', '--package=zip'],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 64);
    expect(result.stderr.toString(), contains('--package must be'));
  });

  test('visualizer check requires signing before notarization', () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'tool/visualizer_check.dart',
        '--package=host',
        '--macos-notary-profile=tracelite-notary',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 64);
    expect(
      result.stderr.toString(),
      contains('--macos-notary-profile requires --macos-sign-identity'),
    );
  });

  test('visualizer check rejects invalid clean-source value', () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'tool/visualizer_check.dart',
        '--require-clean-source=maybe',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 64);
    expect(
      result.stderr.toString(),
      contains('--require-clean-source must be true or false'),
    );
  });

  test('visualizer check rejects invalid heavy-test skip value', () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'tool/visualizer_check.dart',
        '--skip-heavy-visualizer-tests=maybe',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 64);
    expect(
      result.stderr.toString(),
      contains('--skip-heavy-visualizer-tests must be true or false'),
    );
  });

  test('visualizer check rejects invalid native-test skip value', () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'tool/visualizer_check.dart',
        '--skip-native-visualizer-tests=maybe',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 64);
    expect(
      result.stderr.toString(),
      contains('--skip-native-visualizer-tests must be true or false'),
    );
  });
}
