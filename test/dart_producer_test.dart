import 'dart:io';

import 'package:test/test.dart';
import 'package:tracelite/tracelite.dart';

void main() {
  test('Dart producer emits sync, async, counter, and metadata events',
      () async {
    final runtime = await _ensureRuntimeLibrary();

    final regionPath =
        '${Directory.systemTemp.path}/tracelite-dart-producer-$pid.tlt-region';
    addTearDown(() {
      try {
        File(regionPath).deleteSync();
      } catch (_) {}
    });

    TraceRegion.createFile(regionPath);

    final recorder = TraceRecorder.attach(
      regionPath: regionPath,
      runtimeLibraryPath: runtime.absolute.path,
      processName: 'dart_producer_test',
      threadName: 'main',
    );
    expect(recorder.isActive, isTrue);
    final otherRecorder = TraceRecorder.attach(
      regionPath: regionPath,
      runtimeLibraryPath: runtime.absolute.path,
      processName: 'dart_producer_test',
      threadName: 'other',
    );
    expect(otherRecorder.isActive, isTrue);

    recorder.registerSpan(
      userSpanIdStart + 10,
      'resqlite.database.select',
      category: 'resqlite',
    );
    recorder.registerSpan(
      userSpanIdStart + 2,
      'resqlite.rows_decoded',
      category: 'resqlite.counter',
    );

    final sqlId = recorder.internString('SELECT * FROM items WHERE id = ?');
    expect(sqlId, isNot(0xFFFFFFFF));

    final value = recorder.trace<int>(
      userSpanIdStart,
      () => 42,
      beginArgs: [sqlId, 1],
      endArgs: [1],
      correlationId: 11,
    );
    expect(value, 42);

    final asyncValue = await recorder.traceAsync<int>(
      userSpanIdStart + 1,
      () async => 7,
      beginArgs: [sqlId],
      endArgs: [0],
      correlationId: 12,
    );
    expect(asyncValue, 7);

    recorder.asyncBegin(userSpanIdStart + 10, correlationId: 21);
    otherRecorder.asyncEnd(userSpanIdStart + 10, correlationId: 21);

    recorder.counter(userSpanIdStart + 2, 3);
    recorder.counter(userSpanIdStart + 2, 5);
    recorder.gauge(userSpanIdStart + 3, 2, correlationId: 13);
    otherRecorder.detach();
    recorder.detach();

    final trace = Trace.loadRegion(regionPath);
    final tracks = trace.tracks.where((track) => track.state == 3).toList();
    expect(tracks, hasLength(2));
    final mainTrack = tracks.singleWhere((track) => track.threadName == 'main');
    final otherTrack =
        tracks.singleWhere((track) => track.threadName == 'other');
    expect(mainTrack.kind, traceTrackKindIsolate);
    expect(otherTrack.kind, traceTrackKindIsolate);
    expect(mainTrack.processName, 'dart_producer_test');

    expect(trace.strings.values, contains('SELECT * FROM items WHERE id = ?'));
    expect(trace.spanName(userSpanIdStart + 10), 'resqlite.database.select');
    expect(trace.spanName(userSpanIdStart + 2), 'resqlite.rows_decoded');
    expect(trace.events.where((event) => event.isBegin), hasLength(1));
    expect(trace.events.where((event) => event.isEnd), hasLength(1));
    expect(trace.events.where((event) => event.isAsyncBegin), hasLength(2));
    expect(trace.events.where((event) => event.isAsyncEnd), hasLength(2));
    expect(trace.counterEvents, hasLength(3));
    expect(trace.metadataEvents, hasLength(2));

    final syncSpan =
        trace.spans.singleWhere((span) => span.spanId == userSpanIdStart);
    expect(syncSpan.begin.correlationId, 11);
    expect(syncSpan.beginArgs, [sqlId, 1]);
    expect(syncSpan.endArgs, [1]);

    final asyncSpan =
        trace.spans.singleWhere((span) => span.spanId == userSpanIdStart + 1);
    expect(asyncSpan.isAsync, isTrue);
    expect(asyncSpan.begin.correlationId, 12);
    expect(asyncSpan.end?.correlationId, 12);

    final crossTrackAsyncSpan = trace.spans.singleWhere(
      (span) => span.spanId == userSpanIdStart + 10,
    );
    expect(crossTrackAsyncSpan.isAsync, isTrue);
    expect(crossTrackAsyncSpan.begin.trackId, mainTrack.id);
    expect(crossTrackAsyncSpan.end?.trackId, otherTrack.id);

    final counterStats =
        trace.counterEvents.ofCounterType(userSpanIdStart + 2).first;
    expect(counterStats.args.first, 3);
    final grouped = trace.counterEvents.groupCounterStatsByType();
    final counterGroup = grouped.singleWhere(
      (group) => group.spanId == userSpanIdStart + 2,
    );
    expect(counterGroup.stats.count, 2);
    expect(counterGroup.stats.latest, 5);
    expect(counterGroup.stats.min, 3);
    expect(counterGroup.stats.max, 5);

    final report = trace.toMarkdownReport();
    expect(report, contains('## Counters'));
    expect(report, contains('resqlite.database.select'));
    expect(report, contains('resqlite.rows_decoded'));
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
