import 'producer.dart';
import 'vocabulary.dart';

final class TraceSession {
  TraceSession._(this.recorder);

  TraceSession.disabled() : recorder = TraceRecorder.disabled();

  factory TraceSession.attach({
    String? regionPath,
    String? runtimeLibraryPath,
    String? processName,
    String? threadName,
    int kind = traceTrackKindIsolate,
    Iterable<TraceVocabulary> vocabularies = const [],
  }) {
    final recorder = TraceRecorder.attach(
      regionPath: regionPath,
      runtimeLibraryPath: runtimeLibraryPath,
      processName: processName,
      threadName: threadName,
      kind: kind,
    );
    if (recorder.isActive) {
      for (final vocabulary in vocabularies) {
        recorder.registerVocabulary(vocabulary);
      }
    }
    return TraceSession._(recorder);
  }

  final TraceRecorder recorder;
  int _nextCorrelationId = 1;

  bool get isActive => recorder.isActive;

  int nextCorrelationId() {
    final id = _nextCorrelationId++;
    if (_nextCorrelationId == 0) {
      _nextCorrelationId = 1;
    }
    return id;
  }

  int internString(String value) => recorder.internString(value);

  void registerVocabulary(TraceVocabulary vocabulary) {
    recorder.registerVocabulary(vocabulary);
  }

  void begin(int spanId, {List<int> args = const [], int? correlationId}) {
    recorder.begin(spanId, args: args, correlationId: correlationId);
  }

  void end(int spanId, {List<int> args = const [], int? correlationId}) {
    recorder.end(spanId, args: args, correlationId: correlationId);
  }

  void asyncBegin(
    int spanId, {
    List<int> args = const [],
    required int correlationId,
  }) {
    recorder.asyncBegin(spanId, args: args, correlationId: correlationId);
  }

  void asyncEnd(
    int spanId, {
    List<int> args = const [],
    required int correlationId,
  }) {
    recorder.asyncEnd(spanId, args: args, correlationId: correlationId);
  }

  T trace<T>(
    int spanId,
    T Function() body, {
    List<int> beginArgs = const [],
    List<int> Function(T value)? endArgs,
    int? correlationId,
  }) {
    begin(spanId, args: beginArgs, correlationId: correlationId);
    try {
      final result = body();
      end(
        spanId,
        args: endArgs == null ? const [] : endArgs(result),
        correlationId: correlationId,
      );
      return result;
    } catch (_) {
      end(spanId, correlationId: correlationId);
      rethrow;
    }
  }

  Future<T> traceAsync<T>(
    int spanId,
    Future<T> Function() body, {
    int? correlationId,
    List<int> beginArgs = const [],
    List<int> Function(T value)? endArgs,
  }) async {
    final resolvedCorrelationId = correlationId ?? nextCorrelationId();
    asyncBegin(
      spanId,
      args: beginArgs,
      correlationId: resolvedCorrelationId,
    );
    try {
      final result = await body();
      asyncEnd(
        spanId,
        args: endArgs == null ? const [] : endArgs(result),
        correlationId: resolvedCorrelationId,
      );
      return result;
    } catch (_) {
      asyncEnd(spanId, correlationId: resolvedCorrelationId);
      rethrow;
    }
  }

  void counter(int spanId, int value, {int? correlationId}) {
    recorder.counter(spanId, value, correlationId: correlationId);
  }

  void gauge(int spanId, int value, {int? correlationId}) {
    recorder.gauge(spanId, value, correlationId: correlationId);
  }

  void detach() {
    recorder.detach();
  }
}
