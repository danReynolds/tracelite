# tracelite graph-data export

Status: first implementation-backed export, 2026-05-10

This document defines the boundary between tracelite artifacts and project
dashboards such as resqlite's GitHub Pages benchmark site.

## Architecture

Tracelite does not provide embeddable UI components for resqlite. Resqlite owns
its site shell, navigation, charts, copy, and experiment pages.

Tracelite owns the benchmark/profiling data contract:

- compare artifacts;
- suite manifests;
- decision artifacts;
- workload summaries;
- graph-ready JSON derived from those artifacts.

The standalone tracelite visualizer, when built, should be an inspector for
`.tlt-region` files and artifact bundles. It should be used like DevTools or
Perfetto: open a trace, inspect it deeply, and debug. It is not a component
library for downstream GitHub Pages sites.

## Command

```bash
dart run bin/tracelite.dart export-graph-data \
  --suite=build/tracelite-suite/manifest.json \
  --decision=build/decision.json \
  --workload-summary=build/profile-summary.json \
  --run-id=exp-001 \
  --out=docs/benchmarks/data/tracelite/exp-001
```

Validate a bundle before publishing it to a downstream dashboard:

```bash
dart run bin/tracelite.dart validate-graph-data docs/benchmarks/data/tracelite/exp-001
```

`export-graph-data` runs the same validation before it returns successfully,
so downstream repositories can treat a completed export as a schema-checked
artifact handoff.

Inputs are optional but at least one input must be present:

- `--compare=compare.json`, repeated `--compare` flags, or comma-separated
  compare artifacts.
- `--suite=manifest.json`, repeated `--suite` flags, or comma-separated suite
  manifests.
- `--suite-history=history.json`, repeated `--suite-history` flags, or
  comma-separated suite-history manifests.
- `--decision=decision.json`, repeated `--decision` flags, or comma-separated
  decision artifacts.
- `--workload-summary=summary.json`, repeated `--workload-summary` flags, or
  comma-separated workload summaries.

Suite manifests and suite-history manifests are expanded into their referenced
compare artifacts.

## Output

The output directory contains an index plus one file per graphable dataset:

```text
index.json
scenario-series.json
peer-summary.json
decision-summary.json
decision-comparisons.json
workload-summary.json
workload-operations.json
workload-memory.json
workload-fanout.json
```

`index.json` uses schema `tracelite.graph_data.v1` and contains:

- `run_id`
- `sources`
- `files`
- per-dataset row counts

Each dataset file uses schema `tracelite.graph_dataset.v1` and contains:

- `dataset`
- `run_id`
- `rows`

The row arrays are intentionally plain and denormalized so static sites can
chart them without knowing the full internal compare, decision, or workload
schemas.

## Datasets

| Dataset | Purpose |
|---|---|
| `scenario_series` | Long-form scenario/peer/metric/statistic/value rows for charts. |
| `peer_summary` | One row per scenario and peer, with common benchmark columns including measured elapsed time, scenario elapsed time, SQLite step count/time, event volume, and trace health. |
| `decision_summary` | One row per decision artifact, including policy and gate statuses. |
| `decision_comparisons` | Primary, guardrail, and trace-health rows for badges/tables. |
| `workload_summary` | One row per semantic workload in a workload-summary artifact. |
| `workload_operations` | Long-form workload operation metrics such as `median_us`, `p99_us`, and `work_us_median`. |
| `workload_memory` | Flattened RSS, diagnostic, and profile-counter memory rows. |
| `workload_fanout` | Long-form many-streams fanout metric/statistic/value rows. |

## Resqlite Pages consumption

Resqlite Pages should read these JSON files and render its own UI. It should
not parse `.tlt-region` files and should not embed tracelite UI code.

Recommended Pages mapping:

- Scenario charts read `scenario-series.json`.
- Peer tables read `peer-summary.json`.
- Experiment outcome badges read `decision-summary.json`.
- Regression and guardrail tables read `decision-comparisons.json`.
- Legacy profile parity charts read `workload-operations.json` and
  `workload-memory.json`.
- Many-streams fanout charts read `workload-fanout.json`.

Raw trace regions should be linked as downloadable evidence or opened in the
future tracelite inspector. They should not be the public dashboard data model.
