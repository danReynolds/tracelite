# resqlite side-by-side parity run

Date: 2026-05-09

## Inputs

Tracelite commit under test:

- `e9a2641 Harden production benchmark readiness` plus the follow-up local
  sparse-region and external-region changes in this pass.

Resqlite branches under test:

- Main checkout for the old profile artifact:
  `/Users/dan/Coding/resqlite`
- PR #109 semantic tracelite hook branch:
  `/Users/dan/.codex/worktrees/tracelite-resqlite-hooks`

Artifacts:

- `build/tracelite-production-suite/manifest.json`
- `build/resqlite-parity/old-run-profile.json`
- `build/resqlite-parity/pr109-run-profile.json`
- `build/resqlite-parity/pr109-run-profile.tlt-region`
- `build/resqlite-parity/pr109-tracelite-report.md`
- `build/resqlite-parity/pr109-many-streams.tlt-region`
- `build/resqlite-parity/pr109-many-streams-report.md`
- `build/resqlite-parity/pr109-many-streams-profile_*.json`

## Commands

```bash
dart run bin/tracelite.dart suite \
  --profile=production \
  --interfaces=sqlite3,drift,sqlite_async,resqlite \
  --out-dir=build/tracelite-production-suite

/Users/dan/Coding/flutter_arm64/bin/dart run \
  -DRESQLITE_PROFILE=true \
  benchmark/run_profile.dart \
  --out=/Users/dan/Coding/tracelite/build/resqlite-parity/old-run-profile.json

dart run bin/tracelite.dart create-region \
  --out=build/resqlite-parity/pr109-run-profile.tlt-region \
  --ring-data-words=4194304 \
  --max-producers=8

TRACELITE_REGION=/Users/dan/Coding/tracelite/build/resqlite-parity/pr109-run-profile.tlt-region \
TRACELITE_RUNTIME=/Users/dan/Coding/tracelite/build/libtracelite_runtime.dylib \
/Users/dan/Coding/flutter_arm64/bin/dart run \
  -DRESQLITE_PROFILE=true \
  -DRESQLITE_TRACELITE=true \
  benchmark/run_profile.dart \
  --out=/Users/dan/Coding/tracelite/build/resqlite-parity/pr109-run-profile.json

dart run bin/tracelite.dart report \
  build/resqlite-parity/pr109-run-profile.tlt-region \
  > build/resqlite-parity/pr109-tracelite-report.md

dart run bin/tracelite.dart create-region \
  --out=build/resqlite-parity/pr109-many-streams.tlt-region \
  --ring-data-words=4194304 \
  --max-producers=8

TRACELITE_REGION=/Users/dan/Coding/tracelite/build/resqlite-parity/pr109-many-streams.tlt-region \
TRACELITE_RUNTIME=/Users/dan/Coding/tracelite/build/libtracelite_runtime.dylib \
/Users/dan/Coding/flutter_arm64/bin/dart run \
  -DRESQLITE_PROFILE=true \
  -DRESQLITE_TRACELITE=true \
  benchmark/profile/many_streams_writer_profile.dart \
  --out=/Users/dan/Coding/tracelite/build/resqlite-parity/pr109-many-streams-profile

dart run bin/tracelite.dart report \
  build/resqlite-parity/pr109-many-streams.tlt-region \
  > build/resqlite-parity/pr109-many-streams-report.md
```

## Results

The refreshed production suite passed every scenario:

| Scenario | Status |
|---|---|
| `narrow-batch-insert` | ok |
| `point-select` | ok |
| `feed-paging` | ok |
| `sync-burst` | ok |
| `chat-sim` | ok |
| `large-working-set` | ok |
| `keyed-pk-subscriptions` | ok |
| `high-cardinality-fanout` | ok |
| `many-streams-writer-throughput` | ok |
| `sqlite-diagnostics` | ok |

The first production attempt exposed a real tracelite hardening issue: the two
large reactive scenarios overflowed sqlite_async's trace ring. This pass fixed
that by increasing ring sizing and making region files sparse. After the fix,
both scenarios passed with `0/0/0` trace diagnostics.

The PR #109 resqlite semantic trace captured:

| Signal | Value |
|---|---:|
| events | 565,520 |
| producers | 6 |
| dropped / unmatched begin / unmatched end | 0 / 0 / 0 |
| `resqlite.profile.workload` spans | 4 |
| `resqlite.database.select` spans | 60,050 |
| `resqlite.reader_pool.dispatch` spans | 60,050 |
| `resqlite.reader.handle` spans | 60,050 |
| `resqlite.database.execute` spans | 20,252 |
| `resqlite.writer.handle` spans | 21,254 |
| `resqlite.database.execute_batch` spans | 1,001 |
| latest `resqlite.rows_decoded` | 60,000 |
| latest `resqlite.cells_decoded` | 310,000 |

The generic tracelite report now groups the profile trace by explicit resqlite
workload spans:

| Workload | Iterations | Samples | Trace duration |
|---|---:|---:|---:|
| `noop` | 100 | 20,000 | 278 ms |
| `single_insert` | 100 | 10,000 | 195 ms |
| `point_query` | 100 | 50,000 | 452 ms |
| `merge_rounds` | 100 | 1,000 | 108 ms |

Per-workload diagnostic gauges also appear in the trace report:

| Gauge family | Samples |
|---|---:|
| `resqlite.sqlite_page_cache_bytes` | 8 |
| `resqlite.sqlite_schema_bytes` | 8 |
| `resqlite.sqlite_stmt_bytes` | 8 |
| `resqlite.wal_bytes` | 8 |
| `resqlite.stream_count` | 8 |
| `resqlite.reader_busy` | 8 |

The old profile JSON and PR #109 profile JSON agree on the core profile sample
counts and decode totals:

| Workload | Old profile samples | PR #109 profile samples | Counter parity |
|---|---:|---:|---|
| `noop` select | 10,000 | 10,000 | rows 10,000 / cells 10,000 |
| `noop` execute | 10,000 | 10,000 | n/a |
| `single_insert` execute | 10,000 | 10,000 | n/a |
| `point_query` select | 50,000 | 50,000 | rows 50,000 / cells 300,000 |
| `merge_rounds` executeBatch | 1,000 | 1,000 | n/a |

The stream/reactive parity probe also produced a clean tracelite report:

| Signal | Value |
|---|---:|
| events | 102,940 |
| producers | 6 |
| dropped / unmatched begin / unmatched end | 0 / 0 / 0 |
| `resqlite.profile.workload` spans | 3 |
| `resqlite.stream.invalidate` spans | 4,000 |
| `resqlite.reader_pool.dispatch` spans | 13,406 |
| `resqlite.reader.handle` spans | 13,406 |
| `resqlite.database.execute` spans | 6,001 |

The many-streams workload grouping preserved the old harness's scenario
boundaries:

| Workload | Iterations | Samples | Trace duration |
|---|---:|---:|---:|
| `baseline` | 3 | 1,500 | 73.8 ms |
| `disjoint` | 3 | 1,500 | 273 ms |
| `overlap` | 3 | 1,500 | 363 ms |

The grouped stream trace includes the old invalidation/intersection/dispatcher
counters for the stream-heavy scenarios. For example, `overlap` reports 1,500
`resqlite.stream.invalidate` spans and 1,500 samples each for
`resqlite.invalidate_us`, `resqlite.invalidate_count`,
`resqlite.intersection_us`, and `resqlite.intersection_entries`.

## Deletion Decision

No broad resqlite profiling deletion is justified yet, but the deletion gate is
materially closer.

What is proven:

- The four-peer tracelite production matrix can now run to completion.
- PR #109's semantic event path is active, low-noise, and captures database,
  reader-pool, reader-worker, writer-worker, and decode counter signals.
- Decode counter totals mirror the old profile counter totals for the profile
  runner workloads.
- Explicit resqlite workload spans now let tracelite exclude setup/warmup from
  the profile summary and preserve old profile workload names.
- Per-workload SQLite diagnostics snapshots are now visible as correlated
  tracelite gauges.
- Stream invalidation and reader-pool pressure signals are visible in a
  tracelite report for the many-streams writer profile.

What blocks deletion:

- The old profile JSON still owns derived experiment fields: noop-floor
  subtraction, `work_us`, RSS deltas, per-operation sample distributions, and
  old-profile diff compatibility.
- The many-streams harness still emits custom per-write JSON for fanout deltas.
  Tracelite now has the spans and counters, but it does not yet export the
  old harness's derived `writer_us` / `yield_us` / `total_us` tables.
- RSS memory capture is still process-local JSON, not a tracelite counter or
  gauge.
- Downstream resqlite experiment tooling still consumes the old profile JSON
  shape, so deleting it before adding a tracelite summary/export path would
  break the experiment workflow.

## Next Required Slice

1. Add a tracelite workload-summary export that can replace the old resqlite
   profile JSON fields consumed by experiment diffs.
2. Add RSS/peak-RSS counters or explicitly document RSS as the remaining
   resqlite-local signal.
3. Port the many-streams fanout-delta table to tracelite-derived summaries or
   keep that harness as a temporary specialized profile.
4. Re-run baseline/candidate A/B artifacts through `tracelite diff`.
5. Delete only the old profile surfaces whose parity rows are then complete.
