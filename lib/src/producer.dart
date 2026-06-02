import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

const int traceTrackKindUnknown = 0;
const int traceTrackKindIsolate = 1;
const int traceTrackKindCThread = 2;
const int traceTrackKindProcess = 3;

const int userSpanIdStart = 0x4000;
const int userSpanIdEnd = 0xFFFF;

const int metadataKindAddSpan = 0x0001;

typedef _AttachNative = Int32 Function(Pointer<Utf8>);
typedef _AttachDart = int Function(Pointer<Utf8>);
typedef _RegisterProducerNative = Int32 Function(
  Uint8,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _RegisterProducerDart = int Function(
  int,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _NowNative = Uint64 Function();
typedef _NowDart = int Function();
typedef _InternStringNative = Uint32 Function(Pointer<Utf8>, Uint32);
typedef _InternStringDart = int Function(Pointer<Utf8>, int);
typedef _RecordNative = Void Function(Uint16, Pointer<Uint64>, Uint8);
typedef _RecordDart = void Function(int, Pointer<Uint64>, int);
typedef _RecordCorrelatedNative = Void Function(
  Uint16,
  Uint64,
  Pointer<Uint64>,
  Uint8,
);
typedef _RecordCorrelatedDart = void Function(
  int,
  int,
  Pointer<Uint64>,
  int,
);
typedef _RecordOnTrackNative = Void Function(
  Uint8,
  Uint16,
  Pointer<Uint64>,
  Uint8,
);
typedef _RecordOnTrackDart = void Function(
  int,
  int,
  Pointer<Uint64>,
  int,
);
typedef _RecordCorrelatedOnTrackNative = Void Function(
  Uint8,
  Uint16,
  Uint64,
  Pointer<Uint64>,
  Uint8,
);
typedef _RecordCorrelatedOnTrackDart = void Function(
  int,
  int,
  int,
  Pointer<Uint64>,
  int,
);
typedef _CounterNative = Void Function(Uint16, Int64);
typedef _CounterDart = void Function(int, int);
typedef _CounterCorrelatedNative = Void Function(Uint16, Uint64, Int64);
typedef _CounterCorrelatedDart = void Function(int, int, int);
typedef _CounterOnTrackNative = Void Function(Uint8, Uint16, Int64);
typedef _CounterOnTrackDart = void Function(int, int, int);
typedef _CounterCorrelatedOnTrackNative = Void Function(
  Uint8,
  Uint16,
  Uint64,
  Int64,
);
typedef _CounterCorrelatedOnTrackDart = void Function(int, int, int, int);
typedef _DetachNative = Void Function();
typedef _DetachDart = void Function();
typedef _DetachTrackNative = Void Function(Uint8);
typedef _DetachTrackDart = void Function(int);

final class TraceRecorder {
  TraceRecorder._(this._runtime, this.trackId);

  TraceRecorder.disabled()
      : _runtime = null,
        trackId = -1;

  final _TraceliteRuntime? _runtime;
  final int trackId;

  bool get isActive => _runtime != null && trackId >= 0;

  static TraceRecorder attach({
    String? regionPath,
    String? runtimeLibraryPath,
    String? processName,
    String? threadName,
    int kind = traceTrackKindIsolate,
  }) {
    final path = regionPath ?? Platform.environment['TRACELITE_REGION'];
    if (path == null || path.isEmpty) {
      return TraceRecorder.disabled();
    }

    final runtime = _TraceliteRuntime.open(runtimeLibraryPath);
    final attachResult = _withNativeString(path, runtime.attach);
    if (attachResult != 0) {
      return TraceRecorder.disabled();
    }

    final resolvedProcessName =
        processName ?? Platform.script.pathSegments.last;
    final resolvedThreadName =
        threadName ?? Isolate.current.debugName ?? 'dart_isolate';
    final trackId = _withNativeString(
      resolvedProcessName,
      (processPtr) => _withNativeString(
        resolvedThreadName,
        (threadPtr) => runtime.registerProducer(kind, processPtr, threadPtr),
      ),
    );
    if (trackId < 0) {
      return TraceRecorder.disabled();
    }

    return TraceRecorder._(runtime, trackId);
  }

  int nowNs() => _runtime?.now() ?? 0;

  int internString(String value) {
    final runtime = _runtime;
    if (runtime == null) return 0xFFFFFFFF;
    return _withNativeUtf8Bytes(
      value,
      (ptr, byteLength) => runtime.internString(ptr, byteLength),
    );
  }

  void begin(
    int spanId, {
    List<int> args = const [],
    int? correlationId,
  }) {
    final runtime = _runtime;
    if (runtime == null) return;
    _withArgs(args, (ptr, count) {
      if (correlationId == null) {
        runtime.beginOnTrack(trackId, spanId, ptr, count);
      } else {
        runtime.beginCorrelatedOnTrack(
          trackId,
          spanId,
          correlationId,
          ptr,
          count,
        );
      }
    });
  }

  void end(
    int spanId, {
    List<int> args = const [],
    int? correlationId,
  }) {
    final runtime = _runtime;
    if (runtime == null) return;
    _withArgs(args, (ptr, count) {
      if (correlationId == null) {
        runtime.endOnTrack(trackId, spanId, ptr, count);
      } else {
        runtime.endCorrelatedOnTrack(
          trackId,
          spanId,
          correlationId,
          ptr,
          count,
        );
      }
    });
  }

  void instant(
    int spanId, {
    List<int> args = const [],
    int? correlationId,
  }) {
    final runtime = _runtime;
    if (runtime == null) return;
    _withArgs(args, (ptr, count) {
      if (correlationId == null) {
        runtime.instantOnTrack(trackId, spanId, ptr, count);
      } else {
        runtime.instantCorrelatedOnTrack(
          trackId,
          spanId,
          correlationId,
          ptr,
          count,
        );
      }
    });
  }

  void asyncBegin(
    int spanId, {
    required int correlationId,
    List<int> args = const [],
  }) {
    final runtime = _runtime;
    if (runtime == null) return;
    _withArgs(
      args,
      (ptr, count) =>
          runtime.asyncBeginOnTrack(trackId, spanId, correlationId, ptr, count),
    );
  }

  void asyncEnd(
    int spanId, {
    required int correlationId,
    List<int> args = const [],
  }) {
    final runtime = _runtime;
    if (runtime == null) return;
    _withArgs(
      args,
      (ptr, count) =>
          runtime.asyncEndOnTrack(trackId, spanId, correlationId, ptr, count),
    );
  }

  T trace<T>(
    int spanId,
    T Function() body, {
    List<int> beginArgs = const [],
    List<int> endArgs = const [],
    int? correlationId,
  }) {
    begin(spanId, args: beginArgs, correlationId: correlationId);
    try {
      return body();
    } finally {
      end(spanId, args: endArgs, correlationId: correlationId);
    }
  }

  Future<T> traceAsync<T>(
    int spanId,
    Future<T> Function() body, {
    required int correlationId,
    List<int> beginArgs = const [],
    List<int> endArgs = const [],
  }) async {
    asyncBegin(spanId, correlationId: correlationId, args: beginArgs);
    try {
      return await body();
    } finally {
      asyncEnd(spanId, correlationId: correlationId, args: endArgs);
    }
  }

  void counter(int spanId, int value, {int? correlationId}) {
    final runtime = _runtime;
    if (runtime == null) return;
    if (correlationId == null) {
      runtime.counterOnTrack(trackId, spanId, value);
    } else {
      runtime.counterCorrelatedOnTrack(trackId, spanId, correlationId, value);
    }
  }

  void gauge(int spanId, int value, {int? correlationId}) {
    counter(spanId, value, correlationId: correlationId);
  }

  void metadata(int metadataKind, {List<int> args = const []}) {
    final runtime = _runtime;
    if (runtime == null) return;
    _withArgs(
      args,
      (ptr, count) => runtime.metadataOnTrack(
        trackId,
        metadataKind,
        ptr,
        count,
      ),
    );
  }

  void registerSpan(int spanId, String name, {String category = 'user'}) {
    final nameId = internString(name);
    final categoryId = internString(category);
    metadata(metadataKindAddSpan, args: [spanId, nameId, categoryId]);
  }

  void detach() {
    _runtime?.detachTrack(trackId);
  }
}

final class _TraceliteRuntime {
  _TraceliteRuntime._(DynamicLibrary library)
      : attach = library.lookupFunction<_AttachNative, _AttachDart>(
          'tlt_attach',
        ),
        registerProducer = library.lookupFunction<_RegisterProducerNative,
            _RegisterProducerDart>('tlt_register_producer'),
        now = library.lookupFunction<_NowNative, _NowDart>('tlt_now_ns'),
        internString =
            library.lookupFunction<_InternStringNative, _InternStringDart>(
                'tlt_intern_string'),
        begin = library.lookupFunction<_RecordNative, _RecordDart>(
          'tlt_begin',
        ),
        end = library.lookupFunction<_RecordNative, _RecordDart>(
          'tlt_end',
        ),
        instant = library.lookupFunction<_RecordNative, _RecordDart>(
          'tlt_instant',
        ),
        beginCorrelated = library.lookupFunction<_RecordCorrelatedNative,
            _RecordCorrelatedDart>('tlt_begin_correlated'),
        endCorrelated = library.lookupFunction<_RecordCorrelatedNative,
            _RecordCorrelatedDart>('tlt_end_correlated'),
        instantCorrelated = library.lookupFunction<_RecordCorrelatedNative,
            _RecordCorrelatedDart>('tlt_instant_correlated'),
        asyncBegin = library.lookupFunction<_RecordCorrelatedNative,
            _RecordCorrelatedDart>('tlt_async_begin'),
        asyncEnd = library.lookupFunction<_RecordCorrelatedNative,
            _RecordCorrelatedDart>('tlt_async_end'),
        beginOnTrack =
            library.lookupFunction<_RecordOnTrackNative, _RecordOnTrackDart>(
                'tlt_begin_on_track'),
        endOnTrack =
            library.lookupFunction<_RecordOnTrackNative, _RecordOnTrackDart>(
                'tlt_end_on_track'),
        instantOnTrack =
            library.lookupFunction<_RecordOnTrackNative, _RecordOnTrackDart>(
                'tlt_instant_on_track'),
        beginCorrelatedOnTrack = library.lookupFunction<
            _RecordCorrelatedOnTrackNative,
            _RecordCorrelatedOnTrackDart>('tlt_begin_correlated_on_track'),
        endCorrelatedOnTrack = library.lookupFunction<
            _RecordCorrelatedOnTrackNative,
            _RecordCorrelatedOnTrackDart>('tlt_end_correlated_on_track'),
        instantCorrelatedOnTrack = library.lookupFunction<
            _RecordCorrelatedOnTrackNative,
            _RecordCorrelatedOnTrackDart>('tlt_instant_correlated_on_track'),
        asyncBeginOnTrack = library.lookupFunction<
            _RecordCorrelatedOnTrackNative,
            _RecordCorrelatedOnTrackDart>('tlt_async_begin_on_track'),
        asyncEndOnTrack = library.lookupFunction<_RecordCorrelatedOnTrackNative,
            _RecordCorrelatedOnTrackDart>('tlt_async_end_on_track'),
        counter = library.lookupFunction<_CounterNative, _CounterDart>(
          'tlt_counter',
        ),
        counterCorrelated = library.lookupFunction<_CounterCorrelatedNative,
            _CounterCorrelatedDart>('tlt_counter_correlated'),
        counterOnTrack =
            library.lookupFunction<_CounterOnTrackNative, _CounterOnTrackDart>(
                'tlt_counter_on_track'),
        counterCorrelatedOnTrack = library.lookupFunction<
            _CounterCorrelatedOnTrackNative,
            _CounterCorrelatedOnTrackDart>('tlt_counter_correlated_on_track'),
        metadata = library.lookupFunction<_RecordNative, _RecordDart>(
          'tlt_metadata',
        ),
        metadataOnTrack =
            library.lookupFunction<_RecordOnTrackNative, _RecordOnTrackDart>(
                'tlt_metadata_on_track'),
        detach = library.lookupFunction<_DetachNative, _DetachDart>(
          'tlt_detach',
        ),
        detachTrack =
            library.lookupFunction<_DetachTrackNative, _DetachTrackDart>(
                'tlt_detach_track');

  final _AttachDart attach;
  final _RegisterProducerDart registerProducer;
  final _NowDart now;
  final _InternStringDart internString;
  final _RecordDart begin;
  final _RecordDart end;
  final _RecordDart instant;
  final _RecordCorrelatedDart beginCorrelated;
  final _RecordCorrelatedDart endCorrelated;
  final _RecordCorrelatedDart instantCorrelated;
  final _RecordCorrelatedDart asyncBegin;
  final _RecordCorrelatedDart asyncEnd;
  final _RecordOnTrackDart beginOnTrack;
  final _RecordOnTrackDart endOnTrack;
  final _RecordOnTrackDart instantOnTrack;
  final _RecordCorrelatedOnTrackDart beginCorrelatedOnTrack;
  final _RecordCorrelatedOnTrackDart endCorrelatedOnTrack;
  final _RecordCorrelatedOnTrackDart instantCorrelatedOnTrack;
  final _RecordCorrelatedOnTrackDart asyncBeginOnTrack;
  final _RecordCorrelatedOnTrackDart asyncEndOnTrack;
  final _CounterDart counter;
  final _CounterCorrelatedDart counterCorrelated;
  final _CounterOnTrackDart counterOnTrack;
  final _CounterCorrelatedOnTrackDart counterCorrelatedOnTrack;
  final _RecordDart metadata;
  final _RecordOnTrackDart metadataOnTrack;
  final _DetachDart detach;
  final _DetachTrackDart detachTrack;

  static _TraceliteRuntime open(String? explicitPath) {
    final errors = <String>[];
    for (final candidate in _runtimeLibraryCandidates(explicitPath)) {
      try {
        return _TraceliteRuntime._(DynamicLibrary.open(candidate));
      } catch (error) {
        errors.add('$candidate: $error');
      }
    }

    try {
      return _TraceliteRuntime._(DynamicLibrary.process());
    } catch (error) {
      errors.add('process: $error');
    }

    throw StateError(
      'Unable to load tracelite runtime library. Build one with the command '
      'shown by `dart run bin/tracelite.dart doctor`.\n'
      'Tried:\n${errors.join('\n')}',
    );
  }
}

List<String> _runtimeLibraryCandidates(String? explicitPath) {
  final env = Platform.environment['TRACELITE_RUNTIME'];
  final names = switch (Platform.operatingSystem) {
    'macos' => const ['libtracelite_runtime.dylib'],
    'windows' => const ['libtracelite_runtime.dll', 'tracelite_runtime.dll'],
    _ => const ['libtracelite_runtime.so'],
  };
  return [
    if (explicitPath != null && explicitPath.isNotEmpty) explicitPath,
    if (env != null && env.isNotEmpty) env,
    for (final name in names) 'build/$name',
    for (final name in names) name,
  ];
}

R _withNativeString<R>(String value, R Function(Pointer<Utf8>) body) {
  final ptr = value.toNativeUtf8();
  try {
    return body(ptr);
  } finally {
    calloc.free(ptr);
  }
}

R _withNativeUtf8Bytes<R>(
  String value,
  R Function(Pointer<Utf8>, int byteLength) body,
) {
  final ptr = value.toNativeUtf8();
  try {
    return body(ptr, utf8.encode(value).length);
  } finally {
    calloc.free(ptr);
  }
}

void _withArgs(List<int> args, void Function(Pointer<Uint64>, int) body) {
  if (args.length > 255) {
    throw RangeError.range(args.length, 0, 255, 'args.length');
  }
  if (args.isEmpty) {
    body(nullptr.cast<Uint64>(), 0);
    return;
  }

  final ptr = calloc<Uint64>(args.length);
  try {
    for (var i = 0; i < args.length; i++) {
      ptr[i] = args[i];
    }
    body(ptr, args.length);
  } finally {
    calloc.free(ptr);
  }
}
