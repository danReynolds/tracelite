import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'builtin_spans.g.dart';

const int kTraceliteRegionMagic = 0x52544c54; // "TLTR" LE
const int kHeaderSize = 128;
const int kRegistrySlotSize = 16;
const int kRingHeaderSize = 64;

const int kDefaultMaxProducers = 8;
const int kDefaultStringPoolSize = 128 * 1024;
const int kDefaultRingDataWords = 8192;
const int kRegistryReservedBytes = 256 * 16;

const int traceTagBegin = 0x01;
const int traceTagEnd = 0x02;
const int traceTagInstant = 0x03;
const int traceTagAsyncBegin = 0x04;
const int traceTagAsyncEnd = 0x05;
const int traceTagCounter = 0x06;
const int traceTagMetadata = 0x07;
const int traceTagFlow = 0x08;
const int traceFlagHasCorrelation = 0x01;
const int _metadataKindAddSpan = 0x0001;

class TraceRegion {
  TraceRegion._();

  static int perRingSize({int ringDataWords = kDefaultRingDataWords}) {
    _checkPowerOfTwo(ringDataWords, 'ringDataWords');
    return kRingHeaderSize + ringDataWords * 8;
  }

  static int totalSize({
    int maxProducers = kDefaultMaxProducers,
    int stringPoolSize = kDefaultStringPoolSize,
    int ringDataWords = kDefaultRingDataWords,
  }) {
    final ringSectionOffset =
        kHeaderSize + kRegistryReservedBytes + stringPoolSize;
    return ringSectionOffset +
        perRingSize(ringDataWords: ringDataWords) * maxProducers;
  }

  static void createFile(
    String path, {
    int maxProducers = kDefaultMaxProducers,
    int stringPoolSize = kDefaultStringPoolSize,
    int ringDataWords = kDefaultRingDataWords,
  }) {
    _checkPowerOfTwo(ringDataWords, 'ringDataWords');
    final registryOffset = kHeaderSize;
    final stringPoolOffset = registryOffset + kRegistryReservedBytes;
    final ringSectionOffset = stringPoolOffset + stringPoolSize;
    final perProducerRingSize = perRingSize(ringDataWords: ringDataWords);
    final size = ringSectionOffset + perProducerRingSize * maxProducers;

    final headerBytes = Uint8List(kHeaderSize);
    final view = ByteData.sublistView(headerBytes);

    view.setUint32(0, kTraceliteRegionMagic, Endian.little);
    view.setUint16(4, kFormatVersion[0], Endian.little);
    view.setUint16(6, kFormatVersion[1], Endian.little);
    view.setUint64(
      8,
      DateTime.now().microsecondsSinceEpoch * 1000,
      Endian.little,
    );
    view.setUint64(16, 0, Endian.little);
    view.setUint32(24, size, Endian.little);
    view.setUint32(28, registryOffset, Endian.little);
    view.setUint32(32, stringPoolOffset, Endian.little);
    view.setUint32(36, stringPoolSize, Endian.little);
    view.setUint32(40, ringSectionOffset, Endian.little);
    view.setUint32(44, perProducerRingSize, Endian.little);
    view.setUint32(48, maxProducers, Endian.little);
    view.setUint8(52, 0);
    view.setUint8(53, 1);
    view.setUint64(56, 0, Endian.little);

    final file = File(path);
    final opened = file.openSync(mode: FileMode.write);
    try {
      opened.setPositionSync(0);
      opened.writeFromSync(headerBytes);
      opened.truncateSync(size);

      final ringHeaderBytes = Uint8List(kRingHeaderSize);
      final ringHeaderView = ByteData.sublistView(ringHeaderBytes);
      ringHeaderView.setUint32(24, ringDataWords, Endian.little);
      ringHeaderView.setUint32(28, ringDataWords - 1, Endian.little);
      for (var i = 0; i < maxProducers; i++) {
        final offset = ringSectionOffset + i * perProducerRingSize;
        opened.setPositionSync(offset);
        opened.writeFromSync(ringHeaderBytes);
      }
    } finally {
      opened.closeSync();
    }
  }

  static void _checkPowerOfTwo(int value, String name) {
    if (value <= 0 || (value & (value - 1)) != 0) {
      throw ArgumentError.value(value, name, 'must be a positive power of two');
    }
  }
}

class Trace {
  Trace({
    required this.header,
    required this.tracks,
    required this.events,
    required this.spans,
    required this.strings,
    required this.spanNames,
    required this.diagnostics,
  });

  final TraceHeader header;
  final List<TraceTrack> tracks;
  final List<TraceEvent> events;
  final List<TraceSpan> spans;
  final Map<int, String> strings;
  final Map<int, String> spanNames;
  final TraceDiagnostics diagnostics;

  Iterable<TraceEvent> get counterEvents =>
      events.where((event) => event.isCounter);

  Iterable<TraceEvent> get metadataEvents =>
      events.where((event) => event.isMetadata);

  List<TraceWorkload> get workloads {
    final result = <TraceWorkload>[];
    for (final span in spans.where(
      (span) =>
          span.isComplete &&
          spanName(span.spanId).endsWith('.profile.workload'),
    )) {
      final startNs = span.startNs;
      final endNs = span.endNs ?? span.startNs;
      final correlationId = span.begin.correlationId ?? span.end?.correlationId;
      final name = span.beginArgs.isEmpty
          ? spanName(span.spanId)
          : strings[span.beginArgs.first] ?? span.beginArgs.first.toString();
      final iterations = span.beginArgs.length > 1 ? span.beginArgs[1] : null;
      final sampleCount = span.endArgs.isNotEmpty ? span.endArgs.first : null;
      result.add(
        TraceWorkload(
          name: name,
          span: span,
          iterations: iterations,
          sampleCount: sampleCount,
          spans: spans
              .where(
                (candidate) =>
                    !identical(candidate, span) &&
                    candidate.isComplete &&
                    candidate.startNs >= startNs &&
                    (candidate.endNs ?? candidate.startNs) <= endNs,
              )
              .toList(growable: false),
          counters: counterEvents.where((event) {
            final inRange =
                event.timestampNs >= startNs && event.timestampNs <= endNs;
            final correlated =
                correlationId != null && event.correlationId == correlationId;
            return inRange || correlated;
          }).toList(growable: false),
        ),
      );
    }
    result.sort((a, b) => a.span.startNs.compareTo(b.span.startNs));
    return List.unmodifiable(result);
  }

  Duration get duration {
    if (events.isEmpty) return Duration.zero;
    final start = events.first.timestampNs;
    final end = events.last.timestampNs;
    return Duration(microseconds: math.max(0, end - start) ~/ 1000);
  }

  static Trace loadRegion(String path) {
    final raw = File(path).readAsBytesSync();
    return fromRegionBytes(raw, sourcePath: path);
  }

  static Trace fromRegionBytes(List<int> raw, {String? sourcePath}) {
    final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    final view = ByteData.sublistView(bytes);
    final header = TraceHeader.read(view, sourcePath: sourcePath);
    final strings = _readStringPool(view, header);
    final tracks = _readRegistry(view, header, strings);

    final allEvents = <TraceEvent>[];
    final allSpans = <TraceSpan>[];
    var unmatchedEnds = 0;
    var droppedEvents = 0;

    for (final track in tracks.where((track) => track.state >= 2)) {
      final decoded = _drainRing(view, header, track);
      droppedEvents += decoded.droppedEvents;
      allEvents.addAll(decoded.events);
      allSpans.addAll(decoded.spans);
      unmatchedEnds += decoded.unmatchedEndEvents;
    }

    allEvents.sort((a, b) {
      final byTime = a.timestampNs.compareTo(b.timestampNs);
      if (byTime != 0) return byTime;
      final byTrack = a.trackId.compareTo(b.trackId);
      if (byTrack != 0) return byTrack;
      return a.sequence.compareTo(b.sequence);
    });
    final asyncDecoded = _pairAsyncSpans(allEvents);
    allSpans.addAll(asyncDecoded.spans);
    unmatchedEnds += asyncDecoded.unmatchedEndEvents;

    allSpans.sort((a, b) {
      final byTime = a.startNs.compareTo(b.startNs);
      if (byTime != 0) return byTime;
      return a.trackId.compareTo(b.trackId);
    });

    final spanNames = _readSpanNames(allEvents, strings);
    final unmatchedBegins = allSpans.where((span) => span.end == null).length;
    return Trace(
      header: header,
      tracks: List.unmodifiable(tracks),
      events: List.unmodifiable(allEvents),
      spans: List.unmodifiable(allSpans),
      strings: Map.unmodifiable(strings),
      spanNames: Map.unmodifiable(spanNames),
      diagnostics: TraceDiagnostics(
        unmatchedBeginEvents: unmatchedBegins,
        unmatchedEndEvents: unmatchedEnds,
        droppedEvents: droppedEvents,
      ),
    );
  }

  String spanName(int spanId) => spanNames[spanId] ?? hexSpanId(spanId);

  String toMarkdownReport() {
    final groups = spans
        .where((span) => span.isComplete && span.durationNs >= 0)
        .groupStatsByType(spanNames: spanNames)
      ..sort((a, b) {
        final byTotal = b.stats.totalNs.compareTo(a.stats.totalNs);
        if (byTotal != 0) return byTotal;
        return a.spanName.compareTo(b.spanName);
      });
    final counterGroups = counterEvents.groupCounterStatsByType(
      spanNames: spanNames,
    )..sort((a, b) {
        final byName = a.spanName.compareTo(b.spanName);
        if (byName != 0) return byName;
        return a.spanId.compareTo(b.spanId);
      });

    final buffer = StringBuffer()
      ..writeln('# tracelite report')
      ..writeln()
      ..writeln('Trace: ${events.length} events, ${tracks.length} producer(s)')
      ..writeln('Duration: ${formatDurationNs(duration.inMicroseconds * 1000)}')
      ..writeln(
        'Diagnostics: ${diagnostics.droppedEvents} dropped, '
        '${diagnostics.unmatchedBeginEvents} unmatched begin, '
        '${diagnostics.unmatchedEndEvents} unmatched end',
      )
      ..writeln()
      ..writeln('| span | count | p50 | p90 | p99 | total |')
      ..writeln('|---|---:|---:|---:|---:|---:|');

    if (groups.isEmpty) {
      buffer.writeln('| _(no complete spans)_ | 0 | - | - | - | - |');
    } else {
      for (final group in groups) {
        final stats = group.stats;
        buffer.writeln(
          '| `${group.spanName}` | ${stats.count} | '
          '${formatDurationNs(stats.p50Ns)} | '
          '${formatDurationNs(stats.p90Ns)} | '
          '${formatDurationNs(stats.p99Ns)} | '
          '${formatDurationNs(stats.totalNs)} |',
        );
      }
    }

    final workloadGroups = workloads;
    if (workloadGroups.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## Workloads')
        ..writeln()
        ..writeln(
          '| workload | iterations | samples | duration | spans | counters |',
        )
        ..writeln('|---|---:|---:|---:|---:|---:|');

      for (final workload in workloadGroups) {
        buffer.writeln(
          '| `${_markdownCell(workload.name)}` | '
          '${workload.iterations ?? '-'} | '
          '${workload.sampleCount ?? '-'} | '
          '${formatDurationNs(workload.span.durationNs)} | '
          '${workload.spans.length} | '
          '${workload.counters.length} |',
        );
      }

      for (final workload in workloadGroups) {
        buffer
          ..writeln()
          ..writeln('### ${workload.name}')
          ..writeln()
          ..writeln('| span | count | p50 | p90 | p99 | total |')
          ..writeln('|---|---:|---:|---:|---:|---:|');

        final nestedGroups = workload.spans.groupStatsByType(
          spanNames: spanNames,
        )..sort((a, b) {
            final byTotal = b.stats.totalNs.compareTo(a.stats.totalNs);
            if (byTotal != 0) return byTotal;
            return a.spanName.compareTo(b.spanName);
          });
        if (nestedGroups.isEmpty) {
          buffer.writeln('| _(no nested spans)_ | 0 | - | - | - | - |');
        } else {
          for (final group in nestedGroups) {
            final stats = group.stats;
            buffer.writeln(
              '| `${group.spanName}` | ${stats.count} | '
              '${formatDurationNs(stats.p50Ns)} | '
              '${formatDurationNs(stats.p90Ns)} | '
              '${formatDurationNs(stats.p99Ns)} | '
              '${formatDurationNs(stats.totalNs)} |',
            );
          }
        }

        final workloadCounters = workload.counters.groupCounterStatsByType(
          spanNames: spanNames,
        )..sort((a, b) {
            final byName = a.spanName.compareTo(b.spanName);
            if (byName != 0) return byName;
            return a.spanId.compareTo(b.spanId);
          });
        if (workloadCounters.isNotEmpty) {
          buffer
            ..writeln()
            ..writeln('| counter | samples | latest | min | max |')
            ..writeln('|---|---:|---:|---:|---:|');
          for (final group in workloadCounters) {
            final stats = group.stats;
            buffer.writeln(
              '| `${group.spanName}` | ${stats.count} | ${stats.latest} | '
              '${stats.min} | ${stats.max} |',
            );
          }
        }
      }
    }

    if (counterGroups.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## Counters')
        ..writeln()
        ..writeln('| counter | samples | latest | min | max |')
        ..writeln('|---|---:|---:|---:|---:|');

      for (final group in counterGroups) {
        final stats = group.stats;
        buffer.writeln(
          '| `${group.spanName}` | ${stats.count} | ${stats.latest} | '
          '${stats.min} | ${stats.max} |',
        );
      }
    }

    return buffer.toString();
  }
}

class TraceHeader {
  TraceHeader({
    required this.sourcePath,
    required this.formatMajor,
    required this.formatMinor,
    required this.startRealtimeNs,
    required this.startMonotonicNs,
    required this.regionTotalSize,
    required this.producerRegistryOffset,
    required this.stringPoolOffset,
    required this.stringPoolSize,
    required this.producerRingOffset,
    required this.perProducerRingSize,
    required this.maxProducers,
    required this.state,
    required this.endianness,
    required this.stringPoolHead,
  });

  final String? sourcePath;
  final int formatMajor;
  final int formatMinor;
  final int startRealtimeNs;
  final int startMonotonicNs;
  final int regionTotalSize;
  final int producerRegistryOffset;
  final int stringPoolOffset;
  final int stringPoolSize;
  final int producerRingOffset;
  final int perProducerRingSize;
  final int maxProducers;
  final int state;
  final int endianness;
  final int stringPoolHead;

  static TraceHeader read(ByteData view, {String? sourcePath}) {
    final magic = view.getUint32(0, Endian.little);
    if (magic != kTraceliteRegionMagic) {
      throw FormatException(
        'invalid tracelite region magic 0x${magic.toRadixString(16)}',
      );
    }
    final formatMajor = view.getUint16(4, Endian.little);
    final formatMinor = view.getUint16(6, Endian.little);
    if (formatMajor != kFormatVersion[0]) {
      throw FormatException(
        'unsupported tracelite format major $formatMajor',
      );
    }
    final endianness = view.getUint8(53);
    if (endianness != 1) {
      throw const FormatException('only little-endian regions are supported');
    }
    final regionTotalSize = view.getUint32(24, Endian.little);
    if (regionTotalSize > view.lengthInBytes) {
      throw FormatException(
        'region header claims $regionTotalSize bytes, file has '
        '${view.lengthInBytes}',
      );
    }

    return TraceHeader(
      sourcePath: sourcePath,
      formatMajor: formatMajor,
      formatMinor: formatMinor,
      startRealtimeNs: view.getUint64(8, Endian.little),
      startMonotonicNs: view.getUint64(16, Endian.little),
      regionTotalSize: regionTotalSize,
      producerRegistryOffset: view.getUint32(28, Endian.little),
      stringPoolOffset: view.getUint32(32, Endian.little),
      stringPoolSize: view.getUint32(36, Endian.little),
      producerRingOffset: view.getUint32(40, Endian.little),
      perProducerRingSize: view.getUint32(44, Endian.little),
      maxProducers: view.getUint32(48, Endian.little),
      state: view.getUint8(52),
      endianness: endianness,
      stringPoolHead: view.getUint64(56, Endian.little),
    );
  }
}

class TraceTrack {
  TraceTrack({
    required this.id,
    required this.state,
    required this.kind,
    required this.processStringId,
    required this.threadStringId,
    required this.metadataStringId,
    required this.processName,
    required this.threadName,
    required this.droppedEvents,
  });

  final int id;
  final int state;
  final int kind;
  final int processStringId;
  final int threadStringId;
  final int metadataStringId;
  final String? processName;
  final String? threadName;
  final int droppedEvents;

  String get displayName {
    final process = processName ?? 'track_$id';
    final thread = threadName;
    if (thread == null || thread.isEmpty) return process;
    return '$process/$thread';
  }
}

class TraceEvent {
  TraceEvent({
    required this.sequence,
    required this.tag,
    required this.trackId,
    required this.spanId,
    required this.timestampNs,
    required this.args,
    required this.correlationId,
  });

  final int sequence;
  final int tag;
  final int trackId;
  final int spanId;
  final int timestampNs;
  final List<int> args;
  final int? correlationId;

  String get spanName => kSpanNames[spanId] ?? hexSpanId(spanId);
  bool get isBegin => tag == traceTagBegin;
  bool get isEnd => tag == traceTagEnd;
  bool get isInstant => tag == traceTagInstant;
  bool get isAsyncBegin => tag == traceTagAsyncBegin;
  bool get isAsyncEnd => tag == traceTagAsyncEnd;
  bool get isCounter => tag == traceTagCounter;
  bool get isMetadata => tag == traceTagMetadata;
  bool get isFlow => tag == traceTagFlow;
}

class TraceSpan {
  TraceSpan({
    required this.trackId,
    required this.spanId,
    required this.begin,
    required this.end,
  });

  final int trackId;
  final int spanId;
  final TraceEvent begin;
  final TraceEvent? end;

  String get spanName => kSpanNames[spanId] ?? hexSpanId(spanId);
  bool get isAsync => begin.isAsyncBegin || (end?.isAsyncEnd ?? false);
  int get startNs => begin.timestampNs;
  int? get endNs => end?.timestampNs;
  int get durationNs =>
      end == null ? 0 : math.max(0, end!.timestampNs - begin.timestampNs);
  List<int> get beginArgs => begin.args;
  List<int> get endArgs => end?.args ?? const [];
  bool get isComplete => end != null || begin.isInstant;
}

class TraceWorkload {
  TraceWorkload({
    required this.name,
    required this.span,
    required this.iterations,
    required this.sampleCount,
    required this.spans,
    required this.counters,
  });

  final String name;
  final TraceSpan span;
  final int? iterations;
  final int? sampleCount;
  final List<TraceSpan> spans;
  final List<TraceEvent> counters;
}

class TraceDiagnostics {
  const TraceDiagnostics({
    required this.unmatchedBeginEvents,
    required this.unmatchedEndEvents,
    required this.droppedEvents,
  });

  final int unmatchedBeginEvents;
  final int unmatchedEndEvents;
  final int droppedEvents;
}

class TimeRange {
  const TimeRange(this.startNs, this.endNs);

  final int startNs;
  final int endNs;

  bool overlaps(int start, int end) => start < endNs && end > startNs;
}

class DurationStats {
  DurationStats._(this._values)
      : count = _values.length,
        totalNs = _values.fold<int>(0, (sum, value) => sum + value),
        minNs = _values.isEmpty ? 0 : _values.first,
        maxNs = _values.isEmpty ? 0 : _values.last,
        meanNs = _values.isEmpty
            ? 0
            : _values.fold<int>(0, (sum, value) => sum + value) /
                _values.length,
        p50Ns = _percentile(_values, 0.50),
        p90Ns = _percentile(_values, 0.90),
        p99Ns = _percentile(_values, 0.99);

  factory DurationStats.fromNs(Iterable<int> values) {
    final sorted = values.toList()..sort();
    return DurationStats._(List.unmodifiable(sorted));
  }

  final List<int> _values;
  final int count;
  final int totalNs;
  final int minNs;
  final int maxNs;
  final double meanNs;
  final int p50Ns;
  final int p90Ns;
  final int p99Ns;

  Iterable<int> get values => _values;

  static int _percentile(List<int> values, double percentile) {
    if (values.isEmpty) return 0;
    final rank = ((values.length - 1) * percentile).ceil();
    return values[rank.clamp(0, values.length - 1)];
  }
}

class SpanGroupStats {
  SpanGroupStats({
    required this.spanId,
    required this.spanName,
    required this.stats,
  });

  final int spanId;
  final String spanName;
  final DurationStats stats;
}

class CounterGroupStats {
  CounterGroupStats({
    required this.spanId,
    required this.spanName,
    required this.stats,
  });

  final int spanId;
  final String spanName;
  final CounterStats stats;
}

class CounterStats {
  CounterStats._(this.values)
      : count = values.length,
        latest = values.isEmpty ? 0 : values.last,
        min = values.isEmpty ? 0 : values.reduce(math.min),
        max = values.isEmpty ? 0 : values.reduce(math.max);

  factory CounterStats.fromEvents(Iterable<TraceEvent> events) {
    return CounterStats._([
      for (final event in events)
        if (event.args.isNotEmpty) event.args.first,
    ]);
  }

  final List<int> values;
  final int count;
  final int latest;
  final int min;
  final int max;
}

extension TraceSpanQueries on Iterable<TraceSpan> {
  Iterable<TraceSpan> ofType(int spanId) =>
      where((span) => span.spanId == spanId);

  Iterable<TraceSpan> during(TimeRange range) => where((span) {
        final end = span.endNs ?? span.startNs;
        return range.overlaps(span.startNs, end);
      });

  DurationStats durationStats() => DurationStats.fromNs(
        where((span) => span.isComplete).map((span) => span.durationNs),
      );

  List<SpanGroupStats> groupStatsByType({
    Map<int, String> spanNames = kSpanNames,
  }) {
    final groups = <int, List<int>>{};
    for (final span in where((span) => span.isComplete)) {
      groups.putIfAbsent(span.spanId, () => <int>[]).add(span.durationNs);
    }
    return [
      for (final entry in groups.entries)
        SpanGroupStats(
          spanId: entry.key,
          spanName: spanNames[entry.key] ?? hexSpanId(entry.key),
          stats: DurationStats.fromNs(entry.value),
        ),
    ];
  }
}

extension TraceCounterQueries on Iterable<TraceEvent> {
  Iterable<TraceEvent> ofCounterType(int spanId) =>
      where((event) => event.isCounter && event.spanId == spanId);

  List<CounterGroupStats> groupCounterStatsByType({
    Map<int, String> spanNames = kSpanNames,
  }) {
    final groups = <int, List<TraceEvent>>{};
    for (final event in where((event) => event.isCounter)) {
      groups.putIfAbsent(event.spanId, () => <TraceEvent>[]).add(event);
    }
    return [
      for (final entry in groups.entries)
        CounterGroupStats(
          spanId: entry.key,
          spanName: spanNames[entry.key] ?? hexSpanId(entry.key),
          stats: CounterStats.fromEvents(entry.value),
        ),
    ];
  }
}

Map<int, String> _readSpanNames(
  Iterable<TraceEvent> events,
  Map<int, String> strings,
) {
  final result = <int, String>{...kSpanNames};
  for (final event in events) {
    if (!event.isMetadata || event.spanId != _metadataKindAddSpan) {
      continue;
    }
    if (event.args.length < 2) continue;
    final spanId = event.args[0];
    final name = strings[event.args[1]];
    if (name == null || name.isEmpty) continue;
    result[spanId] = name;
  }
  return result;
}

String hexSpanId(int spanId) => '0x${spanId.toRadixString(16).padLeft(4, '0')}';

String _markdownCell(String value) => value.replaceAll('|', '\\|');

String formatDurationNs(int ns) {
  if (ns < 1000) return '${ns}ns';
  if (ns < 1000 * 1000) return '${_trim(ns / 1000)}us';
  if (ns < 1000 * 1000 * 1000) return '${_trim(ns / (1000 * 1000))}ms';
  return '${_trim(ns / (1000 * 1000 * 1000))}s';
}

String _trim(double value) {
  if (value >= 100) return value.toStringAsFixed(0);
  if (value >= 10) return value.toStringAsFixed(1);
  return value.toStringAsFixed(2);
}

Map<int, String> _readStringPool(ByteData view, TraceHeader header) {
  final result = <int, String>{};
  var pos = 0;
  final limit = math.min(header.stringPoolHead, header.stringPoolSize);
  while (pos + 4 <= limit) {
    final len = view.getUint32(header.stringPoolOffset + pos, Endian.little);
    final start = header.stringPoolOffset + pos + 4;
    final end = start + len;
    if (len < 0 || pos + 4 + len > limit || end > view.lengthInBytes) break;
    result[pos] = String.fromCharCodes(
      Uint8List.sublistView(view.buffer.asUint8List(), start, end),
    );
    pos += 4 + len;
  }
  return result;
}

List<TraceTrack> _readRegistry(
  ByteData view,
  TraceHeader header,
  Map<int, String> strings,
) {
  final result = <TraceTrack>[];
  for (var i = 0; i < header.maxProducers; i++) {
    final slot = header.producerRegistryOffset + i * kRegistrySlotSize;
    if (slot + kRegistrySlotSize > view.lengthInBytes) break;
    final state = view.getUint8(slot);
    if (state == 0) continue;
    final ringOffset =
        header.producerRingOffset + i * header.perProducerRingSize;
    final dropped = ringOffset + 24 <= view.lengthInBytes
        ? view.getUint64(ringOffset + 16, Endian.little)
        : 0;
    final processStringId = view.getUint32(slot + 4, Endian.little);
    final threadStringId = view.getUint32(slot + 8, Endian.little);
    final metadataStringId = view.getUint32(slot + 12, Endian.little);
    result.add(
      TraceTrack(
        id: i,
        state: state,
        kind: view.getUint8(slot + 1),
        processStringId: processStringId,
        threadStringId: threadStringId,
        metadataStringId: metadataStringId,
        processName: strings[processStringId],
        threadName: strings[threadStringId],
        droppedEvents: dropped,
      ),
    );
  }
  return result;
}

_DecodedRing _drainRing(ByteData view, TraceHeader header, TraceTrack track) {
  final ringOffset =
      header.producerRingOffset + track.id * header.perProducerRingSize;
  final head = view.getUint64(ringOffset, Endian.little);
  final dropped = view.getUint64(ringOffset + 16, Endian.little);
  final sizeWords = view.getUint32(ringOffset + 24, Endian.little);
  final mask = view.getUint32(ringOffset + 28, Endian.little);
  final dataOffset = ringOffset + kRingHeaderSize;

  final events = <TraceEvent>[];
  final spans = <TraceSpan>[];
  final open = <String, List<TraceEvent>>{};
  var unmatchedEnds = 0;
  var pos = 0;

  while (pos < head) {
    final headerWord = _ringWord(view, dataOffset, mask, pos);
    if (headerWord == 0) break;

    final tag = (headerWord >> 56) & 0xFF;
    final eventTrack = (headerWord >> 48) & 0xFF;
    final spanId = (headerWord >> 32) & 0xFFFF;
    final argCount = (headerWord >> 24) & 0xFF;
    final flags = (headerWord >> 16) & 0xFF;
    final hasCorrelation = (flags & traceFlagHasCorrelation) != 0;
    final timestampNs = _ringWord(view, dataOffset, mask, pos + 1);
    final correlationId =
        hasCorrelation ? _ringWord(view, dataOffset, mask, pos + 2) : null;
    final argsStart = pos + 2 + (hasCorrelation ? 1 : 0);
    final args = <int>[];
    for (var i = 0; i < argCount; i++) {
      args.add(_ringWord(view, dataOffset, mask, argsStart + i));
    }

    final event = TraceEvent(
      sequence: pos,
      tag: tag,
      trackId: eventTrack,
      spanId: spanId,
      timestampNs: timestampNs,
      args: List.unmodifiable(args),
      correlationId: correlationId,
    );
    events.add(event);

    if (event.isBegin) {
      open.putIfAbsent(_pairingKey(event), () => <TraceEvent>[]).add(event);
    } else if (event.isEnd) {
      final stack = open[_pairingKey(event)];
      if (stack == null || stack.isEmpty) {
        unmatchedEnds++;
      } else {
        final begin = stack.removeLast();
        spans.add(TraceSpan(
            trackId: begin.trackId,
            spanId: event.spanId,
            begin: begin,
            end: event));
      }
    } else if (event.isInstant) {
      spans.add(TraceSpan(
          trackId: event.trackId,
          spanId: event.spanId,
          begin: event,
          end: event));
    }

    pos += 2 + argCount + (hasCorrelation ? 1 : 0);
    if (sizeWords > 0 && pos > sizeWords * 4) break;
  }

  for (final stack in open.values) {
    for (final begin in stack) {
      spans.add(TraceSpan(
          trackId: begin.trackId,
          spanId: begin.spanId,
          begin: begin,
          end: null));
    }
  }

  return _DecodedRing(
    events: events,
    spans: spans,
    droppedEvents: dropped,
    unmatchedEndEvents: unmatchedEnds,
  );
}

String _pairingKey(TraceEvent event) {
  if (event.isAsyncBegin || event.isAsyncEnd) {
    return 'async:${event.spanId}:${event.correlationId ?? 0}';
  }
  return 'sync:${event.trackId}:${event.spanId}:${event.correlationId ?? 0}';
}

_DecodedAsyncSpans _pairAsyncSpans(List<TraceEvent> events) {
  final spans = <TraceSpan>[];
  final open = <String, List<TraceEvent>>{};
  var unmatchedEnds = 0;

  for (final event in events) {
    if (event.isAsyncBegin) {
      open.putIfAbsent(_pairingKey(event), () => <TraceEvent>[]).add(event);
    } else if (event.isAsyncEnd) {
      final stack = open[_pairingKey(event)];
      if (stack == null || stack.isEmpty) {
        unmatchedEnds++;
      } else {
        final begin = stack.removeLast();
        spans.add(
          TraceSpan(
            trackId: begin.trackId,
            spanId: event.spanId,
            begin: begin,
            end: event,
          ),
        );
      }
    }
  }

  for (final stack in open.values) {
    for (final begin in stack) {
      spans.add(
        TraceSpan(
          trackId: begin.trackId,
          spanId: begin.spanId,
          begin: begin,
          end: null,
        ),
      );
    }
  }

  return _DecodedAsyncSpans(
    spans: spans,
    unmatchedEndEvents: unmatchedEnds,
  );
}

int _ringWord(ByteData view, int dataOffset, int mask, int pos) =>
    view.getUint64(dataOffset + (pos & mask) * 8, Endian.little);

class _DecodedRing {
  _DecodedRing({
    required this.events,
    required this.spans,
    required this.droppedEvents,
    required this.unmatchedEndEvents,
  });

  final List<TraceEvent> events;
  final List<TraceSpan> spans;
  final int droppedEvents;
  final int unmatchedEndEvents;
}

class _DecodedAsyncSpans {
  _DecodedAsyncSpans({
    required this.spans,
    required this.unmatchedEndEvents,
  });

  final List<TraceSpan> spans;
  final int unmatchedEndEvents;
}
