import 'dart:io';

import 'package:test/test.dart';
import 'package:tracelite/resqlite.dart';
import 'package:tracelite/tracelite.dart';

void main() {
  test('resqlite vocabulary has stable unique IDs', () {
    final definitions = resqliteTraceVocabulary.definitions;
    expect(definitions, isNotEmpty);
    expect(
      definitions.map((definition) => definition.id).toSet(),
      hasLength(definitions.length),
    );
    expect(
      resqliteTraceVocabulary.spanNames[ResqliteTraceSpans.databaseSelect],
      'resqlite.database.select',
    );
    expect(
      resqliteTraceVocabulary.spanNames[ResqliteTraceSpans.profileWorkload],
      'resqlite.profile.workload',
    );
    expect(
      resqliteTraceVocabulary.spanNames[ResqliteTraceCounters.rowsDecoded],
      'resqlite.rows_decoded',
    );
    expect(
      resqliteTraceVocabulary
          .spanNames[ResqliteTraceGauges.sqlitePageCacheBytes],
      'resqlite.sqlite_page_cache_bytes',
    );
  });

  test('resqlite vocabulary registers names into a trace', () async {
    final runtime = await _ensureRuntimeLibrary();
    final regionPath =
        '${Directory.systemTemp.path}/tracelite-resqlite-vocabulary-$pid.tlt';
    addTearDown(() {
      try {
        File(regionPath).deleteSync();
      } catch (_) {}
    });

    TraceRegion.createFile(regionPath);
    final recorder = TraceRecorder.attach(
      regionPath: regionPath,
      runtimeLibraryPath: runtime.absolute.path,
      processName: 'resqlite_vocabulary_test',
      threadName: 'main',
    );
    expect(recorder.isActive, isTrue);

    recorder.registerVocabulary(resqliteTraceVocabulary);
    recorder.trace(ResqliteTraceSpans.databaseSelect, () {});
    recorder.counter(ResqliteTraceCounters.rowsDecoded, 3);
    recorder.gauge(ResqliteTraceGauges.sqlitePageCacheBytes, 4096);
    recorder.detach();

    final trace = Trace.loadRegion(regionPath);
    expect(
      trace.spanName(ResqliteTraceSpans.databaseSelect),
      'resqlite.database.select',
    );
    expect(
      trace.spanName(ResqliteTraceCounters.rowsDecoded),
      'resqlite.rows_decoded',
    );
    expect(
      trace.spanName(ResqliteTraceGauges.sqlitePageCacheBytes),
      'resqlite.sqlite_page_cache_bytes',
    );

    final report = trace.toMarkdownReport();
    expect(report, contains('resqlite.database.select'));
    expect(report, contains('resqlite.rows_decoded'));
    expect(report, contains('resqlite.sqlite_page_cache_bytes'));
  });

  test('resqlite workload spans render grouped report sections', () async {
    final runtime = await _ensureRuntimeLibrary();
    final regionPath =
        '${Directory.systemTemp.path}/tracelite-resqlite-workload-$pid.tlt';
    addTearDown(() {
      try {
        File(regionPath).deleteSync();
      } catch (_) {}
    });

    TraceRegion.createFile(regionPath);
    final recorder = TraceRecorder.attach(
      regionPath: regionPath,
      runtimeLibraryPath: runtime.absolute.path,
      processName: 'resqlite_workload_test',
      threadName: 'main',
    );
    expect(recorder.isActive, isTrue);

    recorder.registerVocabulary(resqliteTraceVocabulary);
    final workloadName = recorder.internString('point_query');
    await recorder.traceAsync<void>(
      ResqliteTraceSpans.profileWorkload,
      () async {
        recorder.trace(ResqliteTraceSpans.databaseSelect, () {});
        recorder.counter(
          ResqliteTraceCounters.rowsDecoded,
          10,
          correlationId: 7,
        );
      },
      beginArgs: [workloadName, 3],
      endArgs: [9],
      correlationId: 7,
    );
    recorder.detach();

    final trace = Trace.loadRegion(regionPath);
    expect(trace.workloads, hasLength(1));
    expect(trace.workloads.single.name, 'point_query');
    expect(trace.workloads.single.iterations, 3);
    expect(trace.workloads.single.sampleCount, 9);

    final report = trace.toMarkdownReport();
    expect(report, contains('## Workloads'));
    expect(report, contains('| `point_query` | 3 | 9 |'));
    expect(report, contains('### point_query'));
    expect(report, contains('resqlite.database.select'));
    expect(report, contains('resqlite.rows_decoded'));
  });

  test('resqlite metric helpers emit the migration parity counters', () async {
    final runtime = await _ensureRuntimeLibrary();
    final regionPath =
        '${Directory.systemTemp.path}/tracelite-resqlite-helpers-$pid.tlt';
    addTearDown(() {
      try {
        File(regionPath).deleteSync();
      } catch (_) {}
    });

    TraceRegion.createFile(regionPath);
    final session = TraceSession.attach(
      regionPath: regionPath,
      runtimeLibraryPath: runtime.absolute.path,
      processName: 'resqlite_helper_test',
      threadName: 'main',
    );
    expect(session.isActive, isTrue);

    recordResqliteDecodeMetrics(
      session,
      rowsDecoded: 3,
      cellsDecoded: 12,
      correlationId: 99,
    );
    recordResqliteStreamMetrics(
      session,
      invalidateUs: 17,
      invalidateCount: 2,
      intersectionUs: 9,
      intersectionEntries: 4,
      correlationId: 99,
    );
    recordResqliteDispatcherMetrics(
      session,
      parkedTotal: 5,
      wakeRetryTotal: 1,
      currentParked: 2,
      maxParkedConcurrent: 3,
      correlationId: 99,
    );
    recordResqliteDiagnostics(
      session,
      sqlitePageCacheBytes: 4096,
      sqliteSchemaBytes: 2048,
      sqliteStmtBytes: 1024,
      walBytes: 512,
      streamCount: 7,
      readerBusy: true,
      correlationId: 99,
    );
    session.detach();

    final trace = Trace.loadRegion(regionPath);
    final names = {
      for (final group in trace.counterEvents.groupCounterStatsByType(
        spanNames: trace.spanNames,
      ))
        group.spanName,
    };
    expect(names, contains('resqlite.rows_decoded'));
    expect(names, contains('resqlite.cells_decoded'));
    expect(names, contains('resqlite.invalidate_us'));
    expect(names, contains('resqlite.invalidate_count'));
    expect(names, contains('resqlite.intersection_us'));
    expect(names, contains('resqlite.intersection_entries'));
    expect(names, contains('resqlite.dispatcher_parked_total'));
    expect(names, contains('resqlite.dispatcher_wake_retry_total'));
    expect(names, contains('resqlite.dispatcher_current_parked'));
    expect(names, contains('resqlite.dispatcher_max_parked_concurrent'));
    expect(names, contains('resqlite.sqlite_page_cache_bytes'));
    expect(names, contains('resqlite.sqlite_schema_bytes'));
    expect(names, contains('resqlite.sqlite_stmt_bytes'));
    expect(names, contains('resqlite.wal_bytes'));
    expect(names, contains('resqlite.stream_count'));
    expect(names, contains('resqlite.reader_busy'));
    expect(
      trace.counterEvents.every((event) => event.correlationId == 99),
      isTrue,
    );
  });
}

Future<File> _ensureRuntimeLibrary() async {
  final extension = switch (Platform.operatingSystem) {
    'macos' => 'dylib',
    'windows' => 'dll',
    _ => 'so',
  };
  final file = File('build/libtracelite_runtime.$extension');
  if (file.existsSync()) return file;

  Directory('build').createSync(recursive: true);
  final args = switch (Platform.operatingSystem) {
    'macos' => [
        '-dynamiclib',
        '-O2',
        '-Inative',
        'native/tracelite_runtime.c',
        '-o',
        file.path,
      ],
    'windows' => [
        '-shared',
        '-O2',
        '-Inative',
        'native/tracelite_runtime.c',
        '-o',
        file.path,
      ],
    _ => [
        '-shared',
        '-fPIC',
        '-O2',
        '-Inative',
        'native/tracelite_runtime.c',
        '-o',
        file.path,
      ],
  };

  final result = await Process.run('cc', args);
  if (result.exitCode != 0) {
    fail('failed to build tracelite runtime library:\n'
        'stdout:\n${result.stdout}\n'
        'stderr:\n${result.stderr}');
  }
  return file;
}
