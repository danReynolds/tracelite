import 'dart:io';

import 'package:test/test.dart';

void main() {
  for (final scenario in [
    'feed-paging',
    'sync-burst',
    'chat-sim',
    'large-working-set',
  ]) {
    test('compare validates $scenario on all peers', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          'run',
          'bin/tracelite.dart',
          'compare',
          '--scenario=$scenario',
          '--interfaces=sqlite3,drift,sqlite_async,resqlite',
          '--rows=8',
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
          reason: '$peer should complete $scenario and emit trace events.\n'
              '$output',
        );
        expect(
          line,
          contains('| 0/0/0 |'),
          reason: '$peer should complete $scenario without trace diagnostics.\n'
              '$output',
        );
      }
      expect(output, isNot(contains('no trace')));
      expect(output, isNot(contains('Trace gaps')));
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
