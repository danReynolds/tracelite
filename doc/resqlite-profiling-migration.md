# resqlite profiling migration audit

Status: implementation-backed audit, 2026-05-09

## Summary judgement

tracelite should be a net win for resqlite's profiling goals. The package now
has the first required layer beyond the SQLite C shim: a Dart-side producer API
with spans, async correlation, counters, gauges, and metadata events.

The current prototype already solves the hard cross-library SQLite visibility
problem: sqlite3, drift, sqlite_async, and trace-enabled resqlite can all emit
SQLite call spans into the same trace format. That is better than resqlite's
current profile harness for ecosystem comparison because the measurement model
is shared instead of library-specific.

The current prototype does not yet replace resqlite's resqlite-specific
semantic counters by itself. The C shim can say where SQLite time went. The new
Dart recorder gives resqlite a place to emit stream invalidation cost,
reader-pool dispatch pressure, row materialization counts, WAL-sidecar size,
and per-operation caller intent. `package:tracelite/resqlite.dart` now wraps
the common counters and gauges in helper functions, but resqlite still needs to
call those hooks at its semantic boundaries.

## Current resqlite profiling inventory

| Surface | Main files | What it answers | tracelite disposition |
|---|---|---|---|
| Profile-mode gate | `lib/src/profile_mode.dart`, `benchmark/EXPERIMENTS.md` | Keeps instrumentation out of normal builds via `RESQLITE_PROFILE`. | Keep the same discipline. tracelite integration must be opt-in and tree-shakable or build-flag gated. |
| Profiled operation wrapper | `benchmark/profile/profiled_database.dart`, `benchmark/profile/profile_sample.dart` | Per-call wall time for `execute`, `executeBatch`, and `select`, with SQL, params, rows, batch size, and tag. | Replace with tracelite Dart operation spans plus trace report grouping. |
| Profile reports and A/B diff | `benchmark/run_profile.dart`, `benchmark/profile/profile_reporting.dart`, `benchmark/profile/diff.dart`, `benchmark/profile/diff_multirun.dart` | JSON/markdown output, RSS snapshots, diagnostics deltas, counter deltas, and experiment-vs-baseline comparison. | Replace most of this with tracelite report/diff once tracelite supports repetition-level comparison, metadata snapshots, and resqlite workload adapters. |
| Cross-isolate Timeline markers | `lib/src/writer/write_worker.dart`, `lib/src/reader/read_worker.dart` | Time spent handling writer and reader isolate messages. | Replace with tracelite spans emitted on the same native monotonic clock as SQLite spans. |
| Stream invalidation counters | `lib/src/stream_engine.dart`, `lib/src/profile_counters.dart` | Time spent invalidating streams and intersecting dependency sets. | Replace with Dart spans/counters: `resqlite.stream.invalidate`, `resqlite.stream.intersect_dependencies`, `intersection_entries`. |
| Reader-pool dispatch counters | `lib/src/reader/reader_pool.dart`, `lib/src/profile_counters.dart` | Whether reader dispatchers park, retry wakeups, or build queue pressure. | Replace with counter/gauge events: parked total, wake retry total, current parked, max parked. |
| Decode/materialization counters | `benchmark/profile/profiled_database.dart`, `lib/src/profile_counters.dart` | Rows and cells decoded into Dart maps. | Replace with counter events or result metadata on resqlite select spans. |
| SQLite internal diagnostics | `lib/src/diagnostics.dart`, `lib/src/database.dart`, `native/resqlite.c`, `benchmark/suites/sqlite_diagnostics.dart` | Page cache bytes, schema bytes, statement bytes, WAL bytes, reader busy state, stream length. | Keep the public API and native helper. Optionally import snapshots into tracelite as gauges/metadata. |
| Release benchmark timings | `benchmark/run_release.dart`, `benchmark/suites/*` | End-to-end benchmark comparisons across workload shapes. | Keep workloads. tracelite replaces profile instrumentation, not the benchmark workload definitions. |

## Why tracelite is better for the original goal

resqlite's current profile mode is useful but local: it wraps resqlite calls,
adds resqlite-specific counters, and reports resqlite-only traces. That is why
it has grown into production-adjacent code and benchmark glue.

tracelite improves the core design in four ways:

1. One shared SQLite trace layer covers sqlite3, drift, sqlite_async, and
   resqlite.
2. C and Dart events can use one monotonic clock, so caller spans, isolate
   message spans, and SQLite spans can be ordered without guessing.
3. The report/diff/visualizer stack can live in one package instead of inside
   resqlite.
4. resqlite can keep only small semantic instrumentation points, while the
   heavy trace storage, aggregation, reporting, and peer comparison logic moves
   out.

That is the win. It is not "zero resqlite instrumentation." It is "minimal
semantic hooks in resqlite, generic tracing machinery in tracelite."

## Required tracelite architecture changes

### 1. Dart producer API

Current state: implemented in `lib/src/producer.dart`.

Delivered:

- FFI bindings attach to `TRACELITE_REGION`.
- `TraceRecorder.attach(...)` registers a process/isolate-local producer.
- `trace(...)` emits synchronous span boundaries.
- `traceAsync(...)` emits async span boundaries with correlation IDs.
- `nowNs()` exposes the native `tlt_now_ns()` clock.

### 2. Counter, gauge, and metadata events

Current state: implemented at the runtime/recorder/decoder level.

Delivered:

- `counter(...)` for monotonic samples such as rows decoded, cells decoded,
  invalidation count, parked dispatchers, and wake retries.
- `gauge(...)` for current parked dispatchers, max parked dispatchers, WAL
  bytes, stream count, and SQLite memory status snapshots.
- `metadata(...)` for workload name, library name, profile build flags, SQL
  fingerprint, operation tag, batch size, row count, and parameter count.
- `Trace.counterEvents` plus markdown counter summaries in reports.
- Resqlite-specific helpers:
  `recordResqliteDecodeMetrics`, `recordResqliteStreamMetrics`,
  `recordResqliteDispatcherMetrics`, and `recordResqliteDiagnostics`.

### 3. Cross-isolate correlation

resqlite's interesting latency often crosses boundaries:

- caller isolate to writer isolate;
- caller isolate to reader pool;
- writer mutation to stream invalidation;
- stream invalidation to reader re-query;
- Dart operation span to native SQLite spans.

Delivered in tracelite core:

- Correlation IDs can be carried on sync and async events.
- Async span pairing across tracks.

Still needed in resqlite:

- Generation at public operation boundaries.
- Propagation through resqlite request messages.
- Chain-level reporting that can show wall time by caller, writer, reader, and
  SQLite.

### 3a. Core/harness package boundary

Current state: fixed in this implementation pass.

The public `tracelite` library now exports only core tracing APIs. The peer
harness moved under `tool/src/`, and peer library packages are dev dependencies.
This matters because resqlite cannot depend on tracelite if tracelite's public
library depends back on resqlite.

### 4. SQL fingerprinting and redaction

The current resqlite profile samples store raw SQL text. tracelite should avoid
making raw SQL the primary grouping key.

Needed:

- Stable SQL fingerprinting for grouping.
- Optional raw SQL capture behind an explicit unsafe/detail flag.
- Parameter count and batch size as structured args.
- Redaction policy shared across all peer libraries.

### 5. Repetition-level diff and overhead calibration

resqlite's experiment workflow needs "did this candidate help" more than it
needs a pretty trace.

Needed:

- Multiple independent repetitions per workload.
- Diff at repetition-summary level by default.
- No-op/floor measurement so trace overhead is visible.
- JSON artifacts that can feed experiment logs and benchmark history.

### 6. Resqlite embedded shim remains necessary

Dynamic libsqlite interposition is enough for sqlite3, drift, and the traced
sqlite_async path. It is not enough for resqlite because resqlite compiles
sqlite3mc into `libresqlite`.

The resqlite build hook needs a trace mode that:

- compiles sqlite3mc under private symbols;
- compiles tracelite runtime and SQLite wrappers into `libresqlite`;
- exposes the normal `sqlite3_*` names to resqlite's existing FFI layer;
- stays behind a build flag so normal resqlite builds are unaffected.

## Proposed resqlite event vocabulary

These should be user/runtime-registered spans, not hard-coded SQLite C built-ins.

| Kind | Name | Purpose |
|---|---|---|
| span | `resqlite.database.execute` | Public execute call boundary. |
| span | `resqlite.database.execute_batch` | Public batch call boundary with batch size and param count. |
| span | `resqlite.database.select` | Public select boundary with row count and SQL fingerprint. |
| span | `resqlite.writer.handle` | Writer isolate message handling. |
| span | `resqlite.reader.handle` | Reader isolate message handling. |
| span | `resqlite.reader_pool.dispatch` | Main-isolate reader dispatch/admission. |
| span | `resqlite.stream.invalidate` | Stream dependency invalidation after writes. |
| span | `resqlite.stream.intersect_dependencies` | Column/table dependency intersection work. |
| span | `resqlite.stream.select_if_changed` | Reactive re-query and hash/changed check. |
| counter | `resqlite.rows_decoded` | Decoded row count. |
| counter | `resqlite.cells_decoded` | Decoded cell count. |
| counter | `resqlite.dispatcher_parked_total` | Reader dispatcher park count. |
| counter | `resqlite.dispatcher_wake_retry_total` | Wake amplification signal. |
| gauge | `resqlite.dispatcher_current_parked` | Current parked dispatcher count. |
| gauge | `resqlite.dispatcher_max_parked_concurrent` | Peak parked dispatcher count. |
| gauge | `resqlite.sqlite_page_cache_bytes` | SQLite page cache snapshot. |
| gauge | `resqlite.sqlite_schema_bytes` | SQLite schema memory snapshot. |
| gauge | `resqlite.sqlite_stmt_bytes` | SQLite statement memory snapshot. |
| gauge | `resqlite.wal_bytes` | WAL sidecar snapshot. |

## Migration plan

1. Keep resqlite's current profiling until tracelite can prove parity.
2. Done: implement tracelite Dart producer APIs, counters, gauges, metadata, and
   async correlation.
3. Build a tracelite-backed resqlite profile harness that reuses the existing
   `benchmark/profile/workloads.dart` shapes.
4. Add opt-in resqlite Dart spans/counters behind the same profile-build
   discipline used today, using the tracelite helper functions wherever a
   helper exists.
5. Run old `benchmark/run_profile.dart` and the new tracelite harness side by
   side on a small workload matrix.
6. Require parity for sample counts, operation grouping, row/cell counts,
   diagnostics snapshots, and directionally matching timing breakdowns.
7. Remove the low-value old instrumentation first: `Timeline.startSync`
   markers and the `ProfiledDatabase` wall-time wrapper.
8. Move report/diff responsibilities from resqlite to tracelite.
9. Retire `ProfileCounters` only after every counter has a tracelite event
   equivalent.
10. Keep `Database.diagnostics()` and `resqlite_db_status_total` as public and
    native diagnostics, even if tracelite imports their snapshots.

## Expected end state

resqlite should retain:

- benchmark workload definitions;
- public `Database.diagnostics()`;
- minimal opt-in semantic trace emissions;
- the trace-enabled native build hook for embedded SQLite.

tracelite should own:

- trace storage and decoding;
- SQLite C call attribution;
- Dart span/counter/gauge APIs;
- cross-library peer harnesses;
- report, diff, visualization, and experiment artifacts.

That end state would reduce custom benchmark/profiling code in resqlite while
making its performance evidence stronger, because the same trace machinery can
compare resqlite against sqlite3, drift, and sqlite_async.
