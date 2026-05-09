# tracelite — Aggregator API

**Status:** Draft v0.1
**Companion to:** `format-spec.md`
**Audience:** Design review for the cross-library SQLite tracing package

The format spec defines what's *in* a trace. This doc defines how programs *query* one. Every consumer — the CLI's `tracelite report` and `tracelite diff`, the visualizer's live aggregation panels, scenario benchmarks, user analyses — uses this API.

The API has to satisfy six properties:

| Property | Why |
|---|---|
| **One-liner common queries** | "p99 of `sqlite3_step` during the executeBatch interval" should not require scaffolding. |
| **Composable** | Filter, group, aggregate compose the way SQL / LINQ / Pandas do. |
| **Lazy by default** | A trace can have millions of events. Pulling a percentile shouldn't materialize every span. |
| **Live-friendly** | Re-running a query against a *visible time window* (visualizer dragging the scrub bar) is the primary interactive workload. Sub-millisecond requery is the goal. |
| **Idiomatic Dart** | No stringly-typed query DSL. Type checker helps; arg types flow from span schemas. |
| **Extensible** | Custom aggregators, custom filters, custom attribution policies. |

## Outline

1. [Conceptual model](#1-conceptual-model)
2. [Loading a trace](#2-loading-a-trace)
3. [Core types](#3-core-types)
4. [Selection and filtering](#4-selection-and-filtering)
5. [Aggregation primitives](#5-aggregation-primitives)
6. [Grouping](#6-grouping)
7. [Chains and correlation](#7-chains-and-correlation)
8. [Attribution (stack samples)](#8-attribution-stack-samples)
9. [Diff](#9-diff)
10. [Live queries (visualizer integration)](#10-live-queries-visualizer-integration)
11. [Custom aggregators](#11-custom-aggregators)
12. [Worked examples](#12-worked-examples)
13. [Performance contract](#13-performance-contract)

---

## 1. Conceptual model

A loaded trace exposes four iterable surfaces:

| Surface | What it is | Cardinality |
|---|---|---|
| `trace.events` | Every event, in timestamp order | Largest — millions for long traces |
| `trace.spans` | Paired `BEGIN`/`END` intervals + standalone `INSTANT`s | ~half of events |
| `trace.chains` | Events grouped by correlation ID | One per logical request |
| `trace.samples` | Stack samples (if a sampler ran) | Sample-rate dependent |

These are the four fundamental data shapes. Every higher-level operation is a transformation over them.

The aggregator is read-only — it never mutates the loaded trace. All operations return new lazy iterables or computed values.

## 2. Loading a trace

A trace is loaded in one of four explicit *modes* that trade off load time, memory footprint, and query support. Choose the smallest mode that supports the queries the consumer will run.

```dart
// Binary on-disk format
final trace = await Trace.load('exp-127.tlt', mode: LoadMode.indexedSpans);
```

### Load modes

| Mode | What's loaded | Approx memory | Queries supported |
|---|---|---|---|
| `metadataOnly` | Header, dictionaries (tracks, spans, strings), footer | ~tens of KB | Trace metadata: track names, span vocabulary, total counts. No events. |
| `indexedEvents` | Above + per-event header/timestamp index | ~24 bytes/event | All event-level queries: `events.where(...)`, `events.ofTag(...)`, range scans. |
| `indexedSpans` | Above + paired BEGIN/END spans + interval index for `during` | ~48 bytes/event | All span queries: `spans.during(...)`, `spans.ofType(...)`, nesting/depth. **Default for most consumers.** |
| `visualizerReady` | Above + correlation-id chain index + concurrent-span sweep index | ~64 bytes/event | All chain queries: `chains.where(...)`, `chain.byTrack`, `span.concurrent`. |

A 1M-event trace at `indexedSpans` is ~48 MB resident. At `visualizerReady`, ~64 MB. Audit-style traces (~2K events) are negligible at any mode.

```dart
// Lossless JSONL roundtrip — same mode parameter applies
final trace = await Trace.loadJsonl('exp-127.jsonl', mode: LoadMode.indexedSpans);

// In-memory (e.g., from a live drainage)
final trace = Trace.fromBytes(rawBytes, mode: LoadMode.indexedSpans);

// Streaming load (for very large traces; events available before full file read).
// Streaming load is metadataOnly + indexedEvents only; spans, chains, and
// concurrent queries require the full event stream and are not available
// until the stream completes.
final trace = await Trace.openStream('big.tlt');
await for (final batch in trace.streamEvents()) { ... }
await trace.close();  // upgrades to indexedSpans if requested via openStream's mode arg
```

### Indices built per mode

- `Map<SpanType, List<int>>` (event positions) — `ofType` queries; built at `indexedEvents` and above.
- `Map<TrackId, List<int>>` — per-track scans.
- `Uint64List` of event timestamps in monotonic order — for `events.during(range)` (binary search).
- **Interval tree of (start, end) intervals** for `spans.during(range)` — built at `indexedSpans` and above. A spanning span (one that starts before the range and ends after it) is correctly returned by an interval tree but missed by binary search on event timestamps alone. This is the right-shape index for the visualizer's primary operation.
- `Map<CorrelationId, List<EventPosition>>` — built at `visualizerReady`. Stored as a sorted run with offset table to avoid a Map per chain when many chains are short-lived.

`ofType(t)` is `O(1)` for the index lookup, `O(k)` for iterating the result. Documented complexities below assume the appropriate mode was loaded.

## 3. Core types

### `Event`

A single record from the wire-format event stream.

```dart
abstract class Event {
  Track get track;
  SpanType get spanType;
  Duration get timestamp;        // relative to trace start
  Tag get tag;                   // BEGIN | END | INSTANT | ASYNC_BEGIN | ASYNC_END | COUNTER | METADATA | FLOW
  int? get correlationId;
  Args get args;
}
```

Events are immutable views over the underlying packed bytes; iterating doesn't allocate per-event for typical access patterns.

### `Span`

A *named interval* — either a paired `BEGIN`/`END` on a single track (sync span) or a paired `ASYNC_BEGIN`/`ASYNC_END` linked by correlation ID across tracks (async span).

```dart
abstract class Span {
  Track get track;
  SpanType get spanType;
  String get name;               // shortcut for spanType.name
  SpanCategory get category;     // shortcut for spanType.category
  bool get isAsync;              // true if from ASYNC_BEGIN/ASYNC_END

  Duration get start;            // start time, relative to trace start
  Duration get end;
  Duration get duration;
  TimeRange get range;           // (start, end)

  int? get correlationId;        // present for async spans

  // Args are split by event phase, matching the format-spec span schema:
  //   beginArgs   — args observed at BEGIN  / ASYNC_BEGIN
  //   endArgs     — args observed at END    / ASYNC_END
  //   instantArgs — args from an INSTANT (only set for instant spans)
  //
  // For typical SQLite-call spans, inputs (sql, stmt, idx, len) are in
  // beginArgs; outputs (rc, stmt_out, blob_out) are in endArgs. Reading
  // the wrong phase returns an empty Args.
  Args get beginArgs;
  Args get endArgs;
  Args get instantArgs;

  /// Convenience: a merged read-only view of beginArgs + endArgs by name.
  /// Only well-defined when begin_args and end_args names don't collide
  /// (the generator enforces this for built-in spans). For collisions,
  /// reach for beginArgs / endArgs explicitly.
  Args get args;

  // Nesting (sync spans on same track):
  Span? get parent;
  List<Span> get children;
  int get depth;

  // Concurrent spans on *other* tracks during this span's interval:
  Iterable<Span> get concurrent;

  // The chain this span belongs to (if it has a correlation ID):
  Chain? get chain;
}
```

Sync spans use stack discipline within a track, so `parent` and `children` are unambiguous. Async spans don't nest by default; their relationship is captured by `chain`.

### `Chain`

A causal chain — every event sharing a correlation ID, ordered by timestamp, possibly spanning multiple tracks.

```dart
abstract class Chain {
  int get correlationId;

  Iterable<Event> get events;
  Iterable<Span> get spans;

  Span get firstSpan;
  Span get lastSpan;
  Duration get start;
  Duration get end;
  Duration get duration;         // end - start

  // Spans grouped by track in chronological order
  Map<Track, List<Span>> get byTrack;

  // Sum of root-span durations on each track that participated in the
  // chain. NOT a partition of `chain.duration`: when a chain has spans
  // executing concurrently on multiple tracks (e.g., stream re-queries
  // fanning out to readers in parallel with the writer continuing),
  // values across tracks can sum to more than `chain.duration`.
  // Display this as "track-wall sum" rather than implying exclusive
  // total time.
  Map<Track, Duration> get trackWallSum;

  // Wall partitioned across tracks WITHOUT double-counting concurrent
  // intervals. Returns the *single-active* wall per track, derived by
  // sweeping the chain's interval and assigning each ns of wall to
  // exactly one track (the writer if active, else a reader, etc.; the
  // priority is tracker-defined). Sums to ≤ chain.duration.
  Map<Track, Duration> get exclusiveWallByTrack;
}
```

Chains answer "where did this one logical request's time go?" — the question that motivated correlation IDs in the first place.

### `Args`

Schema-aware view over an event's arg words.

```dart
abstract class Args {
  bool get isEmpty;
  int get length;

  // By position
  Object? at(int index);

  // By name (resolved against the span's schema)
  Object? operator [](String name);

  // Type-safe getters; throw if type doesn't match
  int asInt(String name);
  int? asIntOrNull(String name);
  double asDouble(String name);
  String asString(String name);  // resolves string_id args automatically
  bool asBool(String name);
  Pointer asPointer(String name);
  Duration asDuration(String name);

  // Iterate over all args with their schema info
  Iterable<({String name, ArgType type, Object value})> get entries;
}
```

The aggregator joins `string_id` args to the trace's string pool transparently — you ask for a string, you get a string.

### Other types

```dart
class Track {
  int get id;
  String get name;               // typically thread name
  String get process;            // owning library/binary
  TrackKind get kind;            // isolate | c_thread | process | unknown
  Map<String, String> get metadata;
}

class SpanType {
  int get id;
  String get name;
  SpanCategory get category;     // sqlite_c | ffi | dart | user
  List<ArgSchema> get argSchema;

  // Stable global references for built-ins:
  static const SpanRef sqlite3Step = SpanRef(0x1004);
  // ...
}

class SpanRef {
  final int id;
  const SpanRef(this.id);
  bool matches(SpanType t) => t.id == id;
}

class TimeRange {
  Duration get start;
  Duration get end;
  Duration get duration;
  bool overlaps(TimeRange other);
  bool contains(Duration t);
}
```

## 4. Selection and filtering

The selection API is fluent. Operations are lazy and return new iterables; nothing materializes until you call a terminal operation (`stats()`, `count()`, `toList()`, etc.).

### Common selectors

```dart
// All spans of a particular type
trace.spans.ofType(BuiltinSpans.sqlite3Step)

// Spans of any of several types
trace.spans.ofTypes([BuiltinSpans.sqlite3Step, BuiltinSpans.sqlite3Reset])

// Spans by category
trace.spans.ofCategory(SpanCategory.sqlite_c)

// Spans by track
trace.spans.onTrack(track)
trace.spans.onTracks(tracks)

// Spans whose interval OVERLAPS the window (start < range.end &&
// end > range.start). A span starting before the window and ending
// inside it is returned. Backed by an interval tree at indexedSpans
// load mode and above; an `O(log N + k)` operation in k matches.
trace.spans.during(TimeRange(Duration(microseconds: 1000), Duration(microseconds: 5000)))

// Spans whose interval STRICTLY CONTAINS a timestamp.
trace.spans.containing(Duration(microseconds: 2500))

// Spans whose interval is FULLY CONTAINED within a window.
trace.spans.fullyWithin(range)

// Spans whose interval is FULLY OUTSIDE a window.
trace.spans.fullyOutside(range)

// Spans by duration
trace.spans.longerThan(Duration(microseconds: 100))
trace.spans.shorterThan(Duration(microseconds: 10))

// Spans by depth (nested spans on a track)
trace.spans.atDepth(0)         // root spans only
trace.spans.atDepthAtMost(2)

// By correlation ID
trace.spans.inChain(42)
```

### Generic predicates

```dart
trace.spans.where((s) => s.args.asInt('rc') != 0)
trace.spans.where((s) => s.duration > Duration(milliseconds: 1))
```

Generic `where` is unindexed — full scan. Use specific selectors when available; they hit indices.

### Composition

Selectors compose by chaining. They're commutative when possible (`ofType().during()` produces the same result as `during().ofType()`) and the implementation reorders to use the cheapest selector first.

```dart
final result = trace.spans
    .ofType(BuiltinSpans.sqlite3Step)
    .during(audit.range)
    .where((s) => s.args.asInt('rc') == 101)  // SQLITE_DONE
    .longerThan(Duration(microseconds: 50));
```

### Equivalent for events and chains

```dart
trace.events.ofTag(Tag.instant).ofType(SomeInstantSpan)
trace.chains.firstSpanOfType(BuiltinSpans.executeRequest).during(range)
```

## 5. Aggregation primitives

### `stats()`

Universal statistical summary of any numeric quantity.

```dart
final stepStats = trace.spans
    .ofType(BuiltinSpans.sqlite3Step)
    .durations
    .stats();

print(stepStats);
// Stats {
//   count: 500,
//   sum:   3.7ms,
//   mean:  7.4µs,
//   stdev: 1.8µs,
//   min:   5.2µs,
//   p50:   7.2µs,
//   p90:   8.4µs,
//   p99:   14.3µs,
//   p99.9: 28.1µs,
//   max:   142µs,
// }
```

`Stats` is type-aware: `.durations` produces `DurationStats` whose values are `Duration`s; `.bytes` (e.g., from `bytes_len` args) produces `ByteStats`; raw integers produce `IntStats`. Display formatters use the type to render correctly.

### Selecting a numeric quantity

```dart
// Span durations
spans.durations             // Iterable<Duration>

// Specific arg values
spans.argInt('rowCount')     // Iterable<int>
spans.argDouble('latencyMs') // Iterable<double>

// Counts
spans.count()                // int
spans.length                 // int (terminal; same as count)

// Sums
spans.totalDuration()        // Duration

// Custom projection
spans.map((s) => s.duration.inMicroseconds).stats()
```

### Percentiles

`Stats` includes p50, p90, p99 by default. For other percentiles:

```dart
spans.durations.percentile(99.9)
spans.durations.percentiles([50, 90, 95, 99, 99.9, 99.99])
```

#### Exact vs approximate

The aggregator distinguishes two percentile backends:

- **Exact** (`PercentileMode.exact`) — sorts the underlying values and reads off the percentile rank. `O(N log N)` initial cost; `O(log N)` for `add`/`remove`. Sub-millisecond for windows ≤ 100K spans.
- **Approximate** (`PercentileMode.tdigest`) — t-digest summary, ~1 KB memory regardless of N. `O(log B)` for `add` where B is the centroid count. **Cannot subtract values exactly** — t-digest is merge-friendly but not subtract-friendly.

Default: `exact` for windows ≤ 100K spans, `tdigest` above. Tunable via `Stats.config`.

Stats objects expose their backend explicitly:

```dart
final stats = spans.durations.stats();
print(stats.precision);  // PercentileMode.exact | PercentileMode.tdigest
print(stats.percentile(99));     // returned value
print(stats.precision == PercentileMode.exact);  // true if returned value is exact
```

Reports and diff outputs annotate approximate values with a `~` prefix (e.g., `p99 ~14.3µs`).

#### Why this matters for `LiveQuery`

Dragging the visualizer's scrub bar shrinks/grows the visible time range. A window-shrink event removes spans that fell outside the new range. With t-digest, "remove" isn't an exact operation — repeated shrinks accumulate approximation drift. The aggregator handles this by:

- Using **exact** percentiles for windows ≤ 100K spans (the typical visualizer case).
- Using **histogram-bucketed** windowing for larger windows: spans are bucketed into fixed-width time slices at load time; live percentiles compute over the bucket sums for the visible range. Bucket-granularity is exact within a bucket; intra-bucket precision degrades but is documented.
- Falling back to t-digest for "give me a one-shot percentile over this static set" cases where add-only semantics are fine.

The visualizer documents which mode is in use for any panel reading percentiles.

### Histograms

```dart
final hist = spans.durations.histogram(buckets: 32);
// Histogram { bucketWidth: 5µs, counts: [142, 89, 67, ...], total: 500 }

final fixed = spans.durations.histogram(bucketWidth: Duration(microseconds: 10));
// Histogram with deterministic bucket boundaries — useful for diff
```

Histograms render as ASCII in markdown reports and as inline sparklines in the visualizer.

### Distribution comparisons

```dart
final ks = stats1.kolmogorovSmirnov(stats2);  // are these the same distribution?
final cohenD = stats1.effectSize(stats2);      // standardized mean difference
```

Useful for diff: "p50 looks similar but the distribution shape differs" is a real signal that scalar comparisons hide.

## 6. Grouping

```dart
// Group by track
final byTrack = trace.spans
    .ofType(BuiltinSpans.sqlite3Step)
    .groupBy((s) => s.track);

// byTrack is Iterable<Group<Track, Span>>; aggregate per group:
for (final group in byTrack) {
  print('${group.key.name}: ${group.values.durations.stats()}');
}

// Or fluent: aggregate all groups into a Map
final stats = trace.spans
    .ofType(BuiltinSpans.sqlite3Step)
    .groupBy((s) => s.track)
    .aggregate((g) => g.durations.stats());
// Map<Track, DurationStats>
```

Common shorthands:

```dart
spans.byTrack    // groupBy(s => s.track)
spans.byType     // groupBy(s => s.spanType)
spans.byCategory // groupBy(s => s.category)
```

Multi-level grouping:

```dart
spans
    .groupBy((s) => s.track)
    .nestedGroupBy((s) => s.spanType)
    .aggregate((g) => g.durations.percentile(99));
// Map<Track, Map<SpanType, Duration>>
```

## 7. Chains and correlation

Chains answer "where did this request's time go?"

```dart
// All chains starting with an executeRequest span
final requests = trace.chains
    .where((c) => c.firstSpan.spanType == BuiltinSpans.executeRequest);

// Distribution of full request durations
print(requests.map((c) => c.duration).stats());
// DurationStats { p50: 65µs, p99: 850µs, ... }

// Per-track wall in each chain
for (final chain in requests.take(5)) {
  print('Request ${chain.correlationId}:');
  for (final entry in chain.trackWallSum.entries) {
    print('  ${entry.key.name}: ${entry.value}');
  }
}
// Request 42:
//   main:      1.2µs
//   writer:   11.3µs   ← writer-Dart wall
//   writer-c:  7.7µs   ← inside SQLite
```

Chain decomposition gives the answer exp 127 was reaching for: every request's full lifecycle, on every track, automatically.

### Common chain queries

```dart
// Slowest 10 requests
trace.chains.topByDuration(10)

// Requests where SQLite was the dominant cost.
//
// Dart's `Duration` doesn't support multiplication by a double. The
// aggregator exposes `Duration.scale(double)` as a convenience.
trace.chains.where((c) {
  final sqliteWall = c.spans.ofCategory(SpanCategory.sqlite_c).totalDuration();
  return sqliteWall > c.duration.scale(0.7);
})

// Requests spanning more than two tracks
trace.chains.where((c) => c.byTrack.length > 2)
```

## 8. CPU attribution (stack samples)

When the harness ran with the optional sampling profiler enabled, every Nth millisecond a stack sample was captured. Each sample is a list of stack frames; each frame's URI tells us which package owns the code.

**Stack samples capture CPU time, not wall time.** Dart's CPU profiler samples *executing* threads — when a thread is blocked on I/O, parked waiting for work, or otherwise off-CPU, no sample fires. The percentage of wall time a function appears in samples is the percentage of CPU time it consumed, not the wall it occupied. Span data (BEGIN/END pairs) already represents wall correctly; sampler data is the *other half* of the picture, attributed to which Dart code was *actively running*.

If you want "wall time spent in drift code", use spans. If you want "CPU time spent in drift code", use the sampler. Reports surface the distinction explicitly.

```dart
// All stack samples in the trace
trace.samples
// Iterable<StackSample>

class StackSample {
  Duration get timestamp;
  Track get track;
  List<Frame> get stack;
}

class Frame {
  String get function;
  String get uri;             // package:drift/src/runtime/query.dart
  int? get line;
  String get package;         // 'drift', 'resqlite', 'sqlite3', 'dart:core'
}
```

Built-in attribution policies:

```dart
// CPU attribution by package, leaf frame
final byPackage = trace.cpuAttribution.leafFrame.byPackage();
// Map<String, Duration> — drift: 45ms-of-CPU, sqlite3: 12ms-of-CPU, dart:core: 3ms-of-CPU

// CPU attribution by package, weighted by frame depth
final weighted = trace.cpuAttribution.weighted.byPackage();

// CPU attribution restricted to a time range
final duringWriter = trace.cpuAttribution
    .during(writer.handlerSpan.range)
    .byPackage();
```

The result type is `CpuAttribution`, not `WallAttribution`. Display formatters render values as e.g. `"45 ms (CPU)"` to keep the distinction obvious in reports.

### Future: wall-time CPU attribution

Some platforms (Linux `perf`, macOS Instruments) sample at a regular wall-time rate including idle threads, attributing CPU-idle wall to the function the idle thread would otherwise be running. tracelite v0.1 does not produce this; its sampler is the standard Dart CPU profiler. Future support for OS-level wall sampling would expose a `trace.wallAttribution` surface separate from `trace.cpuAttribution`.

### Custom policies

```dart
// Attribute samples by which library's span is currently active
final byActiveSpan = trace.cpuAttribution.byPolicy((sample) {
  final activeSpans = trace.spans.containing(sample.timestamp);
  return activeSpans.firstWhere((s) => s.category == SpanCategory.user)?.spanType.name ?? 'idle';
});
```

## 9. Diff

Compare two traces (or two *sets* of traces) for regression detection.

### Experimental units

Significance testing requires *independent* samples. Events from a single workload run are *not* independent — they share GC state, scheduler state, cache state, and a thousand other lurking variables. Running a stat test over thousands of within-run spans is **pseudo-replication**; the resulting p-values are misleadingly small.

Tracelite's diff defines four explicit experimental units, in order of statistical defensibility:

| Unit | Independence assumption | Use when |
|---|---|---|
| `repetition` | Each repetition (`Scenario.run()` invocation) is one independent sample. | Default for benchmark comparisons. The peer-interface contract runs each scenario N times for exactly this reason. |
| `chain` | Each correlation-linked request is independent. | Approximation: chains may share resources, but in chat-sim or feed-paging workloads chains are reasonably independent. |
| `span` | Each individual span is independent. | **Rarely correct.** Use only as descriptive evidence, not as inferential statistics. The diff tool warns when this unit is selected. |
| `bootstrap` | Resampled-with-replacement repetition windows. | When repetition count is small (n<5) and a non-parametric estimate is wanted. |

### Compare API

```dart
// Compare two single-run traces. Significance is computed over within-run
// spans (unit: span) but flagged as descriptive-only.
final diff = TraceDiff.compare(
  baseline: 'exp-126.tlt',
  change: 'exp-127.tlt',
);

// The defensible form: compare sets of traces (one per repetition).
// Significance computed over repetitions.
final diff = TraceDiff.compareRepetitions(
  baseline: ['baseline-rep1.tlt', 'baseline-rep2.tlt', /*...*/],
  change:   ['change-rep1.tlt',   'change-rep2.tlt',   /*...*/],
  unit:     DiffUnit.repetition,
);
```

```
SpanType / metric        │ baseline (n=5) │ change (n=5) │ Δ        │ significance
─────────────────────────┼────────────────┼──────────────┼──────────┼─────────────
sqlite3_step (count)     │ 500 ± 0        │ 500 ± 0      │ —        │ —
sqlite3_step (p50, ms)   │ 7.20 ± 0.31    │ 7.41 ± 0.28  │ +2.7%    │ ns
sqlite3_step (p99, ms)   │ 14.3 ± 1.2     │ 14.1 ± 1.0   │ −1.4%    │ ns
writer.handle (p99, ms)  │ 47 ± 4         │ 89 ± 6       │ +89.4%   │ ★★★ (n=5 reps)
```

Significance is computed via Mann-Whitney U (default) or two-sample t-test (when normality is asserted). For `unit: repetition` the test is over the n repetitions per side. `★`/`★★`/`★★★` correspond to p<0.05/0.01/0.001 with Bonferroni correction across the diff's reported metrics. `ns` means "not significant" at the configured threshold.

```dart
// Filter for actionable regressions
diff.regressions
    .where((d) => d.percentChange > 5 && d.significance >= Significance.high)
    .toMarkdown();
```

The diff API refuses to run with `unit: span` and a single-trace pair unless `--allow-pseudo-replication` is passed; that branch produces descriptive deltas without `significance` columns.

## 10. Live queries (visualizer integration)

The visualizer's aggregations panel re-runs queries every time the user drags the scrub bar. The API has to make this cheap.

```dart
// LiveQuery wraps a query against a moving time range
final live = LiveQuery(trace, (range) => trace.spans
    .during(range)
    .ofCategory(SpanCategory.sqlite_c)
    .byType
    .aggregate((g) => g.durations.stats()));

// Update the visible window; result is a new Map, computed in <1ms for typical traces
live.range = TimeRange(Duration(milliseconds: 10), Duration(milliseconds: 50));
final result = live.value;
```

`LiveQuery` caches partial results across overlapping ranges using interval-tree-backed indices. Dragging the scrub bar by 10% of trace width re-uses 90% of prior work.

For visualizer panels:

```dart
final panel = AggregationPanel(
  query: (range) => trace.spans.during(range).byCategory.aggregate(...),
  trace: trace,
);
panel.bind(timelineWidget.visibleRange);  // re-renders on range change
```

## 11. Custom aggregators

The built-in `stats()`, `histogram()`, etc. cover common cases. Custom aggregations slot in via `Aggregator<T, R>`:

```dart
class SqlGroupingAggregator extends Aggregator<Span, Map<String, DurationStats>> {
  @override
  Map<String, DurationStats> aggregate(Iterable<Span> spans) {
    final grouped = <String, List<Duration>>{};
    for (final s in spans) {
      final sql = s.args.asString('sql');
      grouped.putIfAbsent(sql, () => []).add(s.duration);
    }
    return grouped.map((k, v) => MapEntry(k, v.stats()));
  }
}

final result = trace.spans
    .ofType(BuiltinSpans.executeRequest)
    .applyAggregator(SqlGroupingAggregator());
```

Same shape composes with `groupBy` and `LiveQuery`.

## 12. Worked examples

These mirror the format spec's examples; this is what the analyses look like.

### Example A: Decomposing one write's wall

```dart
final trace = await Trace.load('one-write.tlt');
final chain = trace.chains.first;  // there's only one

print('Total wall: ${chain.duration}');
// Total wall: 11.58µs

print('By track:');
for (final entry in chain.trackWallSum.entries) {
  print('  ${entry.key.name}: ${entry.value}');
}
// By track:
//   main:      0.27µs
//   writer:    0.18µs
//   writer-c: 11.13µs

print('Inside SQLite (writer-c):');
for (final span in chain.spans.onTrack(writerC)) {
  print('  ${span.name}: ${span.duration}');
}
// Inside SQLite (writer-c):
//   sqlite3_prepare_v3:  3.06µs
//   sqlite3_bind_text:   0.09µs
//   sqlite3_bind_int:    0.04µs
//   sqlite3_step:        7.71µs
//   sqlite3_reset:       0.05µs
```

The `prepare_v3` taking 26% of one call is a directly visible fact — no inference, no aggregation, just reading the span tree.

### Example B: Cross-library comparison

```dart
final resqlite = await Trace.load('resqlite-batch.tlt');
final drift    = await Trace.load('drift-batch.tlt');

final diff = TraceDiff.compare(baseline: resqlite, change: drift);

print(diff.bySpanType.where((d) => d.span.category == SpanCategory.sqlite_c)
                     .toMarkdown());
```

| Span | resqlite | drift | Δ |
|---|---|---|---|
| `sqlite3_prepare_v3` (count) | 1 | 1000 | +99900% |
| `sqlite3_prepare_v3` (p50) | 28µs | 14µs | – |
| `sqlite3_step` (count) | 1000 | 1000 | — |
| `sqlite3_step` (p50) | 7.4µs | 7.6µs | +2.7% (ns) |
| `sqlite3_finalize` (count) | 1 | 1000 | +99900% |
| `ffi.entry` (count) | 4002 | 6000 | +49.9% |

The architectural difference (cached statements vs prepare-per-query) shows up *as* the trace diff. No inference required.

### Example C: Tail latency root-causing

```dart
final trace = await Trace.load('production-replay.tlt');

// All requests slower than p99
final p99 = trace.chains.map((c) => c.duration).percentile(99);
final slow = trace.chains.where((c) => c.duration > p99);

// What spans dominated the slow ones?
for (final chain in slow.take(10)) {
  final threshold = chain.duration.scale(0.3);
  final dominant = chain.spans.where((s) => s.duration > threshold);
  print('Request ${chain.correlationId} (${chain.duration}):');
  for (final s in dominant) {
    final pct = s.duration.inMicroseconds * 100 ~/ chain.duration.inMicroseconds;
    print('  ${s.name} on ${s.track.name}: ${s.duration} ($pct%)');
  }
}
```

Or, statistically:

```dart
// "Are slow requests slow because of GC pauses or because of SQLite?"
final tailReqs = trace.chains.topByDuration(50);
final gcDuringTail = tailReqs.expand((c) =>
    c.spans.where((s) => s.spanType == BuiltinSpans.dartGcMajor)
).toList();

print('GC events during tail-50: ${gcDuringTail.length}');
print('GC wall during tail-50: ${gcDuringTail.totalDuration()}');
```

### Example D: Per-package attribution during a window

```dart
final trace = await Trace.load('drift-vs-resqlite.tlt');

// During the executeBatch span, which Dart package owns the wall?
final batchSpan = trace.spans.ofType(BuiltinSpans.executeBatch).first;
final attribution = trace.attribution.during(batchSpan.range).byPackage();

print(attribution);
// {
//   drift: 28.4ms,
//   sqlite3: 11.2ms,
//   dart:core: 1.8ms,
//   <native> (libtracelited): 6.0ms
// }
```

This is the kind of insight that simply doesn't come out of accumulator-based profiling.

## 13. Performance contract

Each operation has a documented complexity:

| Operation | Complexity (selection / iteration) | Notes |
|---|---|---|
| `Trace.load(mode: indexedSpans)` | `O(events)` | Builds the indices for the chosen mode. |
| `spans.ofType(t)` | `O(1)` lookup, `O(k)` iterate | k = matching spans |
| `spans.during(range)` | `O(log E + k)` | Interval tree (indexedSpans+) returns spanning spans |
| `spans.containing(t)` | `O(log E + k)` | Same interval tree |
| `spans.where(predicate)` | `O(N)` | Linear scan, no index |
| `spans.stats()` | `O(N)` filter + `O(N log N)` exact percentile or `O(N log B)` t-digest | Backend documented in `Stats.precision` |
| `chains.where(...)` | `O(chains)` |  |
| `LiveQuery.range = ...` | `O(Δrange)` overlap; `O(N)` worst case | Cached partial sums for histogram-bucketed percentiles |

Memory:

- Trace dictionaries: small, fully resident (~tens of KB).
- Event stream: kept in mmap'd byte buffer. Most iterators are *cursor-style* — they reuse a single `EventView` object pointing at successive offsets, avoiding per-event allocation when the consumer doesn't retain references. Operations that need to retain (`toList`, `where(...).toList`) materialize wrappers on demand. The "zero-copy" benefit only holds if the consumer treats events as transient view objects; copying them out is `O(k)` allocations.
- Indices: built lazily on first use; ~3× the dictionary size.
- t-digest aggregations: ~1KB per active query.

For the audit-style traces that motivate this package (~2K events, ~100KB), all queries are interactively fast. For production-replay traces (~10M events, ~500MB), interactive queries against `LiveQuery` should still be sub-millisecond after warm-up; full-trace `stats()` is `O(N)` and limited by memory bandwidth.

## Open questions

1. **Lazy vs eager loading.** Defaults: lazy for events, eager for dictionaries. Should `Trace.load` accept an `eagerness` flag so visualizers can pre-compute everything?
2. **Sample-pull vs streaming attribution.** Stack samples can be tens of thousands per trace. Should attribution always materialize them or lazy-stream?
3. **Aggregator parallelism.** Some operations (`stats` over a large set) are embarrassingly parallel. Worth dispatching to isolates? Probably yes for traces > 1M events.
4. **Type-erased vs generic groups.** `Group<K, V>` with strong K type is ergonomic but loses some flexibility. Alternative: keep groups type-erased and let users cast.
5. **Diff significance defaults.** Default p-value threshold and effect-size minimum are policy choices that affect every diff report. Probably 0.05 / 5% as defaults, configurable.

## What's next

The format spec defines the trace; this doc defines the queries; the next contract is **the visualizer's data binding** — how a UI panel declares "I want this aggregation against the visible window" and how the aggregator delivers updates. That's the layer that ties the live query system to widget rendering. Worth designing before any UI code is written.

Want me to draft that next?
