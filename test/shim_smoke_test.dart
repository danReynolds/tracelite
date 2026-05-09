// End-to-end test of the tracelite C shim against real `libsqlite3`,
// exercised by a real Dart program using `package:sqlite3`.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tracelite/tracelite.dart';

void main() {
  test('shim intercepts real sqlite3 calls from package:sqlite3', () async {
    final shim = File('build/libsqlite_traced.dylib');
    if (!shim.existsSync()) {
      fail('build/libsqlite_traced.dylib not built; run:\n'
          '  cc -dynamiclib -Inative native/tracelite_runtime.c '
          'native/shim_sqlite3.c -Wl,-reexport-lsqlite3 '
          '-o build/libsqlite_traced.dylib');
    }
    final resolverShim = File('libsqlite_traced.dylib');
    resolverShim.writeAsBytesSync(shim.readAsBytesSync());

    final regionPath =
        '${Directory.systemTemp.path}/tracelite-shim-$pid.tlt-region';
    addTearDown(() {
      try {
        File(regionPath).deleteSync();
      } catch (_) {}
    });

    TraceRegion.createFile(regionPath);

    final result = await Process.run(
      'dart',
      ['run', 'example/sqlite3_user.dart'],
      environment: {
        'TRACELITE_REGION': regionPath,
        'DYLD_LIBRARY_PATH': shim.parent.absolute.path,
        'LD_LIBRARY_PATH': shim.parent.absolute.path,
      },
    );

    expect(result.exitCode, 0,
        reason: 'sqlite3_user exited non-zero. stderr:\n${result.stderr}\n'
            'stdout:\n${result.stdout}');
    expect(result.stdout.toString(), contains('bob'),
        reason: 'sqlite3_user should print query results');

    final trace = Trace.loadRegion(regionPath);
    final registered = trace.tracks.where((track) => track.state >= 2).toList();
    expect(registered.length, greaterThanOrEqualTo(1),
        reason: 'shim should register as a producer');

    final spanCounts = <int, int>{};
    for (final event in trace.events) {
      spanCounts[event.spanId] = (spanCounts[event.spanId] ?? 0) + 1;
    }

    print(
        '  ${trace.events.length} total events from package:sqlite3 workload');
    print('  Span breakdown:');
    final sortedEntries = spanCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final entry in sortedEntries) {
      print('    ${kSpanNames[entry.key] ?? hexSpanId(entry.key)}'
          ': ${entry.value} (x2 = begin+end)');
    }

    final beginCount = trace.events.where((event) => event.isBegin).length;
    final endCount = trace.events.where((event) => event.isEnd).length;
    expect(beginCount, endCount,
        reason: 'every BEGIN should be matched by an END');
    expect(trace.diagnostics.unmatchedBeginEvents, 0);
    expect(trace.diagnostics.unmatchedEndEvents, 0);

    expect(
        spanCounts[BuiltinSpans.sqlite3PrepareV2] != null ||
            spanCounts[BuiltinSpans.sqlite3PrepareV3] != null,
        isTrue,
        reason: 'the workload must trigger prepare_v2 or prepare_v3');
    expect(spanCounts[BuiltinSpans.sqlite3Step], greaterThan(0),
        reason: 'the workload must execute at least one step');
    expect(spanCounts[BuiltinSpans.sqlite3Finalize], greaterThan(0),
        reason: 'the workload must finalize prepared statements');

    final bindCount = (spanCounts[BuiltinSpans.sqlite3BindText] ?? 0) +
        (spanCounts[BuiltinSpans.sqlite3BindInt64] ?? 0);
    expect(bindCount, greaterThan(0),
        reason: 'INSERTs / SELECT use parameter binding');

    final stringPool = trace.strings.values.join('\n');
    expect(
      stringPool.contains('CREATE TABLE') ||
          stringPool.contains('INSERT INTO') ||
          stringPool.contains('SELECT'),
      isTrue,
      reason: 'SQL text should have been interned',
    );

    final report = trace.toMarkdownReport();
    expect(report, contains('sqlite3_step'));
    expect(report, contains('tracelite report'));

    print('  ${trace.spans.length} spans paired by Trace.loadRegion');
    print('  shim intercepts real sqlite3 calls successfully');
  });
}
