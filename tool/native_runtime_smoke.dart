import 'dart:io';

import 'package:tracelite/src/native_artifacts.dart' as native_artifacts;
import 'package:tracelite/tracelite.dart';

Future<void> main() async {
  final runtime = await _ensureRuntimeLibrary();

  await _recordTrace(runtime);
  await _recordSession(runtime);

  stdout.writeln(
    'tracelite native runtime smoke passed on ${Platform.operatingSystem}',
  );
}

Future<void> _recordTrace(File runtime) async {
  final regionPath =
      '${Directory.systemTemp.path}/tracelite-native-runtime-$pid.tlt-region';
  TraceRegion.createFile(regionPath);
  try {
    final recorder = TraceRecorder.attach(
      regionPath: regionPath,
      runtimeLibraryPath: runtime.absolute.path,
      processName: 'native_runtime_smoke',
      threadName: 'main',
    );
    _expect(recorder.isActive, 'main recorder did not attach');

    final otherRecorder = TraceRecorder.attach(
      regionPath: regionPath,
      runtimeLibraryPath: runtime.absolute.path,
      processName: 'native_runtime_smoke',
      threadName: 'other',
    );
    _expect(otherRecorder.isActive, 'other recorder did not attach');

    recorder.registerSpan(
      userSpanIdStart + 1,
      'smoke.operation',
      category: 'smoke',
    );
    recorder.registerSpan(
      userSpanIdStart + 2,
      'smoke.counter',
      category: 'smoke.counter',
    );
    final sqlId = recorder.internString('SELECT * FROM smoke WHERE id = ?');
    _expect(sqlId != 0xFFFFFFFF, 'string interning failed');

    final value = recorder.trace<int>(
      userSpanIdStart + 1,
      () => 42,
      beginArgs: [sqlId, 1],
      endArgs: [1],
      correlationId: 11,
    );
    _expect(value == 42, 'sync trace returned unexpected value');

    await recorder.traceAsync<int>(
      userSpanIdStart + 3,
      () async => 7,
      beginArgs: [sqlId],
      endArgs: [0],
      correlationId: 12,
    );

    recorder.asyncBegin(userSpanIdStart + 4, correlationId: 21);
    otherRecorder.asyncEnd(userSpanIdStart + 4, correlationId: 21);
    recorder.counter(userSpanIdStart + 2, 3);
    recorder.gauge(userSpanIdStart + 5, 9);

    otherRecorder.detach();
    recorder.detach();

    final trace = Trace.loadRegion(regionPath);
    final activeTracks =
        trace.tracks.where((track) => track.state == 3).toList();
    _expect(activeTracks.length == 2, 'expected two detached producer tracks');
    _expect(
      trace.strings.values.contains('SELECT * FROM smoke WHERE id = ?'),
      'interned SQL string missing from trace',
    );
    _expect(
      trace.spanName(userSpanIdStart + 1) == 'smoke.operation',
      'registered span name missing from trace',
    );
    _expect(
      trace.spans.any((span) => span.spanId == userSpanIdStart + 1),
      'sync span missing from trace',
    );
    _expect(
      trace.spans.any(
        (span) => span.spanId == userSpanIdStart + 4 && span.isAsync,
      ),
      'cross-track async span missing from trace',
    );
    _expect(trace.counterEvents.length == 2, 'counter/gauge events missing');
    _expect(
      trace.diagnostics.unmatchedBeginEvents == 0,
      'trace has unmatched begin events',
    );
    _expect(
      trace.diagnostics.unmatchedEndEvents == 0,
      'trace has unmatched end events',
    );
  } finally {
    File(regionPath).deleteSync();
  }
}

Future<void> _recordSession(File runtime) async {
  final regionPath =
      '${Directory.systemTemp.path}/tracelite-session-runtime-$pid.tlt';
  TraceRegion.createFile(regionPath);
  try {
    const spanId = userSpanIdStart + 0x20;
    const counterId = userSpanIdStart + 0x21;
    const vocabulary = TraceVocabulary(
      name: 'native_runtime_smoke',
      definitions: [
        TraceDefinition(
          id: spanId,
          name: 'smoke.session.operation',
          category: 'smoke',
          kind: TraceDefinitionKind.span,
        ),
        TraceDefinition(
          id: counterId,
          name: 'smoke.session.counter',
          category: 'smoke.counter',
          kind: TraceDefinitionKind.counter,
        ),
      ],
    );

    final session = TraceSession.attach(
      regionPath: regionPath,
      runtimeLibraryPath: runtime.absolute.path,
      processName: 'native_runtime_smoke_session',
      threadName: 'main',
      vocabularies: const [vocabulary],
    );
    _expect(session.isActive, 'trace session did not attach');

    final correlationId = session.nextCorrelationId();
    final value = session.trace(
      spanId,
      () => 3,
      beginArgs: [1],
      endArgs: (result) => [result],
      correlationId: correlationId,
    );
    _expect(value == 3, 'session trace returned unexpected value');

    await session.traceAsync(
      spanId,
      () async => 4,
      beginArgs: [2],
      endArgs: (result) => [result],
    );
    session.counter(counterId, 5, correlationId: correlationId);
    session.detach();

    final trace = Trace.loadRegion(regionPath);
    _expect(
      trace.spanName(spanId) == 'smoke.session.operation',
      'session span vocabulary missing from trace',
    );
    _expect(
      trace.spanName(counterId) == 'smoke.session.counter',
      'session counter vocabulary missing from trace',
    );
    _expect(
      trace.spans.where((span) => span.spanId == spanId).length == 2,
      'expected two session spans',
    );
    _expect(
      trace.counterEvents.where((event) => event.spanId == counterId).length ==
          1,
      'expected one session counter event',
    );
  } finally {
    File(regionPath).deleteSync();
  }
}

Future<File> _ensureRuntimeLibrary() async {
  final file = File(native_artifacts.defaultRuntimeLibraryPath());
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
    throw StateError(
      'failed to build tracelite runtime library:\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
  return file;
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
