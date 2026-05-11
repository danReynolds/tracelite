# resqlite profiling replacement checklist

Status: production-readiness checklist, 2026-05-09

This is the deletion gate for moving profiling weight out of resqlite and into
tracelite. The goal is not to delete every resqlite signal. The goal is to
delete report/storage/timing machinery from resqlite while keeping only narrow
semantic emitters and diagnostics that tracelite cannot infer generically.

## Replacement buckets

| resqlite surface | Replacement target | Delete when |
|---|---|---|
| `ProfiledDatabase` wall-time wrappers | `resqlite.database.execute`, `resqlite.database.execute_batch`, `resqlite.database.select`, and `resqlite.database.select_bytes` spans | Tracelite artifacts group by operation tag/fingerprint and match old operation counts. |
| Markdown/JSON profile reporting | `tracelite compare`, `tracelite suite`, `tracelite workload-summary`, and `tracelite decision` artifacts | The resqlite profile matrix has a tracelite suite/workload-summary manifest and experiment logs no longer need resqlite-local reporters. |
| A/B profile diffing | `tracelite decision` primary and guardrail gates, with `tracelite diff` as the exploratory detail view | Existing baseline/candidate examples produce accepted/rejected/inconclusive decisions with the same direction or stricter `inconclusive` outcomes where the old diff was unstable. |
| Benchmark dashboard JSON | `tracelite export-graph-data` datasets | GitHub Pages can render scenario, peer, decision, workload, memory, and fanout rows from tracelite graph data without bespoke benchmark JSON transforms. |
| `Timeline.startSync` worker markers | `resqlite.writer.handle`, `resqlite.reader.handle`, and `resqlite.reader_pool.dispatch` spans | Worker timing is visible in traces with correlation IDs from public operation boundary to worker handling. |
| Stream invalidation counters | `recordResqliteStreamMetrics` plus stream spans | Invalidation count/time, intersection time, and intersection entries match the old profile counters. |
| Reader-pool pressure counters | `recordResqliteDispatcherMetrics` | Parked total, wake retry total, current parked, and max parked concurrent match the old profile counters. |
| Decode/materialization counters | `recordResqliteDecodeMetrics` | Row and cell counts match old `ProfileCounters` for select/selectBytes workloads. |
| SQLite memory/WAL snapshots | `recordResqliteDiagnostics` importing `Database.diagnostics()` | Snapshot values appear in tracelite artifacts; the public resqlite diagnostics API remains. |

## Keep in resqlite

- Benchmark workload definitions and fixtures.
- Public `Database.diagnostics()`.
- Native `resqlite_db_status_total` and WAL-size probing.
- The trace-enabled native build hook for embedded sqlite3mc.
- Small opt-in semantic emitters guarded by the same profile/tracing discipline
  used today.

## Parity matrix

Each row should run through the old resqlite profiler and through tracelite with
the same workload parameters.

| Workload family | Required parity |
|---|---|
| execute / executeBatch | Operation counts, batch sizes, parameter counts, writer spans, SQLite call counts. |
| select / selectBytes | Operation counts, rows decoded, cells decoded, reader spans, SQLite step/column counts. |
| stream invalidation | Stream invalidation count/time, dependency intersection count/time, select-if-changed spans, emissions. |
| reader-pool pressure | Dispatch spans, parked totals, wake retries, current/max parked gauges. |
| SQLite diagnostics | Page-cache bytes, schema bytes, statement bytes, WAL bytes, stream count, reader-busy state. |
| cross-library baseline | Same tracelite workload over `sqlite3`, `drift`, `sqlite_async`, and `resqlite`, with unsupported reactive lanes explicit. |

## Procedure

1. Generate a tracelite baseline:

   ```bash
   dart run bin/tracelite.dart suite \
     --profile=production \
     --interfaces=sqlite3,drift,sqlite_async,resqlite \
     --out-dir=build/tracelite-production-suite
   ```

2. Run the matching old resqlite profile matrix from the resqlite checkout.
3. Compare sample counts, semantic counters, diagnostics snapshots, and timing
   direction before looking at deletion.
4. Run `tracelite decision` over the baseline/candidate artifacts and use the
   accepted/rejected/inconclusive vocabulary in the experiment write-up.
5. Run `tracelite export-graph-data` for any run that should appear in
   resqlite's GitHub Pages benchmark views.
6. Delete only surfaces in the replacement bucket whose parity row is complete.
7. Leave a short resqlite PR note naming the tracelite artifact path and the
   old profile artifact path used as evidence.

## Current state

- Ready to replace first: generic report generation, repetition artifact
  storage, workload-scoped span summaries, low-value wall-time wrappers, and
  Timeline-style worker markers once the resqlite PR adopts the tracelite
  report/export path.
- Not ready to delete yet: old profile JSON/diff compatibility,
  `ProfiledDatabase` sample storage, custom many-streams fanout-delta JSON, and
  RSS memory capture. Tracelite now captures the underlying spans, diagnostics,
  decode counters, stream invalidation counters, and dispatcher counters, but
  it still needs an export that matches the fields consumed by resqlite
  experiments.
- Not a deletion target: benchmark workload definitions, public diagnostics,
  native diagnostics helpers, and the trace-enabled embedded SQLite build hook.

## Latest parity runs

See:

- [`resqlite-parity-run-2026-05-09.md`](resqlite-parity-run-2026-05-09.md)
- [`resqlite-parity-run-2026-05-10.md`](resqlite-parity-run-2026-05-10.md)

Summary:

- The full tracelite production suite now passes after the sparse-region and
  ring-sizing hardening.
- PR #109's tracelite semantic hook path produced a clean trace with 565,520
  events, 6 producers, and `0/0/0` trace diagnostics.
- Decode counter totals matched the old profile runner totals for the profile
  workloads.
- The trace report now groups resqlite profile workloads by name (`noop`,
  `single_insert`, `point_query`, `merge_rounds`) and includes correlated
  per-workload SQLite diagnostic gauges.
- The many-streams writer profile now emits workload spans for `baseline`,
  `disjoint`, and `overlap`; the tracelite report includes stream invalidation,
  intersection, and dispatcher counters with `0/0/0` trace diagnostics.
- The `tracelite workload-summary` command now exports old-compatible resqlite
  profile JSON from traces, including raw profile sample lists, noop floors,
  `work_us`, RSS deltas, SQLite diagnostics, profile counter deltas, and
  many-streams fanout summaries.
- The existing resqlite `benchmark/profile/diff.dart` accepts the
  tracelite-generated workload summary and reports exact parity for the current
  profile workloads.
- The `tracelite decision` command now provides the new accepted/rejected/
  inconclusive decision gate for compare artifacts and suite manifests.
- The `tracelite export-graph-data` command now provides graphable JSON for
  resqlite Pages while keeping all UI ownership in resqlite.

## Current deletion position

The parity gate is now satisfied for the current resqlite profile surfaces.
The next PR slice can wire resqlite's profile workflow to consume
`tracelite workload-summary`, then delete or archive the old resqlite-local
report/diff/storage code that is now covered. Keep the workload definitions,
public diagnostics API, native diagnostics helpers, and tiny semantic emitters.
