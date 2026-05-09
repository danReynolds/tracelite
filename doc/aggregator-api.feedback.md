# Feedback: Aggregator API

Reviewed: `aggregator-api.md`

## TLDR

The API reads well and targets the right users: benchmark authors, CLI reports, and visualizer panels. The main risk is that the performance contract assumes data structures the format does not yet provide. Range-overlap queries, incremental percentiles, diff significance, and stack attribution need more precise semantics before the API becomes a public contract.

Recommended direction: keep the fluent Dart API, but separate "exact query semantics" from "accelerated approximations" and make the required indices explicit.

## Blockers

### 1. Indexing and memory claims conflict

The loading section says `Trace.load` builds several indices immediately. The performance section says indices are built lazily and are only about 3x the dictionary size. A timestamp index, per-track event index, and per-correlation event index are all event-cardinality data structures; they will scale with events, not dictionaries.

Define the real load modes:

- `metadataOnly`
- `indexedEvents`
- `indexedSpans`
- `visualizerReady`

Then document expected memory as bytes per event/span/chain.

### 2. `during(range)` needs interval indexing, not just timestamp indexing

A binary-searchable event timestamp list is not enough for "spans overlapping a range." A span that starts before the visible window and ends inside or after it must still be returned. The API needs an interval tree, segment tree, sorted start/end arrays, or a clearly documented fallback scan.

This matters because `during(range)` is the core visualizer operation.

### 3. Incremental `LiveQuery` and t-digest do not compose exactly

The doc says dragging by 10% reuses 90% of work and that t-digest is the default percentile structure. T-digests are merge-friendly, but not naturally subtractable for exact sliding-window removal. If the range shrinks or pans, cached percentile state cannot simply remove old spans without either approximation drift or a different data structure.

Options:

- Use exact sorted/windowed values for small visible ranges.
- Use segment-tree summaries for fixed time buckets and accept approximate percentiles.
- Use histogram buckets where add/remove is exact at bucket granularity.

The API should expose whether a result is exact or approximate.

### 4. Diff significance needs a clear experimental unit

Running a Mann-Whitney U test over thousands of spans inside one trace is usually pseudo-replication; events from one run are not independent benchmark samples. The safer default is to compare per-repetition summary metrics, then optionally drill into within-run distributions as descriptive evidence.

Define whether diff significance is computed over:

- repetitions,
- chains,
- individual spans,
- bootstrapped windows,
- or a user-selected unit.

The default p-value/effect-size policy should not land before that.

### 5. Stack samples are CPU attribution, not wall attribution

The doc describes stack samples as wall-time attribution by package. Dart's CPU profiler samples executing threads and stack state; it is excellent for CPU attribution, but waiting, blocked native calls, and off-thread SQLite time are already represented better by spans. Call this `cpuAttribution` unless the sampler explicitly samples wall states too.

## Important clarifications

- `Span.args` currently returns args from BEGIN, but the format/registry examples put return codes on END. The aggregator should expose `beginArgs`, `endArgs`, and perhaps a merged convenience view only when schemas allow it.
- `trace.spans.ofType(t)` is not `O(1)` as a full operation. The lookup is `O(1)`; iterating results is `O(k)`.
- `spans.during(range).ofCategory(...)` should document whether selector reordering preserves stable output order.
- `chain.wallByTrack` can sum to more than chain duration across concurrent tracks. That is fine, but the report should label it "track wall sum" rather than implying exclusive total wall.
- `duration > chain.duration * 0.3` does not compile with Dart `Duration` unless tracelite defines numeric extension operators. Examples should use real APIs.
- `Map<int correlation_id, List<int> eventIndex>` can be expensive for traces with many short chains. Consider a sorted correlation column plus offset table.
- `Trace.openStream` can expose raw events early, but `trace.spans`, `trace.chains`, parent/children, and diff require pairing and final dictionaries. Define which APIs are available before EOF.
- User span diffing must match by stable name/schema, not ID, because user IDs are per-trace.
- The claim "zero-copy view objects" should be softened unless the Dart implementation is cursor-based. Allocating `Event`/`Span` wrappers per iteration is easy to do accidentally.

## External checks

- Dart VM CPU profiling is sampling-based and collects stack state for interrupted VM-managed threads: https://dart.dev/blog/dart-devtools-analyzing-application-performance-with-the-cpu-profiler
- VM service streams expose `Profiler`, `GC`, and `Timeline` events, which is a plausible ingestion path but not the same thing as tracelite's persistent trace format: https://api.flutter.dev/flutter/vm_service/VmService/streamListen.html
- Dart `SendPort.send` can copy the transitive object graph with linear cost, which matters for visualizer worker APIs that pass trace objects around: https://api.dart.dev/dart-isolate/SendPort/send.html

## Suggested next edits

1. Add a "Load modes and indices" table with bytes-per-event estimates.
2. Specify the interval index used for `spans.during`.
3. Mark percentile/live-query outputs as exact or approximate.
4. Define diff significance over repetitions by default.
5. Rename stack sample wall attribution to CPU attribution unless wall sampling is added.
