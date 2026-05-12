# resqlite capability demo, 2026-05-12

Status: local run against resqlite PR #109 hook worktree

This run checks whether tracelite is useful as the primary resqlite profiling
path before publication, using local dependency overrides.

## Hypothesis

tracelite should do more than reproduce the old resqlite profile JSON. A useful
replacement run should show:

- old-profiler parity for workload timings, memory, diagnostics, and counters;
- graph-ready data that resqlite Pages can consume directly;
- cross-library attribution for realistic SQLite workload shapes;
- reactive workload attribution that the old resqlite-local profiler could not
  compare across peers;
- trace health, SQLite call counts, and semantic resqlite spans in the same
  artifact.

## Local wiring

The tracelite checkout used a temporary local override:

```yaml
dependency_overrides:
  resqlite:
    path: /Users/dan/.codex/worktrees/tracelite-resqlite-hooks
```

The override points at the trace-enabled resqlite worktree for PR #109.

## Commands

```bash
/Users/dan/Coding/flutter_arm64/bin/dart run benchmark/profile/run_tracelite_profile.dart \
  --tracelite-root=/Users/dan/Coding/tracelite \
  --dart=/Users/dan/Coding/flutter_arm64/bin/dart \
  --label=capability-demo-profile-20260512 \
  --out-dir=/tmp/resqlite-tracelite-capability-demo-profile-20260512 \
  --graph-data-dir=/tmp/resqlite-tracelite-capability-demo-graph-data-20260512

/Users/dan/Coding/flutter_arm64/bin/dart run bin/tracelite.dart compare \
  --scenario=feed-paging \
  --interfaces=sqlite3,drift,sqlite_async,resqlite \
  --rows=64 \
  --repetitions=5 \
  --out-json=/tmp/tracelite-capability-demo-feed-paging-20260512.json

/Users/dan/Coding/flutter_arm64/bin/dart run bin/tracelite.dart compare \
  --scenario=many-streams-writer-throughput \
  --interfaces=sqlite_async,resqlite \
  --rows=8 \
  --repetitions=5 \
  --out-json=/tmp/tracelite-capability-demo-many-streams-20260512.json
```

The combined graph-data export used a suite manifest containing both compare
artifacts plus the resqlite workload summary:

```bash
/Users/dan/Coding/flutter_arm64/bin/dart run bin/tracelite.dart export-graph-data \
  --suite=/tmp/tracelite-capability-demo-suite-20260512.json \
  --workload-summary=/tmp/resqlite-tracelite-capability-demo-profile-20260512/workload-summary.json \
  --run-id=capability-demo-20260512 \
  --out=/tmp/tracelite-capability-demo-graph-data-suite-20260512

/Users/dan/Coding/flutter_arm64/bin/dart run bin/tracelite.dart validate-graph-data \
  /tmp/tracelite-capability-demo-graph-data-suite-20260512
```

## Profile parity

The resqlite profile wrapper produced:

- legacy profile JSON;
- raw tracelite region;
- tracelite workload summary JSON and markdown;
- graph-data bundle;
- parity diff against the legacy profile JSON.

The parity diff reported exact matches for the old-compatible fields:

| workload | old-compatible result |
|---|---|
| `noop` | exact timing, RSS, SQLite diagnostics, noop floors |
| `single_insert` | exact timing, RSS, SQLite diagnostics |
| `point_query` | exact timing, RSS, SQLite diagnostics |
| `merge_rounds` | exact timing, RSS, SQLite diagnostics |

The graph-data bundle validated and contained:

| dataset | rows |
|---|---:|
| `workload_summary` | 4 |
| `workload_operations` | 41 |
| `workload_memory` | 132 |

## New resqlite-local insight

The old profiler reported workload summaries. The tracelite report also showed
where those timings landed in resqlite:

| span | count | p50 | p90 | total |
|---|---:|---:|---:|---:|
| `resqlite.database.select` | 60050 | 9us | 17us | 895ms |
| `resqlite.reader_pool.dispatch` | 60050 | 8us | 15us | 830ms |
| `resqlite.reader.handle` | 60050 | 4us | 8us | 443ms |
| `resqlite.database.execute` | 20252 | 17us | 26us | 431ms |
| `resqlite.writer.handle` | 21254 | 10us | 21us | 354ms |
| `resqlite.database.execute_batch` | 1001 | 92us | 144us | 121ms |

For `point_query`, tracelite also carried semantic counters and diagnostics in
the same trace:

| signal | value |
|---|---:|
| select samples | 50000 |
| rows decoded | 50000 |
| cells decoded | 300000 |
| RSS delta | 22.937 MB |
| SQLite statement bytes delta | 0 |
| WAL bytes delta | 0 |

This is the first clear replacement shape: keep narrow semantic emitters in
resqlite, but let tracelite own grouping, reporting, graph export, and parity
diff inputs.

## Cross-library feed-paging

`feed-paging` is a shared SQL workload across sqlite3, drift, sqlite_async, and
resqlite.

| peer | scenario mean | measured mean | sqlite3_step count | sqlite3_step time | trace health |
|---|---:|---:|---:|---:|---|
| sqlite3 | 37.5ms | 5.67ms | 138 | 3.84ms | 0/0/0 |
| drift | 46.6ms | 4.65ms | 140 | 3.57ms | 0/0/0 |
| sqlite_async | 48.4ms | 5.84ms | 145 | 5.34ms | 0/0/0 |
| resqlite | 306ms | 3.99ms | 143 | 1.08ms | 0/0/0 |

The important insight is the split between scenario elapsed and measured
elapsed. The console table makes resqlite look slow because scenario elapsed
includes setup/warmup shape. The measured workload phase is competitive, and
the SQLite step count proves the peers are doing comparable SQL work. That
suggests the report should promote `measured_elapsed_ns` more prominently for
experiment decisions.

## Reactive many-streams writer throughput

`many-streams-writer-throughput` compares reactive peers only.

| peer | scenario mean | measured mean | sqlite3_step count | sqlite3_step time | events | trace health |
|---|---:|---:|---:|---:|---:|---|
| sqlite_async | 702ms | 587ms | 53423 | 86.2ms | 645142 | 0/0/0 |
| resqlite | 905ms | 543ms | 7830 | 10.2ms | 95604 | 0/0/0 |

For the first resqlite sample, the trace showed:

| SQLite span | resqlite count | sqlite_async count |
|---|---:|---:|
| `sqlite3_step` | 8173 | 53423 |
| `sqlite3_prepare_v3` | 13 | 623 |
| `sqlite3_column_text` | 14400 | 104000 |
| `sqlite3_column_int64` | 7200 | 52001 |
| `sqlite3_column_bytes` | 14400 | 104000 |

This is the clearest new capability. The old resqlite profiler could say what
resqlite did. It could not show that, under the same reactive workload,
resqlite used far fewer SQLite calls and less SQLite step time than
sqlite_async while still exposing measured workload time, event volume, and
trace health.

## What to highlight

For a demo or production-readiness write-up, highlight these capabilities:

1. Parity: old profile summary fields can be derived from tracelite with exact
   parity for the covered workloads.
2. Layer attribution: public operation, dispatch, worker, and SQLite spans are
   visible together.
3. Workload phase split: setup/warmup/measured time prevents misleading
   conclusions from headline scenario elapsed alone.
4. SQLite call accounting: `sqlite3_step`, prepare, bind, column, reset, and
   finalize counts expose whether a regression is SQL volume, SQLite runtime,
   or library overhead.
5. Reactive comparison: reactive scenarios can compare resqlite and peers while
   unsupported libraries are explicit rather than forced into the lane.
6. Graph-data handoff: one validated export can feed resqlite Pages without
   resqlite consuming tracelite UI code.

## Follow-up changes suggested by this run

- Make `measured_elapsed_ns` a first-class column in compare reports and
  graph-data dashboards. Keep scenario elapsed, but treat measured elapsed as
  the default experiment metric.
- Improve `export-graph-data` CLI ergonomics for multiple compare artifacts.
  The suite manifest path works, but repeated `--compare` currently keeps only
  the last value.
- Add a named "capability demo" or "profile replacement demo" command/profile
  that runs the old-parity wrapper plus one shared SQL scenario and one
  reactive scenario.
- Use this artifact shape for the first real resqlite experiment: baseline and
  candidate compare artifacts, `tracelite decision`, validated graph-data, and
  the raw trace region preserved out of `docs/`.

## Verdict

This run supports moving tracelite to the primary profiling path. It proves
old-profile parity and shows materially better attribution than the old
resqlite-local profiler. The remaining work is not signal capture; it is
runner ergonomics, report defaults, and turning this demo shape into the
standard experiment workflow.
