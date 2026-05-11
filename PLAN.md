# tracelite — Execution Plan & Status

This is the canonical orientation doc for the tracelite project. It captures what we're building, why, what's been done, what's empirically proven vs designed, what's next, and the load-bearing decisions a future maintainer needs to know.

---

## TLDR

**Status:** Design corpus complete (6 specs, ~3,700 LOC, all reviewed and patched). Runtime + cross-language interop, Dart producer API, aggregator/reporting, wider macOS shim coverage, and the peer harness are implemented. `sqlite3`, `drift`, `sqlite_async`, and a trace-enabled local `resqlite` build validate through SQLite trace events. The CLI now supports repeated peer runs, JSON artifacts, artifact diffs with confidence-interval plus non-parametric gates, accepted/rejected/inconclusive decision artifacts, graph-ready dashboard data export, CI/production suites, and recorder-overhead calibration.

**Killer claim — proven:** A real Dart program using `package:sqlite3` was profiled with zero changes to `package:sqlite3`. 74 events captured from `CREATE TABLE / INSERT × 3 / SELECT` against a real SQLite, all flowing through tracelite's mmap'd ring buffer.

**Next bottleneck:** production benchmark replacement hardening — calibrate decision thresholds on production-sized history, wire resqlite's profile workflow to tracelite artifacts, then finish packaging and Linux/Windows shim validation.

---

## What tracelite is

A SQLite performance-analysis toolkit for the Dart ecosystem: a benchmarking
tool powered by a profiler. The core insight: **every Dart SQLite library
FFI-links to the same `libsqlite3` C library**, so instrumenting `libsqlite3`
once captures every library that uses it — drift, sqlite_async, the `sqlite3`
package itself, Resqlite, anything future. No coordination with library authors
needed.

Layered on top:

- **Per-library Dart-side spans** for libraries that opt in (~10 lines per logical boundary).
- **Cross-isolate causal chains** linking a request's full lifecycle (main → writer → reader-pool → response).
- **Aggregator** that produces statistical reports, regression diffs, and live queries.
- **Peer-comparison harness** so `tracelite compare --interfaces=drift,sqlite_async,sqlite3,resqlite --scenario=batch-insert` is one command.
- **Visualizer** (Flutter web) for interactive trace exploration.

---

## Architecture

```
your code                             ↓
  │   (drift / sqlite_async / Resqlite / a real Dart app)
  │
  ▼
package:sqlite3  ←─── native hooks select source: system, name: sqlite_traced
  │   resolves DynamicLibrary symbols against...
  │
  ▼
libsqlite_traced.dylib (the tracelite shim)
  │   ├── wrapped SQLite API subset:
  │   │     open/close, prepare/step/reset/finalize,
  │   │     binds, column reads, counters/errors, exec
  │   │     → emit BEGIN/END events with timing into shared mmap ring
  │   │     → call real libsqlite3 via dlsym(RTLD_NEXT, ...)
  │   └── unwrapped functions: forwarded transparently via LC_REEXPORT_DYLIB
  │
  ▼
real libsqlite3.dylib or private sqlite3mc symbols in an embedded build


            ┌─── meanwhile, on the Dart side ───┐

(optional) Dart-side TraceRecorder calls in libraries that opt in:
  recorder.trace(MyLibrarySpan, () => doWork())
  ↓
  emit events into the same shared mmap region
  ↓
  cross-isolate timestamps comparable via shared monotonic clock


            ┌─── after the workload ───┐

harness drains the mmap region → finalized .tlt file →
  ↓
  aggregator: trace.spans.ofType(SqliteStep).durations.stats()
  ↓
  ├── markdown reports
  ├── regression diffs (TraceDiff over repetitions)
  ├── visualizer (Flutter web)
  └── Perfetto-format export (optional)
```

Every layer above is contractually defined in `doc/`.

---

## The design corpus

Six specs, all v0.1 drafts after one external review pass:

| Spec | Lines | Defines |
|---|---|---|
| [`format-spec.md`](doc/format-spec.md) | 605 | Wire format, file format, JSONL archival, tags, tracks, spans (begin/end/instant phase model), args, correlation IDs, METADATA payloads, redaction policy |
| [`runtime-protocol.md`](doc/runtime-protocol.md) | 645 | Cross-language shared mmap, slot reservation (commit-head-last), CAS string pool, 4-state producer registry, scenario-boundary drainage, file permissions, ABI conformance tests |
| [`span-registry.md`](doc/span-registry.md) | 130 (rules) + generated tables | Reserved span ID ranges, stability rules, naming, deprecation cycle, hook registration vs invocation distinction |
| [`aggregator-api.md`](doc/aggregator-api.md) | 815 | Loading (4 explicit modes), selection, filtering, aggregation, grouping, chains, CPU attribution (renamed from "wall attribution"), diff over repetitions, live queries |
| [`visualizer-binding.md`](doc/visualizer-binding.md) | 880 | Probes (typed reactive nodes), scope, derivation, frame coalescing via `ProbeScheduler` abstraction, isolate offload via `TraceHandle`, Flutter widget integration, diff mode with cycle-guarded range linking |
| [`peer-interface-contract.md`](doc/peer-interface-contract.md) | 760 | `SqliteInterface` API, `SqliteRow`, `ExecutionResult`, two `LifecycleMode` state machines, `BatchingMode` enum, `RequiredCapability` set, fairness rules |

Plus the source-of-truth file:

- [`tools/spans.yaml`](tools/spans.yaml) — every reserved span ID with begin/end/instant arg schemas. Generator emits Dart constants, C `#define`s, and Markdown tables in lockstep.
- [`tools/generate.dart`](tools/generate.dart) — runs `tools/spans.yaml` → 4 derived files. CI uses `--check` to fail on drift.

Per-spec feedback files (`*.feedback.md`) capture the external review and are retained as the documented review history.

---

## What's been built

### Schema generator (working)

- `tools/spans.yaml` defines 30+ built-in spans across `tracelite`, `sqlite_c`, `dart_recorder`, `ffi_bridge` categories.
- `tools/generate.dart` validates the YAML (range membership, schema phase exclusivity, list-arg position) and emits four derived files.
- `dart run tools/generate.dart --check` exits non-zero if any output is stale relative to the YAML.

```
lib/src/builtin_spans.g.dart       Dart constants for every span ID
native/builtin_spans.g.h           C #define macros, same set
doc/format-spec.appendix.md        compact per-ID table
doc/span-registry.generated.md     full per-category schemas with arg lists
```

### Native runtime (working)

`native/tracelite_runtime.{h,c}` (~270 LOC) implements the producer-side runtime per the spec:

- mmap region attach with `tlt_attach(NULL)` (uses `TRACELITE_REGION` env var if set, otherwise explicit path).
- 4-state producer registry (empty / claiming / registered / ended) with release-store publication of metadata.
- CAS-loop string pool allocator (no fetch_sub on overflow).
- SPSC ring buffer per producer with commit-head-last semantics.
- `tlt_now_ns()` — monotonic clock primitive that Dart and C share.
- `tlt_begin` / `tlt_end` / `tlt_instant` — variable-length event append.
- Correlated sync events, async begin/end events, counter samples, and metadata
  events for Dart-side semantic instrumentation.
- `_Static_assert`s on struct sizes catch ABI drift at compile time.

### Dart producer API (working)

`lib/src/producer.dart` exposes the public recorder surface:

- `TraceRecorder.attach(...)` loads the native runtime, attaches to a region,
  and registers the current isolate as a producer.
- `trace(...)` and `traceAsync(...)` emit sync and async spans with optional
  correlation IDs.
- `counter(...)`, `gauge(...)`, and `metadata(...)` emit non-duration samples
  needed for semantic metrics such as resqlite stream invalidation counts,
  dispatcher pressure, and diagnostic snapshots.
- `TraceVocabulary` and `TraceRecorder.registerVocabulary(...)` let adapters
  register stable span/counter/gauge names without copying metadata code into
  the measured library.
- `package:tracelite/resqlite.dart` exposes the resqlite semantic vocabulary
  that resqlite can import instead of hard-coding IDs and names locally.
- The public `tracelite` library is now core-only. Peer adapters live under
  `bin/src/` and their dependencies are dev-only, so a library such as
  `resqlite` can depend on tracelite's recorder without a package cycle.
  A published peer-comparison CLI should move those adapters into a companion
  package or explicit CLI package rather than reintroducing peer libraries as
  core dependencies.

### libsqlite3 shim (working)

`native/shim_sqlite3.c`:

- Builds as a `libsqlite3`-compatible dylib via `cc -dynamiclib -Wl,-reexport-lsqlite3`.
- Wraps the high-traffic API subset needed by the current peer workloads: connection open/close, prepare, step, reset, finalize, bind variants, column accessors, change counters, last-insert-rowid, errors, and `exec`.
- Each wrapper resolves the real symbol via `dlsym(RTLD_NEXT, ...)` (cached after first call).
- Untraced functions reach through transparently via `LC_REEXPORT_DYLIB` (verified by direct dlsym test).
- Auto-attaches and registers as a `c_thread` producer named `libsqlite_traced` on first call.

### Smoke tests (passing)

| Test | Validates | Events |
|---|---|---|
| [`test/runtime_smoke_test.dart`](test/runtime_smoke_test.dart) | C producer writes via mmap; Dart reader parses the same bytes | 18 |
| [`test/shim_smoke_test.dart`](test/shim_smoke_test.dart) | Real `package:sqlite3` workload routed through the shim; events captured for every wrapped SQLite call | 74 |
| [`test/cli_report_test.dart`](test/cli_report_test.dart) | CLI report loads a captured region and prints markdown stats | 18 |

Run both: `dart test`. Both pass.

### Aggregator and CLI report (working)

`lib/src/trace.dart` implements the first Dart consumer layer:

- `TraceRegion.createFile(...)` creates the current mmap region layout for tests and harness runs.
- `Trace.loadRegion(path)` decodes region headers, producer registry slots, string-pool entries, ring events, paired spans, and diagnostics.
- Span queries support `.ofType(...)`, `.during(...)`, `.durationStats()`, and `.groupStatsByType()`.
- `Trace.toMarkdownReport()` emits the first report table.
- `bin/tracelite.dart report <region>` prints that report from the CLI.
- `bin/tracelite.dart compare --repetitions=N --out-json=compare.json` runs
  repeated peer scenarios and writes benchmark artifacts with per-repetition
  scenario elapsed time, child process time, trace diagnostics, span groups, and
  counter groups.
- `bin/tracelite.dart diff --baseline=base.json --candidate=change.json`
  compares compare artifacts by summary metric with CV gates, a 95% mean-delta
  confidence interval, Mann-Whitney U repetition evidence, and outlier counts.
- `bin/tracelite.dart decision --baseline=base.json --candidate=change.json`
  turns compare artifacts or suite manifests into an accepted/rejected/
  inconclusive decision using trace-health, primary-metric, noise,
  significance, and guardrail gates.
- `bin/tracelite.dart export-graph-data --out=...` writes normalized JSON
  datasets from compare, suite, decision, and workload-summary artifacts so
  downstream sites can render their own charts without embedding tracelite UI.
- `bin/tracelite.dart suite --profile=ci|production --out-dir=...` runs a
  repeatable scenario matrix and writes a manifest plus per-scenario artifacts
  and logs.
- `bin/tracelite.dart calibrate` measures body-only, disabled-recorder, and
  active-recorder overhead for Dart producer spans.

### Wider macOS SQLite shim coverage (working)

`native/shim_sqlite3.c` now wraps the initial prepare/step/reset/finalize/bind/exec set plus connection open/close, additional bind variants, column accessors, change counters, last-insert-rowid, and error accessors.

### Peer harness (working)

`bin/tracelite.dart compare --scenario=narrow-batch-insert --interfaces=sqlite3,drift,sqlite_async,resqlite` runs each peer in a subprocess with its own trace region and decodes the result.

Current validation status:

| Peer | Scenario status | Shim trace status | Notes |
|---|---|---|---|
| `sqlite3` | Pass | Pass | Uses sqlite3 native hooks with `source: system`, `name: sqlite_traced`; the harness provides `libsqlite_traced.dylib` in cwd. |
| `drift` | Pass | Pass | Uses `NativeDatabase`, which routes through `package:sqlite3`. |
| `sqlite_async` | Pass | Pass | Uses the documented `singleConnection` wrapper over a traced `package:sqlite3` connection for the narrow common-interface scenario. The default native pool bypasses the shim. |
| `resqlite` | Pass | Pass | Uses the local `resqlite` checkout's `trace_sqlite` build mode, which compiles sqlite3mc under private symbols and embeds tracelite's SQLite wrappers inside `libresqlite`. |

### Example consumer

- [`example/sqlite3_user.dart`](example/sqlite3_user.dart) — a minimal Dart program that uses `package:sqlite3`. The repo's sqlite3 hook configuration selects the shim as a system library, and the shim test spawns this as a subprocess.

### Repo skeleton

```
tracelite/
├── README.md                    project overview (audience: external)
├── PLAN.md                      this file (audience: contributors / future-self)
├── LICENSE                      MIT
├── .gitignore
├── pubspec.yaml                 package metadata + peer dependencies
├── doc/                         design specs + per-spec feedback
├── tools/                       spans.yaml + generator
├── native/                      C runtime + shim + generated header
├── lib/src/                     trace decoder, peer harness, generated Dart constants
├── example/                     example consumer programs
├── test/                        smoke tests
└── build/                       compiled artifacts (.gitignored)
```

No git remote yet — design and prototype live locally pending a public push.

---

## What's empirically validated vs designed-only

A clear-eyed accounting. Designed ≠ proven.

| Claim | Status | Evidence |
|---|---|---|
| Wire format encodes events round-trippably | ✓ proven | runtime smoke test, 18 events |
| Cross-language mmap with shared monotonic clock works | ✓ proven | C writes, Dart reads, timestamps comparable |
| 4-state registry prevents partial-state visibility | ✓ proven by construction | C writes after release-store of `state=2` |
| CAS string pool allocator is race-free | ✓ proven by construction | no fetch_sub anywhere; not yet stress-tested under contention |
| Commit-head-last avoids torn-event reads | ✓ proven by construction | not yet stress-tested under heavy concurrent drain |
| `package:sqlite3` can be transparently profiled | ✓ proven | shim smoke test, 74 events from CREATE/INSERT/SELECT |
| Reexport + RTLD_NEXT lets us wrap selectively without breaking unwrapped symbols | ✓ proven | direct dlsym test + smoke test |
| Current wrapped SQLite API subset is sufficient for non-trivial sqlite3/drift/sqlite_async/resqlite workloads | ✓ proven | full INSERT + SELECT cycle and peer scenarios work |
| Aggregator skeleton loads region traces and reports stats | ✓ proven | `Trace.loadRegion`, report CLI, runtime/shim/CLI tests |
| Repeated peer runs produce durable JSON artifacts | ✓ proven | `compare --repetitions --out-json`, compare artifact test |
| Artifact diff can compare two benchmark outputs | ✓ proven | `tracelite diff` over compare JSON with threshold, CV gate, 95% mean-delta CI, Mann-Whitney U repetition evidence, and outlier counts |
| Benchmark decisions are machine-gated | ✓ proven | `tracelite decision` over compare JSON and suite manifests, command tests for accepted/rejected/inconclusive outcomes |
| Benchmark artifacts can power downstream dashboards without tracelite UI | ✓ proven | `tracelite export-graph-data` emits graphable datasets from suite, decision, and workload-summary inputs |
| Dart recorder overhead is small enough for profile-mode spans | ✓ measured | 10K spans × 5 reps: active-minus-disabled mean 109ns/span, p90 259ns/span |
| Visualizer is implementable | ✗ designed only | no visualizer code exists |
| Diff over repetitions produces meaningful significance | △ partial | mean CI, non-parametric repetition test, and outlier reporting exist; still needs calibration on real production-sized artifact history |
| Live queries hit sub-frame requery | ✗ designed only | needs visualizer first |
| Linux LD_PRELOAD shim works | ✗ designed only | macOS-only validation today |
| Peer adapters for sqlite3 / drift / sqlite_async / resqlite work | ✓ proven | `tracelite compare --interfaces=sqlite3,drift,sqlite_async,resqlite` emits non-empty SQLite traces |
| resqlite scenario runs through the harness | ✓ proven | compare command completes the resqlite scenario |
| resqlite SQLite internals are traced | ✓ proven | local `trace_sqlite` native-asset mode emits non-empty SQLite spans from `libresqlite` |

Things validated by build but not runtime:

- The C runtime's `_Static_assert`s ensure `sizeof(tlt_region_header_t) == 128`, `sizeof(tlt_registry_slot_t) == 16`, `sizeof(tlt_ring_header_t) == 64`. These caught a real bug during initial development (region header padding mistake).
- The schema generator's `--check` mode catches drift between `spans.yaml` and
  any of its 4 outputs. `.github/workflows/ci.yml` runs that check, builds the
  macOS runtime/shim, runs analysis/tests, and runs
  `tracelite suite --profile=ci` against the four-peer matrix. The workflow
  assumes a sibling `${{ github.repository_owner }}/resqlite` repository because
  local validation uses `dependency_overrides: resqlite: ../resqlite`; private
  installs should provide `CROSS_REPO_READ_TOKEN`.

---

## Execution roadmap

The implementation sequence after the prototype validation is:

> format/schema → runtime mmap proof → registry generation → aggregator/reporting → SQLite shim coverage → peer harness/adapters → cross-library validation → benchmark artifacts/diff → production resqlite parity → workload/statistics hardening → visualizer/export

Format/schema, runtime mmap proof, registry generation, aggregator/reporting,
wider SQLite shim coverage, peer harness/adapters, the four-peer validation
matrix, and the first benchmark artifact/diff/calibration/suite workflow are
done for the local prototype.

### Production-ready target

Production-ready means tracelite can replace most of resqlite's custom profile
runner/reporting code while improving cross-library evidence quality.

The target split:

- **tracelite owns** trace capture, SQLite attribution, Dart recorder APIs,
  span/counter metadata, JSON artifacts, report generation, repetition
  summaries, regression decisions, peer adapters, visualization, and optional
  Perfetto/export paths.
- **resqlite owns** benchmark workload definitions, public diagnostics APIs,
  the trace-enabled native build hook, and small opt-in semantic emissions for
  facts only resqlite can know.

Exit criteria before deleting old resqlite profiling surfaces:

- Old `benchmark/run_profile.dart` and new tracelite artifacts run side by side
  for the same workload matrix.
- Operation counts, row/cell decode counts, stream invalidation counters,
  reader-pool pressure, and SQLite diagnostics snapshots have tracelite
  equivalents.
- Timing breakdowns directionally match the old profiler while adding
  trace-level attribution to SQLite C, reader/writer handling, dispatch,
  invalidation, and decode work.
- `tracelite diff` can produce `improved`, `regressed`, `neutral`, or
  `too_noisy` decisions from independent repetitions without depending on
  pseudo-replicated within-run spans.
- CI verifies the native shim path, the trace-enabled resqlite native-asset
  path, generated schema freshness, and at least one cross-library smoke
  benchmark.
- The normal resqlite release path remains unaffected unless profile/tracing
  build flags are explicitly enabled.

### Phase 4: Aggregator skeleton (complete)

**Goal:** turn captured region files into queryable traces and markdown reports.

Delivered surface:
- `Trace.loadRegion(path)` — read the current mmap region layout and build paired spans.
- `trace.events`, `trace.spans`, `trace.tracks`, `trace.strings` — immutable decoded views.
- `trace.spans.ofType(span)` / `.during(range)` / `.where(...)` — selection.
- `.durations.stats()` — count, total, min, mean, p50, p90, p99, max.
- `.byType` grouping for report tables.
- A markdown exporter suitable for committed benchmark reports.
- A small CLI entrypoint: `tracelite report <region>`.

Out of scope for this phase:
- LiveQuery / scrub-bar reactivity.
- CPU attribution (no sampler integrated yet).
- Diff mode (`TraceDiff.compare`).
- Cross-trace analysis.
- Finalized `.tlt` writer/loader; the current CLI reads live-region files.
- Approximate percentile structures; exact percentiles are enough for the current smoke/peer traces.

The shim smoke test's hand-rolled drain is gone; runtime, shim, and CLI tests all use the shared decoder.

### Phase 5: Wider C shim coverage + first sqlite3 markdown report (complete)

**Goal:** make the existing sqlite3 proof produce a useful profiling report.

Column accessors (`column_int64`, `column_text`, `column_bytes`, ...), bind variants, connection open/close, counters, last-insert-rowid, error accessors, and other high-traffic functions are now wrapped. The first real markdown report is generated by `tracelite report`:

```
$ tracelite report shim_smoke.tlt
# tracelite report

Trace: 74 events, 1 producer (c_thread / libsqlite_traced)
Duration: <workload duration>

| span                  | count | p50      | p99      | total    |
|-----------------------|-------|----------|----------|----------|
| sqlite3_step          | 12    | 4.1 µs   | 14.2 µs  | 73 µs    |
| sqlite3_prepare_v3    | 8     | 23 µs    | 47 µs    | 218 µs   |
| sqlite3_finalize      | 8     | 1.8 µs   | 3.4 µs   | 18 µs    |
| sqlite3_reset         | 8     | 0.9 µs   | 1.6 µs   | 8 µs     |
| sqlite3_bind_int64    | 8     | 0.4 µs   | 0.8 µs   | 4 µs     |
| sqlite3_bind_text     | 6     | 0.6 µs   | 1.2 µs   | 5 µs     |
| sqlite3_exec          | 2     | 28 µs    | 28 µs    | 56 µs    |
```

This is the first user-visible value and is covered by the CLI report test.

### Phase 6: Peer harness and adapters (complete)

**Goal:** run one deterministic scenario through all required peer libraries with the same shim and report format.

Implemented:
- `SqliteInterface` and row/result types from `peer-interface-contract.md`.
- Scenario lifecycle runner with explicit fresh/shared DB state machines.
- `narrow-batch-insert` and `point-select` baseline scenarios.
- `feed-paging` and `sync-burst` resqlite-derived workload ports over the
  shared SQL interface.
- Adapters for:
  - `sqlite3`
  - `drift`
  - `sqlite_async`
  - `resqlite`
- Per-run status capture: peer name, scenario parameters, setup/warmup/measured
  phase timing, event count, span count, `sqlite3_step` span count, total traced
  time, and trace-gap notes.

The harness command shape:

```
$ tracelite compare --scenario=narrow-batch-insert --interfaces=sqlite3,drift,sqlite_async,resqlite
```

Drift and sqlite3 use `package:sqlite3` directly or transitively, so the same macOS shim path works. `sqlite_async` validates through its `singleConnection` wrapper over a traced `package:sqlite3` connection. `resqlite` validates through a local `trace_sqlite` native-asset mode that embeds tracelite's SQLite wrappers inside `libresqlite`.

### Phase 7: Cross-library validation matrix (complete)

**Goal:** prove the implementation against the four named peers.

Current evidence:
- `dart run bin/tracelite.dart report <region>` produces non-empty markdown with paired SQLite spans.
- `dart run bin/tracelite.dart compare --scenario=narrow-batch-insert --interfaces=sqlite3,drift,sqlite_async,resqlite --rows=20` runs all four peers and each emits non-empty SQLite trace events.
- `resqlite` uses the local checkout via `dependency_overrides` plus `hooks.user_defines.resqlite.trace_sqlite=true`; upstream/pub validation depends on carrying that build mode into the published package.
- Tests cover region decoding, span pairing, string-pool decoding, markdown reporting, at least one real sqlite3 shim run, and the four-peer compare command.
- The compare output includes the architectural warning from `peer-interface-contract.md`: tracelite compares shared SQL execution paths, not overall library quality.

### Phase 8: Benchmark artifact workflow (complete)

**Goal:** turn trace runs into benchmark artifacts that can replace resqlite's
custom profile output over time.

Delivered:

- `tracelite compare --repetitions=N --out-json=compare.json` writes a stable
  artifact with per-repetition samples, scenario elapsed time, child process
  elapsed time, trace diagnostics, span groups, and counter groups.
- Scenario elapsed time is measured inside the child process, so benchmark
  timings exclude `dart run` startup and native-asset build-hook overhead.
- `tracelite diff --baseline=base.json --candidate=change.json` compares
  artifacts by summary metric with a percent threshold and coefficient-of-
  variation noise gate.
- `tracelite calibrate` measures body-only, disabled-recorder, and
  active-recorder overhead.
- `doc/production-benchmark-readiness.md` records the current measured evidence
  and blockers.

Current measured checkpoint:

- Dart recorder overhead: active-minus-disabled mean 109ns/span, p90
  259ns/span over 10K spans × 5 repetitions.
- Four-peer `narrow-batch-insert` and `point-select` runs complete with
  `0/0/0` max dropped/unmatched diagnostics.
- `diff` can now refuse a verdict as `too_noisy` when CV exceeds the configured
  gate.

### Phase 9: Resqlite production integration and semantic parity (in progress)

**Goal:** make resqlite's integration tiny while tracelite does the profiling
and benchmark heavy lifting.

Work:

- Land the trace-enabled resqlite native-asset mode and logical-track Dart
  bridge in resqlite.
- Move bespoke resqlite bridge code toward tracelite-owned helpers where
  possible: attach, span registration, correlation IDs, counters, gauges,
  metadata naming, and no-op disabled behavior.
- Done in tracelite core: generic vocabulary registration and the public
  resqlite vocabulary now live in tracelite. Next resqlite PR work should
  consume this surface instead of duplicating span IDs and metadata names.
- Keep resqlite-specific knowledge as a small vocabulary adapter, not a
  profiling subsystem.
- Emit the minimum semantic facts tracelite cannot infer:
  - public operation spans: `database.select`, `select_bytes`, `execute`,
    `execute_batch`;
  - worker/dispatch spans: writer handle, reader handle, reader-pool dispatch;
  - stream spans/counters: invalidate, dependency intersection, selected stream
    re-query/change checks;
  - decode counters: rows decoded, cells decoded;
  - dispatcher counters/gauges: parked total, wake retries, current parked, max
    parked;
  - diagnostics snapshots: page cache bytes, schema bytes, statement bytes, WAL
    bytes, stream counts, reader busy state.
- Add side-by-side parity tests between current resqlite profile output and
  tracelite artifacts for a small initial matrix.

Acceptance gates:

- A trace-enabled resqlite workload produces named resqlite spans/counters and
  SQLite C spans with zero dropped/unmatched diagnostics.
- Tracelite artifacts can reproduce the old profiler's operation counts,
  row/cell counts, diagnostics deltas, and major timing buckets.
- Removing `Timeline.startSync` markers and `ProfiledDatabase` wall-time
  wrappers becomes a behavior-preserving cleanup, not a loss of evidence.

### Phase 10: Workload matrix and peer fairness hardening (in progress)

**Goal:** make tracelite's benchmark harness broad enough to replace resqlite's
profile workflow for real experiment decisions.

Work:

- Done in tracelite core: compare artifacts now include deterministic workload
  parameters plus setup, warmup, and measured phase timings from the child
  process.
- Done in tracelite core: compare artifacts now include Dart/OS environment
  metadata, and `compare` exits non-zero if any peer fails, emits no trace, or
  reports dropped/unmatched trace diagnostics.
- Done in the peer harness: initial `feed-paging`, `sync-burst`, `chat-sim`,
  and scaled `large-working-set` workload ports run across `sqlite3`, `drift`,
  `sqlite_async`, and `resqlite`.
- Done in the peer harness: capability-aware scenario dispatch now reports
  `unsupported` peers without failing the compare run, and artifacts include
  each peer's advertised capabilities.
- Done in the peer harness: initial reactive scenarios cover keyed primary-key
  subscriptions, high-cardinality fan-out, and many-stream writer throughput
  for peers with a stream/watch API. The current `sqlite_async` and `resqlite`
  adapters implement this lane; `sqlite3` and the current raw-SQL `drift`
  adapter report unsupported.
- Done in the resqlite vocabulary: `recordResqliteDiagnostics` records
  `Database.diagnostics()` snapshots as tracelite gauges, and the
  `sqlite-diagnostics` scenario validates the path through resqlite.
- Port the useful resqlite workload shapes:
  - chat simulation; ✓ initial shared-SQL port
  - feed paging; ✓ initial shared-SQL port
  - sync burst; ✓ initial shared-SQL port
  - large working set; ✓ scaled shared-SQL port
  - keyed primary-key subscriptions; ✓ initial capability-specific reactive
    scenario;
  - high-cardinality fan-out; ✓ initial capability-specific reactive scenario;
  - many-stream writer throughput; ✓ initial capability-specific reactive
    scenario;
  - SQLite diagnostics workload; ✓ initial resqlite semantic gauge scenario.
- Encode workload parameters and seeds in artifacts so runs are reproducible.
- Separate setup/warmup/measured phases in the peer harness.
- Document each peer's traced mode. In particular, `sqlite_async` currently
  validates through a traced `singleConnection` wrapper; default native-pool
  coverage needs separate validation or explicit exclusion.
- Add a real drift reactive adapter backed by generated/table-registry-aware
  drift queries before claiming drift support for the optional reactive lane.
  The current raw `NativeDatabase` adapter cannot honestly model drift's stream
  invalidation semantics.
- Scale ring sizing from expected event volume and fail loudly if any producer
  drops events.
- Consider a compiled/snapshotted child or long-lived worker to reduce suite
  wall time once region reset semantics are formalized.

Acceptance gates:

- The tracelite harness covers the workload shapes used for resqlite experiment
  decisions.
- Each peer has documented capability/fairness constraints.
- Artifacts identify setup time, measured time, trace diagnostics, peer mode,
  workload parameters, and environment.

### Phase 11: Statistical decisioning and experiment artifacts (in progress)

**Goal:** make `tracelite diff` credible enough for PRs and experiment logs.

Work:

- Done in tracelite core: `diff` now computes a 95% mean-delta confidence
  interval over independent repetitions and treats threshold-sized changes as
  `too_noisy` unless the interval excludes zero.
- Add a non-parametric test over independent repetitions.
- Keep the CV/noise gate, but make verdicts explicit:
  `improved`, `regressed`, `neutral`, `too_noisy`, `insufficient_samples`.
- Add outlier classification and report it without silently deleting samples.
- Support metric families: scenario elapsed, traced span total, specific span
  groups, counters, diagnostics deltas, and peer-normalized comparisons.
- Emit PR/experiment-ready markdown and JSON sidecars.
- Add schema versioning for compare/diff artifacts.

Acceptance gates:

- Diff output names the metric, effect size, noise level, sample count, and
  verdict.
- CI can fail on configured regressions while treating noisy data as
  inconclusive instead of pretending it is signal.

### Phase 12: Profiling depth and report ergonomics

**Goal:** make traces explain benchmark changes, not just detect them.

Work:

- Add SQL fingerprinting and redaction. Raw SQL capture must be explicit and
  unsafe/detail-gated; grouping should default to normalized fingerprints.
- Add causal-chain reporting from public Dart operation to reader/writer
  dispatch, worker handling, stream invalidation, decode, and SQLite C spans.
- Improve counter/gauge reports for semantic resqlite signals.
- Add trace export paths for external inspection, likely Perfetto first.
- Build a visualizer after the query/artifact layer is stable.
- Consider stack sampling for CPU attribution only after wall/span attribution
  is solid.

Acceptance gates:

- A regression report can answer "where did the time move?" across Dart,
  resqlite semantic spans, and SQLite C.
- High-cardinality values are redacted or fingerprinted by default.
- Visual and exported traces agree with CLI summaries.

### Phase 13: Portability, packaging, and CI

**Goal:** make the profiler/benchmark workflow usable outside the local macOS
prototype.

Work:

- Package the CLI and runtime build outputs cleanly.
- Validate Linux shim loading (`LD_PRELOAD` or equivalent native-asset path).
- Validate Windows substitution/loading strategy.
- Add CI for:
  - generator freshness;
  - runtime/shim tests;
  - benchmark artifact tests;
  - resqlite `trace_sqlite` native-asset smoke;
  - four-peer compare smoke where dependencies are available.
- Publish docs for:
  - using tracelite as a peer benchmark harness;
  - adding a lightweight semantic adapter to a library;
  - interpreting diff/noise verdicts;
  - redaction and artifact storage policy.

Acceptance gates:

- A fresh checkout can run the documented smoke workflow without local hidden
  state.
- Resqlite can depend on tracelite's core recorder without pulling in peer
  benchmark dependencies.
- Platform-specific behavior is documented and tested.

---

## Key design decisions

The non-obvious choices a future maintainer needs to know.

### 1. Reexport-and-override, not LD_PRELOAD

Initial design assumed LD_PRELOAD-style symbol interposition. The actual implementation uses a different mechanism: build the shim as a libsqlite3-compatible dylib that re-exports the real libsqlite3 plus overrides the traced SQLite API subset. Consumer programs load the shim via sqlite3 native hooks. No global env var manipulation is required for the `package:sqlite3` path.

This is *better* than LD_PRELOAD because it works on macOS without DYLD_INSERT_LIBRARIES restrictions, doesn't rely on global symbol resolution order, and doesn't surprise users who didn't expect their environment to be intercepted.

### 2. BEGIN/END/INSTANT phase schemas, not single-phase args

A SQLite call like `sqlite3_step(stmt) → rc` has `stmt` known at BEGIN and `rc` known at END. A single positional arg list per span can't express this without lying. Spans declare `begin_args`, `end_args`, and `instant_args` separately. The generator and aggregator both honor this distinction.

### 3. Commit-head-last, no per-slot commit bits

The producer writes data words first, then the header word with `release` ordering, then advances `head` with `release`. A consumer sees an event only after `head` has been advanced past it. No "reserved but not committed" state visible across processes; no zero-then-write protocol on the hot path.

### 4. Scenario-boundary drainage only in v0.1

Live mid-workload drainage requires a back-pressure signal, a producer-pause handshake with timeout, and live string-pool race handling. v0.1 sidesteps all of these by drainage only happening *between* `Scenario.run()` invocations when producers are inactive. v0.2 design pass needed for live mode.

### 5. Dart producers must use `tlt_now_ns()`, not `Stopwatch`

Dart's `Stopwatch` doesn't promise the same epoch or backing clock as the native runtime's `clock_gettime(CLOCK_MONOTONIC)` on every platform. Dart producers reach the runtime's clock via FFI; using `Stopwatch` is undefined behavior under the protocol.

### 6. Schema generator is load-bearing

After one review pass, span IDs in `aggregator-api.md` examples disagreed with `span-registry.md`. The fix wasn't more careful editing — it was making spec drift mechanically impossible by deriving everything from `tools/spans.yaml`. CI's `--check` mode is the load-bearing protection. **Never edit generated files by hand; the generator overwrites them on next run.**

### 7. CPU attribution, not "wall attribution"

Dart's CPU profiler samples *executing* threads. A function appearing in 30% of samples used 30% of the *CPU*, not 30% of wall time. Span data captures wall correctly; the sampler is the other half. The aggregator API is `trace.cpuAttribution`, not `trace.wallAttribution`. Users seeing "drift used 45ms-of-CPU" understand it's CPU time; conflating with wall produces misleading reports.

### 8. Diff over repetitions, not over individual spans

Mann-Whitney U over thousands of within-run spans is pseudo-replication — events from one run aren't independent samples. Default `unit: repetition` requires multiple independent runs. `unit: span` is allowed with `--allow-pseudo-replication` but produces no significance column.

### 9. Format file extension is `.tlt`, magic is `TLTE`

Avoids collision with Linux's `strace` tool. The runtime mmap region uses a different magic (`TLTR`) so a half-finalized region file can't be mistaken for a finished trace.

---

## How to pick this up

If you're a new contributor, future-self after a break, or an LLM session continuing this work:

1. **Read this file** (you're here).
2. **Read [README.md](README.md)** for the external pitch.
3. **Skim [doc/format-spec.md](doc/format-spec.md)** sections 1–4 for the format mental model. Dive deeper if you'll touch the runtime.
4. **Run the tests:** `dart pub get && dart test` should pass. The tests build the C producer and shim as needed.
5. **Pick the next phase.** The prototype validation matrix and first artifact
   workflow are complete; next work is Phase 9 resqlite semantic parity and
   workload migration.

### Build commands worth memorizing

```bash
# Regenerate from spans.yaml after editing
dart run tools/generate.dart

# Verify generated files match spans.yaml (CI-shape check)
dart run tools/generate.dart --check

# Build the native runtime + test_producer
cc -std=c11 -O2 -Wall -Wextra -Inative \
  native/tracelite_runtime.c native/test_producer.c \
  -o build/test_producer

# Build the libsqlite3 shim (macOS)
cc -dynamiclib -O2 -Inative \
  native/tracelite_runtime.c native/shim_sqlite3.c \
  -Wl,-reexport-lsqlite3 \
  -o build/libsqlite_traced.dylib

# Run all tests
dart test

# Run the small artifact-producing CI benchmark suite
dart run bin/tracelite.dart suite \
  --profile=ci \
  --interfaces=sqlite3,drift,sqlite_async,resqlite \
  --out-dir=build/tracelite-ci-suite

# Run the production-oriented replacement matrix
dart run bin/tracelite.dart suite \
  --profile=production \
  --interfaces=sqlite3,drift,sqlite_async,resqlite \
  --out-dir=build/tracelite-production-suite
```

### Common gotchas

- **Generated files** (`*.g.dart`, `*.g.h`, `*.generated.md`, `*.appendix.md`) regenerate on every `dart run tools/generate.dart`. Hand edits are lost. Edit `tools/spans.yaml` and the generator instead.
- **Ring data words must be a power of 2.** The producer's `& mask` math depends on it. The smoke test caught this once; the runtime header docs it.
- **macOS `-Wl,-reexport-lsqlite3`** is the load-bearing flag for the shim. Without it, the shim only exposes explicitly wrapped symbols and `package:sqlite3` fails on first dlsym for an unwrapped function.
- **resqlite needs embedded tracing, not dynamic interposition.** Its native asset compiles sqlite3mc into `libresqlite`, so the trace build renames selected sqlite3mc API symbols to `tlt_sqlite3_*` and embeds tracelite's wrappers under the public `sqlite3_*` names.
- **Don't add `Stopwatch` calls in Dart producers.** Use `tlt_now_ns()` via FFI. The protocol contract requires a single shared clock primitive.
- **Runtime tests are serialized.** The current C runtime has one active mapped
  region per loaded process. `dart_test.yaml` sets `concurrency: 1` so tests
  that attach different trace regions do not race each other until multi-region
  or explicit detach/unmap support exists.

---

## Open design questions (not blocking)

- **Wider SQLite C API coverage** — Should the shim wrap *every* SQLite API or stay narrow? Driven by encountered gaps.
- **SQL fingerprinting** — ORM-generated SQL varies per call. Need a `sql_fingerprint_id` arg derived from a normalized form for fair grouping. Reserved as a future arg type.
- **`bind` event volume** — A 10-column INSERT produces 10 bind events. Wide-batch inserts (10K rows × 20 cols) generate 200K bind events per call. Consider eliding to a `bind_batch_summary` span (ID `0x107F` reserved).
- **Counter sampling cadence** — `sqlite3_db_status` page-cache, schema-cache counters could be polled and emitted as `COUNTER` events on a timer. Default rate? Producer-driven or consumer-pulled?
- **Live-mode design** — back-pressure, producer-pause handshake, live string-pool race. Whole v0.2 design pass.
- **Track slot recycling** — 256-slot registry caps long-running live sessions. Generation counter per slot needed for v0.2.

---

## Out of scope (deferred or rejected)

| Feature | Why deferred / rejected |
|---|---|
| Production telemetry / always-on tracing | Different problem; tracelite is for synthetic benchmarks and dev-time profiling |
| Replacement for Dart DevTools | DevTools wins for interactive debugging; tracelite is for offline trace analysis |
| Migration tool from tracelite to Perfetto | An export adapter is feasible later; not v0.1 |
| Mobile (Flutter) target | Desktop / CI first; mobile shim is a future v0.x |
| Web target | `dart:ffi` doesn't exist on web; tracelite is native-only by design |
| Encrypted trace files at rest | Out of scope; file permissions + redaction modes are the answer |
| Distributed tracing (cross-process, cross-machine) | v0.2+; cross-process drainage is one piece of this |
| Wall-time CPU attribution (full-fidelity) | Needs OS-level wall sampling (`perf` on Linux, Instruments on macOS); not v0.1 |

---

## Appendix: file inventory

| Path | Purpose | Lines |
|---|---|---|
| `README.md` | Project pitch | 87 |
| `PLAN.md` | This file | — |
| `LICENSE` | MIT | 21 |
| `pubspec.yaml` | Package metadata + peer dependencies | 31 |
| `doc/format-spec.md` | Trace format spec | 671 |
| `doc/runtime-protocol.md` | Cross-language mmap protocol | 803 |
| `doc/span-registry.md` | Span ID rules + generator pointer | 169 |
| `doc/span-registry.generated.md` | (generated) full schemas | 69 |
| `doc/aggregator-api.md` | Query API spec | 866 |
| `doc/visualizer-binding.md` | Reactive UI binding spec | 904 |
| `doc/peer-interface-contract.md` | `SqliteInterface` + scenarios + adapters | 798 |
| `doc/format-spec.appendix.md` | (generated) compact ID table | 51 |
| `doc/*.feedback.md` (6 files) | External review history | ~5,800 total |
| `tools/spans.yaml` | SOURCE OF TRUTH for span IDs | 466 |
| `tools/generate.dart` | Schema generator | 359 |
| `lib/src/builtin_spans.g.dart` | (generated) Dart constants | 198 |
| `native/tracelite_runtime.h` | Runtime header (region, registry, ring layouts) | 167 |
| `native/tracelite_runtime.c` | Runtime implementation | 269 |
| `native/builtin_spans.g.h` | (generated) C macros | 102 |
| `native/test_producer.c` | Synthetic event producer (runtime smoke test) | 72 |
| `native/shim_sqlite3.c` | libsqlite3 shim wrapping the current SQLite API subset | 582 |
| `example/sqlite3_user.dart` | Real package:sqlite3 consumer | 26 |
| `test/runtime_smoke_test.dart` | Cross-language mmap round-trip (18 events) | 105 |
| `test/shim_smoke_test.dart` | Real package:sqlite3 round-trip (74 events) | 105 |
| `test/cli_report_test.dart` | CLI markdown report smoke test | 45 |

Total hand-written code: ~3,200 LOC.
Total design specs: ~3,700 LOC of markdown.
Total review feedback: ~5,800 LOC of markdown (preserved as *.feedback.md).

---

*Last updated: 2026-05-09 — after the production benchmark/profiling roadmap was expanded around resqlite semantic parity, workload coverage, statistical gates, profiling depth, and portability.*
