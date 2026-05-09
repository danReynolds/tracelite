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
