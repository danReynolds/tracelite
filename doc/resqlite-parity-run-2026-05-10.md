# resqlite workload-summary parity run

Date: 2026-05-10

## Scope

This run closes the remaining resqlite profile-replacement gap from the
2026-05-09 pass: export/workflow compatibility. The goal was to prove that a
tracelite trace can produce the same practical artifact shape consumed by
resqlite's existing profile diff workflow.

## What changed

- Added `tracelite workload-summary <region> --out-json=...`.
- Added `resqlite.profile.sample` spans so tracelite can export exactly the
  same measured call samples as `ProfiledDatabase`, excluding raw cleanup/setup
  database calls inside a workload scope.
- Added correlated RSS gauges:
  - `resqlite.rss_before_bytes`
  - `resqlite.rss_after_bytes`
  - `resqlite.rss_peak_bytes`
- Added correlated profile-counter snapshots:
  - `resqlite.profile.rows_decoded`
  - `resqlite.profile.cells_decoded`
  - stream invalidation and dispatcher profile counters
- Added fanout sample counters for the many-streams profile:
  - `resqlite.fanout.writer_us`
  - `resqlite.fanout.yield_us`
  - `resqlite.fanout.total_us`
  - `resqlite.fanout.invalidate_us`
  - `resqlite.fanout.intersection_us`
  - `resqlite.fanout.intersection_entries`

## Artifacts

- `build/resqlite-parity/parity-traced-run-profile.json`
- `build/resqlite-parity/parity-run-profile.tlt-region`
- `build/resqlite-parity/parity-workload-summary.json`
- `build/resqlite-parity/parity-workload-summary.md`
- `build/resqlite-parity/parity-many-streams.tlt-region`
- `build/resqlite-parity/parity-many-streams-summary.json`
- `build/resqlite-parity/parity-many-streams-profile_2026-05-10T09-23-55.json`

## Commands

```bash
dart run bin/tracelite.dart create-region \
  --out=build/resqlite-parity/parity-run-profile.tlt-region \
  --ring-data-words=4194304 \
  --max-producers=8

TRACELITE_REGION=/Users/dan/Coding/tracelite/build/resqlite-parity/parity-run-profile.tlt-region \
TRACELITE_RUNTIME=/Users/dan/Coding/tracelite/build/libtracelite_runtime.dylib \
/Users/dan/Coding/flutter_arm64/bin/dart run \
  -DRESQLITE_PROFILE=true \
  -DRESQLITE_TRACELITE=true \
  benchmark/run_profile.dart \
  --out=/Users/dan/Coding/tracelite/build/resqlite-parity/parity-traced-run-profile.json

dart run bin/tracelite.dart workload-summary \
  build/resqlite-parity/parity-run-profile.tlt-region \
  --out-json=build/resqlite-parity/parity-workload-summary.json \
  > build/resqlite-parity/parity-workload-summary.md

/Users/dan/Coding/flutter_arm64/bin/dart run benchmark/profile/diff.dart \
  /Users/dan/Coding/tracelite/build/resqlite-parity/parity-traced-run-profile.json \
  /Users/dan/Coding/tracelite/build/resqlite-parity/parity-workload-summary.json
```

## Profile JSON parity

The existing resqlite profile diff tool accepts the tracelite-generated
`parity-workload-summary.json` and reports no meaningful deltas against the
old `benchmark/run_profile.dart` JSON emitted from the same traced run.

| Workload | Field family | Result |
|---|---|---|
| `noop` | `select` / `execute` p50, p90, p99, max | exact |
| `single_insert` | `execute` p50, p90, p99, max, `work_us` | exact |
| `point_query` | `select` p50, p90, p99, max, `work_us` | exact |
| `merge_rounds` | `executeBatch` p50, p90, p99, max, `work_us` | exact |
| all profile workloads | RSS delta | exact to exported MB precision |
| all profile workloads | SQLite diagnostic deltas | exact |
| `noop` | reader/writer dispatch floors | exact |

The summary JSON also preserves old-style raw sample lists for profile
workloads. It derives these from `resqlite.profile.sample` spans, not from
lower-level database spans, so cleanup calls such as per-iteration
`db.raw.execute(...)` do not contaminate the sample table.

## Many-streams fanout parity

The many-streams trace summary was compared against the old raw custom JSON.
For each scenario, tracelite summary medians matched the raw profile medians:

| Scenario | writer_us | yield_us | total_us | invalidate_us | intersection_us | intersection_entries |
|---|---:|---:|---:|---:|---:|---:|
| `baseline` | exact | exact | exact | exact | exact | exact |
| `disjoint` | exact | exact | exact | exact | exact | exact |
| `overlap` | exact | exact | exact | exact | exact | exact |

## Decision

The profile-replacement parity gate is now satisfied for the current resqlite
profile surfaces:

- operation samples and summaries
- noop floor subtraction / `work_us`
- RSS before/after/peak/delta
- SQLite diagnostics before/after/delta
- decoder/profile counter deltas
- many-streams fanout summaries
- existing `benchmark/profile/diff.dart` compatibility

The remaining work is migration cleanup, not parity discovery: wire resqlite's
profile workflow to consume `tracelite workload-summary`, then delete the old
resqlite-local report/diff/storage surfaces that are now covered.
