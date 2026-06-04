import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('operator docs describe resqlite source-audited gate', () {
    final readme = File('README.md').readAsStringSync();
    final productionReadiness =
        File('doc/production-benchmark-readiness.md').readAsStringSync();
    final replacementChecklist =
        File('doc/resqlite-replacement-checklist.md').readAsStringSync();
    final soleProfilingGate =
        File('doc/resqlite-sole-profiling-gate.md').readAsStringSync();

    for (final text in [
      readme,
      productionReadiness,
      replacementChecklist,
      soleProfilingGate,
    ]) {
      expect(text, contains('source'));
      expect(text, contains('Tracelite'));
      expect(text, contains('resqlite'));
      expect(text, isNot(contains('resqlite-profiling-gate-2026-05-31')));
      expect(text, isNot(contains('resqlite-profiling-gate-2026-06-01-r2')));
      expect(text, isNot(contains('resqlite-profiling-gate-2026-06-01`')));
      expect(text, isNot(contains('resqlite-profiling-gate-2026-06-02-r10')));
      expect(text, isNot(contains('94529ec00dfb74d4c0093ce52d6d510964761067')));
      expect(
        text,
        isNot(contains('bcb3f3f419a09aa682948595fdb8ab002af637dc')),
      );
      expect(
        text,
        isNot(contains('1fc321113c5a3a1598fc2908b52ed401eb65737c')),
      );
      expect(
        text,
        isNot(contains('06c00ac126b54027c14c96deb5634e5a38104973')),
      );
      expect(
        text,
        isNot(contains('98f08c4a1d5e8d877c6b1ef3c11697b42d846d41')),
      );
      expect(text, isNot(contains('resqlite-profiling-gate-2026-06-02-r8')));
      expect(
        text,
        isNot(contains('4b4165693c752c8e73da3237c117fa5699c0bb79')),
      );
      expect(
        text,
        isNot(contains('a2e684c6861980e2fbbbc437dd7a4797ae984f2f')),
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
    expect(devCli, contains('[--runner=auto|script|app-jit|worker]'));
  });

  test('visualizer release docs include package and source gate options', () {
    final readme = File('README.md').readAsStringSync();
    final visualizerReadme =
        File('tool/visualizer_app/README.md').readAsStringSync();
    final visualizerDesign =
        File('doc/visualizer-product-design.md').readAsStringSync();
    final doctor = File('doc/doctor.md').readAsStringSync();
    final devCli = File('tool/tracelite_dev.dart').readAsStringSync();

    for (final text in [readme, visualizerReadme]) {
      expect(text, contains('--package=host'));
      expect(text, contains('--require-clean-source=true'));
      expect(text, contains('Visualizer Release'));
      expect(text, contains('heavyweight'));
      expect(text, contains('dense-trace'));
    }
    for (final text in [readme, visualizerReadme, visualizerDesign]) {
      expect(text, contains('Decision Review'));
      expect(text, contains('decision'));
    }
    expect(doctor, contains('Visualizer Release'));
    expect(doctor, contains('--package=host --require-clean-source=true'));
    expect(doctor, contains('--visualizer-release=build/visualizer-release'));
    expect(doctor, contains('--require-signed-macos-release=true'));
    expect(doctor, contains('--sqlite-amalgamation=third_party/sqlite3.c'));
    expect(doctor, contains('tool/build_sqlite_shim.dart'));
    expect(doctor, contains('heavyweight dense-trace'));
    expect(devCli, contains('--package=none|host'));
    expect(devCli, contains('--require-clean-source=true'));
    expect(devCli, contains('--visualizer-release=manifest-or-dir'));
    expect(devCli, contains('--sqlite-amalgamation=/path/to/sqlite3.c'));
    expect(devCli, contains('--require-signed-macos-release=true'));
    expect(devCli, contains('--skip-heavy-visualizer-tests=true'));
    expect(devCli, contains('--skip-native-visualizer-tests=true'));
  });

  test('docs and CI reflect peer suite and platform smoke coverage', () {
    final workflow = File('.github/workflows/ci.yml').readAsStringSync();
    final readme = File('README.md').readAsStringSync();
    final doctor = File('doc/doctor.md').readAsStringSync();
    final plan = File('PLAN.md').readAsStringSync();
    final productionReadiness =
        File('doc/production-benchmark-readiness.md').readAsStringSync();

    expect(workflow, contains('Linux CI benchmark suite'));
    expect(workflow, contains('RESQLITE_TRACE_REVISION'));
    expect(workflow, contains('SQLITE_AMALGAMATION_VERSION'));
    expect(workflow, contains('Windows SQLite shim smoke'));
    expect(workflow, contains('tool/build_sqlite_shim.dart'));
    expect(workflow, contains('tool/sqlite_shim_smoke.dart'));
    expect(
        workflow, isNot(contains('a2e684c6861980e2fbbbc437dd7a4797ae984f2f')));
    expect(workflow, contains('Publish archive smoke'));
    expect(workflow, contains('tool/publish_check.dart'));
    expect(workflow, contains('--out-dir=build/tracelite-linux-ci-suite'));
    expect(workflow, contains('tool/native_runtime_smoke.dart'));
    for (final text in [readme, plan, productionReadiness]) {
      expect(text, contains('four-peer `ci` suite'));
    }
    for (final text in [readme, doctor, productionReadiness]) {
      expect(text, contains('full `sqlite3` ABI'));
      expect(text, contains('sqlite_traced.dll'));
      expect(text, contains('SQLite amalgamation'));
    }
  });

  test('docs do not contain conversational drafting leftovers', () {
    final docs = Directory('doc')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.md'));

    for (final doc in docs) {
      final text = doc.readAsStringSync();
      expect(text, isNot(contains('Want me to')));
    }
  });
}
