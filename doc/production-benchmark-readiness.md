# Production benchmark replacement readiness

Status: implementation-backed pass, 2026-05-09

## Verdict

tracelite is now viable as the benchmark artifact and attribution layer, but it
is not yet a complete replacement for resqlite's production benchmark profiling
stack.

The core direction held up: one trace format can capture sqlite3, drift,
sqlite_async, and trace-enabled resqlite under the same SQLite call model, and
the recorder overhead is small enough for profile-mode instrumentation. The
remaining gaps are around benchmark-runner maturity: workload coverage,
significance testing, packaging, and resqlite's migration to the semantic event
vocabulary.

## What changed in this pass

- `tracelite compare` now supports `--repetitions=N`.
- `tracelite compare` writes structured JSON with `--out-json=path`.
- The compare artifact records per-repetition scenario elapsed time, child
  process elapsed time, event/span counts, diagnostics, span groups, and
  counter groups.
- Scenario elapsed time is measured inside the child process, so reported
  benchmark time excludes `dart run` startup and native-asset build-hook
  overhead.
- `tracelite diff --baseline=base.json --candidate=change.json` compares
  repetition artifacts by a chosen summary metric.
- `tracelite diff` now reports a 95% mean-delta confidence interval over
  independent repetitions and treats threshold-sized changes as `too_noisy`
  unless the interval excludes zero.
- `tracelite diff` now reports a Mann-Whitney U two-sided p-value over
  repetition samples and per-side Tukey outlier counts; threshold-sized changes
  require both the mean interval and non-parametric repetition evidence to agree
  before they are called `improved` or `regressed`.
- `tracelite suite --profile=ci|production` now runs a repeatable benchmark
  matrix and writes a suite manifest plus per-scenario compare artifacts and
  logs.
- `.github/workflows/ci.yml` now defines the intended macOS CI baseline:
  generated-span freshness, native runtime/shim build, analysis, tests, and the
  four-peer `ci` suite. It assumes a sibling resqlite repository checkout and
  supports `CROSS_REPO_READ_TOKEN` for private installs.
- `tracelite calibrate` measures Dart recorder overhead with body-only,
  disabled-recorder, and active-recorder loops.
- Compare artifacts now include deterministic workload parameters and
  child-process setup, warmup, measured phase timings, and Dart/OS environment
  metadata.
- `tracelite compare` now exits non-zero when any peer fails, emits no trace, or
  reports dropped/unmatched trace diagnostics.
- The peer harness now includes initial shared-SQL ports of resqlite's
  `feed-paging`, `sync-burst`, `chat-sim`, and scaled `large-working-set`
  workload shapes.
- Compare artifacts now include peer capability metadata and can represent
  unsupported capability-specific scenarios without failing the whole run.
- The peer harness now includes initial reactive ports for keyed PK
  subscriptions, high-cardinality fan-out, and many-stream writer throughput.
  These currently run on `sqlite_async` and `resqlite`; `sqlite3` and the
  current raw-SQL `drift` adapter report unsupported.
- `package:tracelite/resqlite.dart` now includes
  `recordResqliteDecodeMetrics`, `recordResqliteStreamMetrics`,
  `recordResqliteDispatcherMetrics`, and `recordResqliteDiagnostics`, and the
  `sqlite-diagnostics` scenario records resqlite diagnostic snapshots as
  tracelite gauges.

## Evidence from this pass

### Recorder overhead

Command:

```bash
dart run bin/tracelite.dart calibrate \
  --iterations=10000 \
  --repetitions=5 \
  --out-json=/tmp/tracelite-calibration.json
```

Result:

| metric | mean | p50 | p90 |
|---|---:|---:|---:|
| active minus disabled per span | 109ns | 85ns | 259ns |
| active minus body-only per span | 216ns | 193ns | 369ns |

Trace validation: 20,001 events average, 10,000 spans average, and `0/0/0`
max dropped/unmatched diagnostics.

Interpretation: Dart recorder event emission is not the blocker for
profile-mode use. The next overhead question is full SQLite-shim overhead on
larger workloads, not the Dart producer API itself.

### Four-peer batch shape

Command:

```bash
dart run bin/tracelite.dart compare \
  --scenario=narrow-batch-insert \
  --interfaces=sqlite3,drift,sqlite_async,resqlite \
  --rows=10 \
  --repetitions=3 \
  --out-json=/tmp/tracelite-compare-four-peer.json
```

Result:

| peer | status | reps | events avg | spans avg | sqlite3_step avg | scenario elapsed avg | scenario cv | traced total avg | diagnostics max |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| sqlite3 | ok | 3/3 | 116 | 58 | 12 | 32.5ms | 9.34% | 2.44ms | 0/0/0 |
| drift | ok | 3/3 | 136 | 68 | 14 | 40.1ms | 6.71% | 2.30ms | 0/0/0 |
| sqlite_async | ok | 3/3 | 174 | 87 | 18 | 38.4ms | 3.49% | 1.63ms | 0/0/0 |
| resqlite | ok | 3/3 | 240 | 120 | 16 | 305ms | 18.7% | 4.37ms | 0/0/0 |

### Four-peer read-heavy shape

Command:

```bash
dart run bin/tracelite.dart compare \
  --scenario=point-select \
  --interfaces=sqlite3,drift,sqlite_async,resqlite \
  --rows=20 \
  --repetitions=3 \
  --out-json=/tmp/tracelite-compare-point-select.json
```

Result:

| peer | status | reps | events avg | spans avg | sqlite3_step avg | scenario elapsed avg | scenario cv | traced total avg | diagnostics max |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| sqlite3 | ok | 3/3 | 676 | 338 | 62 | 38.4ms | 6.02% | 2.16ms | 0/0/0 |
| drift | ok | 3/3 | 620 | 310 | 64 | 49.6ms | 12.0% | 2.85ms | 0/0/0 |
| sqlite_async | ok | 3/3 | 734 | 367 | 68 | 54.3ms | 6.94% | 2.49ms | 0/0/0 |
| resqlite | ok | 3/3 | 648 | 324 | 66 | 312ms | 4.85% | 4.34ms | 0/0/0 |

The resqlite runs above use the current local `../resqlite` override. The
fuller Dart-level resqlite span/counter vocabulary depends on the PR that adds
the tracelite logical-track bridge.

### Four-peer resqlite-derived workload smoke

Commands:

```bash
dart run bin/tracelite.dart compare \
  --scenario=feed-paging \
  --interfaces=sqlite3,drift,sqlite_async,resqlite \
  --rows=8

dart run bin/tracelite.dart compare \
  --scenario=sync-burst \
  --interfaces=sqlite3,drift,sqlite_async,resqlite \
  --rows=8
```

Result: the first two resqlite-derived workload shapes completed on all four
peers with non-empty SQLite traces and `0/0/0` max dropped/unmatched
diagnostics. Follow-up validation extended the same smoke test to `chat-sim`
and scaled `large-working-set`. The small row count is a smoke validation of
scenario semantics and tracing coverage; production-scale numbers still need
repetition counts, larger parameter sets, and statistical decisioning.

### Capability-aware reactive and diagnostic lanes

Commands:

```bash
dart run bin/tracelite.dart compare \
  --scenario=keyed-pk-subscriptions \
  --interfaces=sqlite3,drift,sqlite_async,resqlite \
  --rows=4

dart run bin/tracelite.dart compare \
  --scenario=high-cardinality-fanout \
  --interfaces=sqlite3,drift,sqlite_async,resqlite \
  --rows=4

dart run bin/tracelite.dart compare \
  --scenario=many-streams-writer-throughput \
  --interfaces=sqlite3,drift,sqlite_async,resqlite \
  --rows=4

dart run bin/tracelite.dart compare \
  --scenario=sqlite-diagnostics \
  --interfaces=sqlite3,drift,sqlite_async,resqlite \
  --rows=4
```

Result: reactive scenarios report `sqlite3` and the current raw-SQL `drift`
adapter as `unsupported`, while `sqlite_async` and `resqlite` complete with
non-empty traces and `0/0/0` diagnostics. The diagnostics scenario reports
`sqlite3`, `drift`, and `sqlite_async` as unsupported and records resqlite
gauges for page-cache bytes, schema bytes, statement bytes, WAL bytes, stream
count, and reader-busy state.

## What this can replace first

Ready to migrate first:

- Markdown/JSON profile report generation.
- Repetition artifact storage.
- Cross-library SQLite call attribution.
- Low-value wall-time wrappers whose only job is operation duration.
- Timeline-style worker markers where tracelite spans already exist.

Keep for now:

- Resqlite workload definitions.
- `Database.diagnostics()` and native SQLite status snapshots.
- Existing profile runner until tracelite diff grows production statistical
  gates and the resqlite semantic event parity checklist is complete.

## Remaining blockers

### 1. Statistical decisioning needs production calibration

`tracelite diff` now compares summary means with a percent threshold, CV gate,
95% mean-delta confidence interval, Mann-Whitney U repetition evidence, and
explicit outlier counts. This is enough to stop relying on pseudo-replicated
within-run spans for decisions. The remaining work is calibration on real
production-sized artifact history: choose default repetition counts, thresholds,
and noise gates per workload family.

### 2. Workload coverage is broader, but still needs production scale

`narrow-batch-insert`, `point-select`, `feed-paging`, `sync-burst`, `chat-sim`,
scaled `large-working-set`, keyed PK subscriptions, high-cardinality fan-out,
many-stream writer throughput, and `sqlite-diagnostics` are now implemented in
tracelite's peer harness. Production replacement still requires larger
parameter sets, repeated-run artifacts for each workload, and side-by-side
parity against the current resqlite profiler outputs.

The biggest architectural gap is drift's optional reactive lane. The current
tracelite `drift` peer adapter is intentionally raw-SQL based, so it cannot
honestly exercise drift's generated stream-query invalidation model. Supporting
drift reactivity needs a generated/table-registry-aware adapter rather than a
fake watch wrapper around the current raw `NativeDatabase` path.

### 3. Runner startup is separated, not eliminated

Scenario elapsed time is now measured inside the child process, so startup does
not pollute the benchmark metric. The runner still pays `dart run` process
startup per repetition, which makes large experiment suites slower than they
need to be. A production runner should use a compiled/snapshotted child or a
long-lived worker once region lifecycle and reset semantics are formalized.

### 4. Resqlite semantic parity depends on adoption

The trace format and recorder now support the needed semantic events, and the
resqlite bridge PR emits the first vocabulary. tracelite now also exposes
helpers for the migration counters and gauges so resqlite does not need to
scatter event IDs through production code. The old resqlite profile runner
should not be removed until tracelite artifacts prove parity for operation
counts, rows/cells decoded, stream invalidation cost, reader-pool pressure, and
diagnostic snapshots.

### 5. Portability is still macOS-first

The current shim validation is macOS-oriented. Linux `LD_PRELOAD`, Windows
substitution, and CI coverage for those paths are still required before this can
be called production-quality across Dart targets.

## Recommended next iteration

1. Run `tracelite suite --profile=production` for the full peer matrix and keep
   the generated artifacts as the first baseline set.
2. Run the new reactive and diagnostics scenarios at production-like parameter
   sizes with repetitions.
3. Add a generated/table-registry-aware drift reactive adapter or document drift
   as unsupported for the optional reactive lane.
4. Run old resqlite profile artifacts and tracelite artifacts side by side for
   the same workloads.
5. Remove only the resqlite profile surfaces that have proven tracelite parity.
