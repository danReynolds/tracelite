// End-to-end test of the tracelite C shim against real `libsqlite3`,
// exercised by a real Dart program using `package:sqlite3`.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tracelite/src/native_artifacts.dart' as native_artifacts;
import 'package:tracelite/tracelite.dart';

void main() {
  test('shim intercepts real sqlite3 calls from package:sqlite3', () async {
    final shimBuildCommand = _sqliteShimBuildCommand();
    if (shimBuildCommand == null) {
      markTestSkipped(
        'sqlite shim smoke is not implemented for '
        '${Platform.operatingSystem}',
      );
      return;
    }

    final shim = File(native_artifacts.sqliteShimLibraryPath());
    if (!shim.existsSync()) {
      fail('${shim.path} not built; run:\n$shimBuildCommand');
    }
    final resolverShim = File(native_artifacts.sqliteShimLibraryName());
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
      Platform.resolvedExecutable,
      ['run', 'example/sqlite3_user.dart'],
      environment: _sqliteUserEnvironment(
        regionPath: regionPath,
        shimDirectory: shim.parent,
      ),
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
    expect(
      registered.map((track) => track.processName),
      contains('libsqlite_traced'),
      reason:
          'standalone sqlite_traced shim should keep a stable producer name',
    );

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
    expect(stringPool, contains('sqlfp:v1:'));
    expect(stringPool, contains('INSERT INTO T VALUES (?, ?)'));
    expect(stringPool, isNot(contains('alice')));
    expect(stringPool, isNot(contains('bob')));
    expect(stringPool, isNot(contains('carol')));
    expect(stringPool, isNot(contains('literal_secret')));

    final report = trace.toMarkdownReport();
    expect(report, contains('sqlite3_step'));
    expect(report, contains('tracelite report'));
    expect(report, contains('SQL Fingerprints'));
    expect(report, contains('INSERT INTO T VALUES (?, ?)'));

    print('  ${trace.spans.length} spans paired by Trace.loadRegion');
    print('  shim intercepts real sqlite3 calls successfully');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('raw SQL capture requires an explicit opt-in', () async {
    final shimBuildCommand = _sqliteShimBuildCommand();
    if (shimBuildCommand == null) {
      markTestSkipped(
        'sqlite shim smoke is not implemented for '
        '${Platform.operatingSystem}',
      );
      return;
    }

    final shim = File(native_artifacts.sqliteShimLibraryPath());
    if (!shim.existsSync()) {
      fail('${shim.path} not built; run:\n$shimBuildCommand');
    }
    final resolverShim = File(native_artifacts.sqliteShimLibraryName());
    resolverShim.writeAsBytesSync(shim.readAsBytesSync());

    final regionPath =
        '${Directory.systemTemp.path}/tracelite-shim-raw-$pid.tlt-region';
    addTearDown(() {
      try {
        File(regionPath).deleteSync();
      } catch (_) {}
    });

    TraceRegion.createFile(regionPath);

    final result = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'example/sqlite3_user.dart'],
      environment: _sqliteUserEnvironment(
        regionPath: regionPath,
        shimDirectory: shim.parent,
        sqlCapture: 'raw',
      ),
    );

    expect(result.exitCode, 0,
        reason: 'sqlite3_user exited non-zero. stderr:\n${result.stderr}\n'
            'stdout:\n${result.stdout}');

    final trace = Trace.loadRegion(regionPath);
    final stringPool = trace.strings.values.join('\n');
    expect(stringPool, contains("SELECT 'literal_secret' AS hidden"));
    expect(stringPool, contains('INSERT INTO t VALUES (?, ?)'));
    expect(stringPool, contains('SELECT id, name FROM t WHERE id > ?'));
    expect(stringPool, isNot(contains('sqlfp:v1:')));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

String? _sqliteShimBuildCommand() {
  final sqliteAmalgamation =
      Platform.environment['TRACELITE_SQLITE_AMALGAMATION'];
  return native_artifacts.sqliteShimBuildCommand(
    embeddedSqliteSourcePath:
        sqliteAmalgamation == null || sqliteAmalgamation.isEmpty
            ? null
            : sqliteAmalgamation,
  );
}

Map<String, String> _sqliteUserEnvironment({
  required String regionPath,
  required Directory shimDirectory,
  String? sqlCapture,
}) {
  final shimPath = shimDirectory.absolute.path;
  final inheritedPath =
      Platform.environment['PATH'] ?? Platform.environment['Path'] ?? '';
  return {
    'TRACELITE_REGION': regionPath,
    if (sqlCapture != null) 'TRACELITE_SQL_CAPTURE': sqlCapture,
    'DYLD_LIBRARY_PATH': shimPath,
    'LD_LIBRARY_PATH': shimPath,
    'PATH': inheritedPath.isEmpty
        ? shimPath
        : '$shimPath${Platform.pathSeparator}$inheritedPath',
  };
}
