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
| Markdown/JSON profile reporting | `tracelite compare`, `tracelite suite`, and `tracelite diff` artifacts | The resqlite profile matrix has a tracelite suite manifest and experiment logs no longer need resqlite-local reporters. |
| A/B profile diffing | `tracelite diff` repetition gates | Existing baseline/candidate examples produce the same direction or `too_noisy` where the old diff was unstable. |
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
4. Delete only surfaces in the replacement bucket whose parity row is complete.
5. Leave a short resqlite PR note naming the tracelite artifact path and the
   old profile artifact path used as evidence.

## Current state

- Ready to replace first: report generation, repetition artifact storage,
  low-value wall-time wrappers, and Timeline-style markers once the side-by-side
  matrix is captured.
- Not ready to delete yet: `ProfileCounters`, stream/reader/decode counters,
  and diagnostics import points. These now have tracelite helper APIs, but
  resqlite still needs to adopt and prove them.
- Not a deletion target: benchmark workload definitions, public diagnostics,
  native diagnostics helpers, and the trace-enabled embedded SQLite build hook.
