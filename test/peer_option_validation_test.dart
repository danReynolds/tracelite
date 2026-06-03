import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('compare rejects invalid interface lists before runner setup', () async {
    final cases = [
      (
        argument: '--interfaces=sqlite3,typo',
        message: 'contains unknown peer "typo"',
      ),
      (
        argument: '--interfaces=,',
        message: 'must include at least one peer',
      ),
      (
        argument: '--interfaces=sqlite3,sqlite3',
        message: 'contains duplicate peer "sqlite3"',
      ),
    ];

    for (final testCase in cases) {
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          'tool/tracelite_dev.dart',
          'compare',
          '--scenario=narrow-batch-insert',
          testCase.argument,
          '--rows=1',
        ],
        workingDirectory: Directory.current.path,
      );

      expect(
        result.exitCode,
        64,
        reason: 'unexpected result for ${testCase.argument}.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stderr.toString(), contains('--interfaces'));
      expect(result.stderr.toString(), contains(testCase.message));
      expect(result.stderr.toString(), contains('sqlite3, drift'));
      expect(result.stdout.toString(), isNot(contains('# tracelite compare')));
    }
  });

  test('peer runner rejects invalid direct peer before scenario setup',
      () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'tool/peer_runner.dart',
        'run',
        '--peer=typo',
        '--database=/tmp/tracelite-invalid-peer.db',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      64,
      reason: 'unexpected peer runner result.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    expect(result.stderr.toString(), contains('--peer'));
    expect(result.stderr.toString(), contains('contains unknown peer "typo"'));
  });
}
