import 'dart:io';

import 'package:test/test.dart';
import 'package:tracelite/tracelite.dart';

const _workloadSpan = 0x7000;
const _sampleSpan = 0x7001;
const _selectSpan = 0x7002;
const _rssBefore = 0x7010;
const _rssAfter = 0x7011;
const _rssPeak = 0x7012;
const _sqlitePageCache = 0x7020;
const _rowsDecoded = 0x7030;
const _cellsDecoded = 0x7031;
const _fanoutTotal = 0x7040;

const _genericSqliteVocabulary = TraceVocabulary(
  name: 'other_sqlite',
  definitions: [
    TraceDefinition(
      id: _workloadSpan,
      name: 'other_sqlite.profile.workload',
      category: 'other_sqlite',
      kind: TraceDefinitionKind.span,
    ),
    TraceDefinition(
      id: _sampleSpan,
      name: 'other_sqlite.profile.sample',
      category: 'other_sqlite',
      kind: TraceDefinitionKind.span,
    ),
    TraceDefinition(
      id: _selectSpan,
      name: 'other_sqlite.database.select',
      category: 'other_sqlite',
      kind: TraceDefinitionKind.span,
    ),
    TraceDefinition(
      id: _rssBefore,
      name: 'other_sqlite.rss_before_bytes',
      category: 'other_sqlite.gauge',
      kind: TraceDefinitionKind.gauge,
    ),
    TraceDefinition(
      id: _rssAfter,
      name: 'other_sqlite.rss_after_bytes',
      category: 'other_sqlite.gauge',
      kind: TraceDefinitionKind.gauge,
    ),
    TraceDefinition(
      id: _rssPeak,
      name: 'other_sqlite.rss_peak_bytes',
      category: 'other_sqlite.gauge',
      kind: TraceDefinitionKind.gauge,
    ),
    TraceDefinition(
      id: _sqlitePageCache,
      name: 'other_sqlite.sqlite_page_cache_bytes',
      category: 'other_sqlite.gauge',
      kind: TraceDefinitionKind.gauge,
    ),
    TraceDefinition(
      id: _rowsDecoded,
      name: 'other_sqlite.profile.rows_decoded',
      category: 'other_sqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: _cellsDecoded,
      name: 'other_sqlite.profile.cells_decoded',
      category: 'other_sqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: _fanoutTotal,
      name: 'other_sqlite.fanout.total_us',
      category: 'other_sqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
  ],
);

void main() {
  test('workload summary consumes semantic suffixes without resqlite prefix',
      () async {
    final runtime = await _ensureRuntimeLibrary();
    final regionPath =
        '${Directory.systemTemp.path}/tracelite-generic-summary-$pid.tlt';
    addTearDown(() {
      try {
        File(regionPath).deleteSync();
      } catch (_) {}
    });

    TraceRegion.createFile(regionPath);
    final recorder = TraceRecorder.attach(
      regionPath: regionPath,
      runtimeLibraryPath: runtime.absolute.path,
      processName: 'profile_summary_test',
      threadName: 'main',
    );
    expect(recorder.isActive, isTrue);
    recorder.registerVocabulary(_genericSqliteVocabulary);

    await _recordWorkload(recorder, 'noop', totalUs: 12, correlationId: 1);
    await _recordWorkload(recorder, 'point_query',
        totalUs: 13, correlationId: 2);
    recorder.detach();

    final artifact = traceWorkloadSummaryArtifact(Trace.loadRegion(regionPath));
    final workloads = artifact['workloads'] as Map<String, Object?>;
    final pointQuery = workloads['point_query'] as Map<String, Object?>;
    final summary = pointQuery['summary'] as Map<String, Object?>;
    final select = summary['select'] as Map<String, Object?>;
    expect(select['dispatch_floor_us'], 12);
    expect(select['work_us_median'], 1);

    final memory = pointQuery['memory'] as Map<String, Object?>;
    expect(memory['rss_delta_mb'], 1.0);
    expect(
      memory['diagnostics_delta'],
      containsPair('sqlite_page_cache_bytes_delta', 8),
    );
    expect(memory['allocation_delta'], {
      'rows_decoded': 7,
      'cells_decoded': 42,
    });

    final fanout = pointQuery['fanout_summary'] as Map<String, Object?>;
    final total = fanout['total_us'] as Map<String, Object?>;
    expect(total['median'], 30);
  });
}

Future<void> _recordWorkload(
  TraceRecorder recorder,
  String name, {
  required int totalUs,
  required int correlationId,
}) async {
  final nameId = recorder.internString(name);
  await recorder.traceAsync<void>(
    _workloadSpan,
    () async {
      final selectOpId = recorder.internString('select');
      final sqlId = recorder.internString('SELECT 1');
      recorder.counter(_rssBefore, 1024 * 1024, correlationId: correlationId);
      recorder.counter(_sqlitePageCache, 10, correlationId: correlationId);
      recorder.counter(_rowsDecoded, 0, correlationId: correlationId);
      recorder.counter(_cellsDecoded, 0, correlationId: correlationId);
      recorder.trace(
        _sampleSpan,
        () => recorder.trace(_selectSpan, () {}),
        beginArgs: [selectOpId, sqlId, 0],
        endArgs: [totalUs, 1],
        correlationId: correlationId,
      );
      recorder.counter(_rowsDecoded, 7, correlationId: correlationId);
      recorder.counter(_cellsDecoded, 42, correlationId: correlationId);
      recorder.counter(_fanoutTotal, 30, correlationId: correlationId);
      recorder.counter(_sqlitePageCache, 18, correlationId: correlationId);
      recorder.counter(_rssAfter, 2 * 1024 * 1024,
          correlationId: correlationId);
      recorder.counter(_rssPeak, 3 * 1024 * 1024, correlationId: correlationId);
    },
    beginArgs: [nameId, 1],
    endArgs: [1],
    correlationId: correlationId,
  );
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
