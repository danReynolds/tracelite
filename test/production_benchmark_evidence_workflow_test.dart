import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('production benchmark evidence workflow records macOS and Linux history',
      () {
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
    expect(workflow, isNot(contains('os: windows-2025')));
    expect(workflow, contains('tool/verify_resqlite_source.dart'));
    expect(workflow, contains('tool/native_runtime_smoke.dart'));
    expect(workflow, contains('tool/build_sqlite_shim.dart'));
    expect(workflow, contains('tool/sqlite_shim_smoke.dart'));
    expect(workflow, contains('suite-history'));
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
}
