# tracelite

> **Status:** Prototype implementation in progress. The native runtime, Dart recorder, span generator, macOS SQLite shim, aggregator/report CLI, and peer harness are working. `sqlite3`, `drift`, `sqlite_async`, and a trace-enabled local `resqlite` build all produce SQLite traces for baseline plus initial resqlite-derived feed-paging, sync-burst, chat-sim, and large-working-set scenarios. Capability-aware reactive and diagnostic scenarios now report unsupported peers explicitly instead of forcing every library into the same feature model.

Cross-library SQLite profiling and tracing for the Dart ecosystem. Point it at any Dart program that uses SQLite — Resqlite, drift, sqlite_async, the raw `sqlite3` package, anything — and see the full call timeline: into FFI, through SQLite's C internals, and back. On a single shared clock, with no instrumentation in the libraries being measured.

## What it is

tracelite is a profiling system designed around three observations about Dart's SQLite ecosystem:

1. **Every Dart SQLite library FFI-links to the same SQLite C library.** That FFI boundary is shared infrastructure. Instrumenting it once captures every library that uses it — no library-specific code, no coordination, no maintenance forks.

2. **Wall-time numbers without per-call attribution are hard to learn from.** "Library A is 1.5× faster than Library B" is a finding without an explanation. "Library A avoids 999 prepare/finalize cycles per workload run" is a finding *with* a fix.

3. **Profiling clutter accumulates in source code over time.** If we get the design right, every future metric is harness-only work. Source code stays clean; new measurements never edit hot paths.

## How it works

```
┌──────────────────────────────────────────────────────────────────────────┐
│                       tracelite package                                   │
├──────────────────────────────────────────────────────────────────────────┤
│   ┌─────────────────┐  ┌─────────────────┐  ┌────────────────┐          │
│   │  C SHIM         │  │  DART RECORDER  │  │  STACK SAMPLER │          │
│   │  drop-in        │  │  one-line       │  │  per-package   │          │
│   │  libsqlite3 ABI │  │  trace() calls  │  │  attribution   │          │
│   └────────┬────────┘  └────────┬────────┘  └───────┬────────┘          │
│            └────────────────────┼────────────────────┘                   │
│                                 ▼                                         │
│                ┌────────────────────────────┐                             │
│                │    SHARED-MEMORY RING      │                             │
│                │    monotonic clock         │                             │
│                │    lock-free append        │                             │
│                └────────────┬───────────────┘                             │
│                             ▼                                             │
│                ┌────────────────────────────┐                             │
│                │   AGGREGATOR (pure Dart)   │                             │
│                │   spans, joins, stats      │                             │
│                └────────────┬───────────────┘                             │
│                             ▼                                             │
│       ┌──────────┬──────────┼──────────┬───────────┐                      │
│       ▼          ▼          ▼          ▼           ▼                      │
│    JSONL     Markdown   Diff/CI    Visualizer   Perfetto                  │
│    on disk    report     check     (Flutter web) export                   │
└──────────────────────────────────────────────────────────────────────────┘
```

The C shim is a drop-in `libsqlite3` replacement that wraps SQLite C API calls with timing and emits to a shared-memory ring buffer. The current macOS prototype loads the shim through sqlite3 native-asset configuration, with the shim re-exporting the real SQLite library and overriding traced symbols. For `resqlite`, which compiles SQLite into `libresqlite`, the local trace build compiles sqlite3mc under private symbols and embeds the same wrappers inside that native asset. Linux `LD_PRELOAD` and Windows substitution are planned but not yet validated. Peer libraries don't know they're being traced — they FFI into "SQLite" and the shim is what answers.

Dart code can also emit events for its own boundaries via `TraceRecorder`. C and Dart events use the same monotonic clock, so they merge by timestamp into one unified timeline. Libraries can register lightweight vocabularies of span/counter/gauge names; `package:tracelite/resqlite.dart` provides the resqlite vocabulary plus helpers for decode metrics, stream invalidation metrics, dispatcher pressure, and diagnostics so resqlite can emit semantic facts without owning report or metadata plumbing. Optional stack sampling adds per-Dart-package attribution on top.

The aggregator is pure Dart and operates on the resulting event stream. Every metric — counts, durations, percentiles, histograms, per-library splits, regression diffs — is a query, not source instrumentation. The current CLI can emit markdown reports, run repeated peer comparisons, write JSON artifacts, diff those artifacts with confidence-interval plus non-parametric repetition gates, turn baseline/candidate artifacts into accepted/rejected/inconclusive decisions, run CI/production benchmark suites, and calibrate recorder overhead.

The peer harness has a narrow common SQL lane and optional capability lanes. Shared SQL scenarios run across all peers; reactive scenarios currently run on `sqlite_async` and `resqlite`; the resqlite diagnostics scenario records semantic gauges from `Database.diagnostics()`. Peers that do not support a scenario are marked `unsupported` in the report and JSON artifact.

## What it makes possible

- **See into SQLite from Dart.** "What's the p99 of `sqlite3_step` during the executeBatch interval, broken down by parameter count?" answerable without modifying SQLite or any peer library.
- **Apples-to-apples library comparison.** Same workload, same shim, same format. drift and Resqlite stop being a wall-time horse race; they become a structural comparison ("drift prepares per query; Resqlite caches statements").
- **Causal chains across isolates.** A request's full lifecycle — main isolate → writer isolate → SQLite C → response → main isolate — observable as one chain.
- **Tail-latency distributions, not just medians.** p99, histogram, distribution shape; effect-size and significance testing built in.
- **Cross-commit regression detection.** `tracelite diff --baseline=base.json --candidate=change.json` explains deltas, and `tracelite decision --baseline=base.json --candidate=change.json` turns those artifacts into a trace-health, primary-metric, noise, significance, and guardrail decision.

## Status

The design corpus is in `doc/`, and the implementation is present in `native/`, `tools/`, `lib/src/`, `bin/`, `example/`, and `test/`. `PLAN.md` is the canonical implementation and status tracker.

| Spec | Status | What it defines |
|---|---|---|
| [Trace format](doc/format-spec.md) | Draft v0.1 | Wire format, file format, JSONL archival, tags, tracks, spans, args, correlation IDs |
| [Aggregator API](doc/aggregator-api.md) | Draft v0.1 | Loading, selection, filtering, aggregation, grouping, chains, attribution, diff, live queries |
| [Visualizer binding](doc/visualizer-binding.md) | Draft v0.1 | Probes, scope, derivation, frame coalescing, isolate offload, Flutter widget integration |
| [Runtime mmap protocol](doc/runtime-protocol.md) | Draft v0.1 | Cross-language shared buffer, slot reservation, drainage, crash safety, lifecycle |
| [Span ID registry](doc/span-registry.md) | Draft v0.2 | Reserved span IDs across SQLite C, Dart recorder, FFI bridge, user ranges |
| [Peer interface contract](doc/peer-interface-contract.md) | Draft v0.1 | The `SqliteInterface` API, scenarios, adapters, fairness rules, standard scenario library |

The latest production benchmark replacement audit is in
[`doc/production-benchmark-readiness.md`](doc/production-benchmark-readiness.md).
The decision standard for accepting, rejecting, or marking experiments
inconclusive is in
[`doc/profiling-decision-standard.md`](doc/profiling-decision-standard.md).
The resqlite deletion/parity gate is tracked in
[`doc/resqlite-replacement-checklist.md`](doc/resqlite-replacement-checklist.md).

## Non-goals

- **Replacement for Dart DevTools.** DevTools is the right tool for interactive debugging during development. tracelite is for synthetic-benchmark and offline-analysis workflows.
- **Production telemetry.** This is for synthetic workloads and dev-time profiling, not live observability.
- **Tied to any single library.** Resqlite is one peer interface among several; this package treats all libraries equally and isn't privileged toward any of them.

## License

MIT. See [LICENSE](LICENSE).

## Contributing

This is early-stage. Feedback on the design specs is the most valuable contribution right now. Open an issue with concerns about the format, the API, or any design decision that seems load-bearing.
