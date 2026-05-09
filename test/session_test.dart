import 'dart:io';

import 'package:test/test.dart';
import 'package:tracelite/tracelite.dart';

void main() {
  test('disabled trace session is no-op safe', () async {
    final session = TraceSession.disabled();
    expect(session.isActive, isFalse);
    expect(session.nextCorrelationId(), 1);
    expect(session.internString('SELECT 1'), 0xFFFFFFFF);
    expect(
      session.trace(0x4000, () => 7, endArgs: (value) => [value]),
      7,
    );
    expect(
      await session.traceAsync(0x4001, () async => 9),
      9,
    );
    expect(() {
      session.counter(0x4100, 1);
      session.gauge(0x4101, 2);
      session.detach();
    }, returnsNormally);
  });

  test('trace session registers vocabularies and records correlated spans',
      () async {
    final runtime = await _ensureRuntimeLibrary();
    final regionPath =
        '${Directory.systemTemp.path}/tracelite-session-$pid.tlt';
    addTearDown(() {
      try {
        File(regionPath).deleteSync();
      } catch (_) {}
    });

    const spanId = userSpanIdStart + 0x20;
    const counterId = userSpanIdStart + 0x21;
    const vocabulary = TraceVocabulary(
      name: 'session_test',
      definitions: [
        TraceDefinition(
          id: spanId,
          name: 'session.operation',
          category: 'session',
          kind: TraceDefinitionKind.span,
        ),
        TraceDefinition(
          id: counterId,
          name: 'session.counter',
          category: 'session.counter',
          kind: TraceDefinitionKind.counter,
        ),
      ],
    );

    TraceRegion.createFile(regionPath);
    final session = TraceSession.attach(
      regionPath: regionPath,
      runtimeLibraryPath: runtime.absolute.path,
      processName: 'session_test',
      threadName: 'main',
      vocabularies: const [vocabulary],
    );
    expect(session.isActive, isTrue);

    final correlationId = session.nextCorrelationId();
    final syncValue = session.trace(
      spanId,
      () => 3,
      beginArgs: [1],
      endArgs: (value) => [value],
      correlationId: correlationId,
    );
    expect(syncValue, 3);

    final asyncValue = await session.traceAsync(
      spanId,
      () async => 4,
      beginArgs: [2],
      endArgs: (value) => [value],
    );
    expect(asyncValue, 4);

    session.counter(counterId, 5, correlationId: correlationId);
    session.detach();

    final trace = Trace.loadRegion(regionPath);
    expect(trace.spanName(spanId), 'session.operation');
    expect(trace.spanName(counterId), 'session.counter');
    expect(trace.spans.where((span) => span.spanId == spanId), hasLength(2));
    expect(trace.counterEvents.ofCounterType(counterId), hasLength(1));
    expect(trace.diagnostics.droppedEvents, 0);
    expect(trace.diagnostics.unmatchedBeginEvents, 0);
    expect(trace.diagnostics.unmatchedEndEvents, 0);
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
