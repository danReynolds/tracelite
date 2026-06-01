import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('operator docs name the current resqlite gate pin', () {
    final readme = File('README.md').readAsStringSync();
    final productionReadiness =
        File('doc/production-benchmark-readiness.md').readAsStringSync();
    const currentTag = 'resqlite-profiling-gate-2026-06-01';
    const currentRevision = '1fc321113c5a3a1598fc2908b52ed401eb65737c';

    for (final text in [readme, productionReadiness]) {
      expect(text, contains(currentTag));
      expect(text, contains(currentRevision));
      expect(text, isNot(contains('resqlite-profiling-gate-2026-05-31')));
      expect(
        text,
        isNot(contains('bcb3f3f419a09aa682948595fdb8ab002af637dc')),
      );
    }
  });

  test('suite-history help documents every supported profile', () {
    final plan = File('PLAN.md').readAsStringSync();
    final devCli = File('tool/tracelite_dev.dart').readAsStringSync();

    expect(
      plan,
      contains('suite-history --profile=ci|experiment|production'),
    );
    expect(
      devCli,
      contains('[--profile=ci|experiment|production] [--runs=5]'),
    );
  });
}
