import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('production benchmark evidence workflow records desktop history', () {
    final workflow = File(
      '.github/workflows/production-benchmark-evidence.yml',
    ).readAsStringSync();

    expect(workflow, contains('name: Production Benchmark Evidence'));
    expect(workflow, contains('workflow_dispatch:'));
    expect(workflow, contains('resqlite_revision:'));
    expect(workflow, contains('aabcce733240b8586216f8c32bcc1a16f806586f'));
    expect(workflow, contains('default: auto'));
    expect(workflow, contains('os: macos-14'));
    expect(workflow, contains('os: ubuntu-24.04'));
    expect(workflow, contains('os: windows-2025'));
    expect(workflow, contains('SQLITE_AMALGAMATION_VERSION'));
    expect(workflow, contains('Download Windows SQLite amalgamation'));
    expect(workflow, contains('Build Windows embedded SQLite shim'));
    expect(workflow, contains('TRACELITE_SQLITE_AMALGAMATION'));
    expect(workflow, contains('Prepare production evidence directory'));
    expect(workflow, contains('setup.txt'));
    expect(workflow, contains('cat > pubspec_overrides.yaml'));
    expect(workflow, contains('python_cmd=python3'));
    expect(workflow, contains('tool/verify_resqlite_source.dart'));
    expect(workflow, contains('tool/native_runtime_smoke.dart'));
    expect(workflow, contains('tool/build_sqlite_shim.dart'));
    expect(workflow, contains('tool/sqlite_shim_smoke.dart'));
    expect(workflow, contains('tool/generate.dart --check'));
    expect(workflow, contains('dart run bin/tracelite.dart suite-history'));
    expect(workflow, contains('--profile=production'));
    expect(
      workflow,
      contains('--interfaces=sqlite3,drift,sqlite_async,resqlite'),
    );
    expect(workflow, contains('--policy-peers=resqlite'));
    expect(workflow, contains('--metrics=measured_elapsed_ns'));
    expect(workflow, contains('--require-clean-source=true'));
    expect(workflow, contains('--strict=false'));
    expect(workflow, contains('export-graph-data'));
    expect(workflow, contains('validate-graph-data'));
    expect(
      workflow,
      isNot(contains('dart run bin/tracelite.dart export-graph-data')),
    );
    expect(
      workflow,
      isNot(contains('dart run bin/tracelite.dart validate-graph-data')),
    );
    expect(
      workflow,
      isNot(contains('dart run bin/tracelite.dart explain')),
    );
    expect(workflow, isNot(contains('dart run tool/generate.dart')));
    expect(workflow, contains(r'explain "$out_dir/history.json"'));
    expect(workflow, contains('if: always()'));
    expect(workflow, contains('actions/upload-artifact@v7.0.1'));
    expect(
      workflow,
      contains(r'tracelite-production-history-${{ matrix.label }}'),
    );
    expect(workflow, contains('Evaluate production evidence'));
    expect(workflow, contains('calibration_status'));
    expect(workflow, contains('successful_runs'));
  });

  test('source checkout peer suites can use the Windows embedded shim', () {
    final devCli = File('tool/tracelite_dev.dart').readAsStringSync();

    expect(devCli, contains('TRACELITE_SQLITE_AMALGAMATION'));
    expect(devCli, contains('embedded sqlite_traced.dll shim'));
    expect(
      devCli,
      contains('embeddedSqliteSourcePath: sqliteAmalgamation'),
    );
  });
}
