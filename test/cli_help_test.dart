import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('top-level help is an explicit successful command', () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/tracelite.dart', 'help'],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'help failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    expect(result.stderr.toString(), contains('dart run bin/tracelite.dart'));
    expect(result.stderr.toString(), contains('visualizer-check'));
  });

  test('source-checkout subcommand help exits before command validation',
      () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/tracelite.dart', 'doctor', '--help'],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'doctor --help failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    expect(result.stderr.toString(), contains('doctor'));
    expect(result.stdout.toString(), isNot(contains('# tracelite doctor')));
  });

  test('forced core subcommand help exits before artifact loading', () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/tracelite.dart', 'report', '--help'],
      workingDirectory: Directory.current.path,
      environment: {
        ...Platform.environment,
        'TRACELITE_FORCE_CORE_CLI': 'true',
      },
    );

    expect(
      result.exitCode,
      0,
      reason: 'core report --help failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    expect(result.stderr.toString(), contains('report <region>'));
    expect(result.stderr.toString(), isNot(contains('No such file')));
  });
}
