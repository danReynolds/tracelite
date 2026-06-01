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
    expect(result.stderr.toString(), contains('--build=none|host'));
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
}
