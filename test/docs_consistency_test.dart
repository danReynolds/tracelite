import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('operator docs name the current resqlite gate pin', () {
    final readme = File('README.md').readAsStringSync();
    final productionReadiness =
        File('doc/production-benchmark-readiness.md').readAsStringSync();
    final replacementChecklist =
        File('doc/resqlite-replacement-checklist.md').readAsStringSync();
    final soleProfilingGate =
        File('doc/resqlite-sole-profiling-gate.md').readAsStringSync();
    const currentTag = 'resqlite-profiling-gate-2026-06-01-r2';
    const currentRevision = '06c00ac126b54027c14c96deb5634e5a38104973';
    const currentResqlitePrRevision =
        '98f08c4a1d5e8d877c6b1ef3c11697b42d846d41';

    for (final text in [
      readme,
      productionReadiness,
      replacementChecklist,
      soleProfilingGate,
    ]) {
      expect(text, contains(currentTag));
      expect(
        text,
        anyOf(
          contains(currentRevision),
          contains(currentResqlitePrRevision),
        ),
      );
      expect(text, isNot(contains('resqlite-profiling-gate-2026-05-31')));
      expect(text, isNot(contains('resqlite-profiling-gate-2026-06-01`')));
      expect(
        text,
        isNot(contains('bcb3f3f419a09aa682948595fdb8ab002af637dc')),
      );
      expect(
        text,
        isNot(contains('1fc321113c5a3a1598fc2908b52ed401eb65737c')),
      );
      expect(text, isNot(contains('should stay draft')));
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
    expect(devCli, contains('[--runner=auto|script|app-jit]'));
  });

  test('visualizer release docs include package and source gate options', () {
    final readme = File('README.md').readAsStringSync();
    final visualizerReadme =
        File('tool/visualizer_app/README.md').readAsStringSync();
    final devCli = File('tool/tracelite_dev.dart').readAsStringSync();

    for (final text in [readme, visualizerReadme]) {
      expect(text, contains('--package=host'));
      expect(text, contains('--require-clean-source=true'));
    }
    expect(devCli, contains('--package=none|host'));
    expect(devCli, contains('--require-clean-source=true'));
  });

  test('docs reflect Linux pinned peer suite coverage', () {
    final workflow = File('.github/workflows/ci.yml').readAsStringSync();
    final readme = File('README.md').readAsStringSync();
    final plan = File('PLAN.md').readAsStringSync();
    final productionReadiness =
        File('doc/production-benchmark-readiness.md').readAsStringSync();

    expect(workflow, contains('Linux CI benchmark suite'));
    expect(workflow, contains('--out-dir=build/tracelite-linux-ci-suite'));
    for (final text in [readme, plan, productionReadiness]) {
      expect(text, contains('pinned four-peer `ci` suite'));
    }
  });
}
