import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('compare validates sqlite3, drift, sqlite_async, and resqlite traces',
      () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'compare',
        '--scenario=narrow-batch-insert',
        '--interfaces=sqlite3,drift,sqlite_async,resqlite',
        '--rows=5',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'compare exited non-zero.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );

    final output = result.stdout as String;
    for (final peer in ['sqlite3', 'drift', 'sqlite_async', 'resqlite']) {
      final line = output
          .split('\n')
          .firstWhere((line) => line.startsWith('| `$peer` |'));
      expect(
        line,
        contains('| `$peer` | ok |'),
        reason: '$peer should complete and emit trace events.\n$output',
      );
      expect(
        line,
        contains('| 0/0/0 |'),
        reason: '$peer should complete without trace diagnostics.\n$output',
      );
    }
    expect(output, isNot(contains('no trace')));
    expect(output, isNot(contains('Trace gaps')));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
