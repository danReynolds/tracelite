# tracelite profiling decision standard

Status: first implementation-backed standard, 2026-05-10

This document defines how tracelite artifacts should be used to accept,
reject, or mark performance experiments as inconclusive. The standard applies
to resqlite and to peer-library benchmark work where tracelite can produce
compare or suite artifacts.

## Required artifact set

Every production-quality experiment should preserve:

- The baseline compare artifact or suite manifest.
- The candidate compare artifact or suite manifest.
- The `tracelite decision` JSON artifact.
- The markdown decision report.
- The raw `.tlt-region` files when the run includes external workload traces
  such as resqlite profile regions.
- The commit SHAs, package versions, device, OS, Dart/Flutter version, scenario
  parameters, warmups, repetitions, and threshold policy embedded in the
  artifacts or experiment write-up.

Console output is not enough. The durable artifact is the evidence.

## Command

For an experiment expected to improve resqlite:

```bash
dart run bin/tracelite.dart decision \
  --baseline=build/baseline/manifest.json \
  --candidate=build/candidate/manifest.json \
  --expect=improvement \
  --primary-peer=resqlite \
  --primary-metric=elapsed_ns \
  --primary-threshold-percent=5 \
  --max-regression-percent=3 \
  --max-cv-percent=15 \
  --out-json=build/decision.json \
  > build/decision.md
```

For a regression guard in CI or release checks:

```bash
dart run bin/tracelite.dart decision \
  --baseline=build/main/manifest.json \
  --candidate=build/pr/manifest.json \
  --expect=no_regression \
  --primary-peer=resqlite \
  --primary-metric=elapsed_ns
```

The command accepts either single `tracelite.compare.v1` artifacts or
`tracelite.suite.v1` manifests. It exits `0` only for an accepted decision.
Rejected and inconclusive decisions exit non-zero.

## Gates

### Trace health

The candidate and baseline must have usable traces. Failed, no-trace, or
trace-diagnostic peer results reject the decision unless the peer is unsupported
on both sides of a capability-specific scenario.

### Primary metric

The primary peer, scenario set, and metric define the hypothesis under test.

For `--expect=improvement`, every primary comparison must be:

- larger than the configured improvement threshold in the right direction;
- below the maximum CV threshold;
- statistically clear by both the mean-delta confidence interval and
  Mann-Whitney repetition evidence.

For `--expect=no_regression`, neutral and improved primary comparisons pass,
while statistically clear regressions reject.

### Guardrails

Guardrail metrics default to:

- `elapsed_ns`
- `measured_elapsed_ns`
- `sqlite3_step_total_ns`
- `trace_span_total_ns`
- `dropped_events`
- `unmatched_begin_events`
- `unmatched_end_events`

Guardrails reject clear regressions larger than `--max-regression-percent`.
Noisy or undersampled guardrails make the decision inconclusive. Unsupported or
missing optional guardrail metrics are skipped; missing primary evidence is not.

## Outcomes

| Decision | Meaning |
|---|---|
| `accepted` | The primary hypothesis cleared the threshold/noise/statistical gates and guardrails stayed clean. |
| `rejected` | The primary metric regressed, trace health failed, or a guardrail showed a clear regression. |
| `inconclusive` | The signal was neutral, too noisy, undersampled, or missing required primary evidence. |

Experiment write-ups should use the same vocabulary. A result that is only
"probably better" is inconclusive until the artifact clears the gate.

## Standard lanes

Use these lanes as the default suite boundaries:

| Lane | Purpose |
|---|---|
| SQL core | Shared SQLite execution across `sqlite3`, `drift`, `sqlite_async`, and `resqlite`. |
| Resqlite profile | `noop`, `single_insert`, `point_query`, `merge_rounds`, and follow-on resqlite profile workloads through `workload-summary`. |
| Reactive | Keyed subscriptions, high-cardinality fanout, many-stream writer throughput, invalidation/intersection cost. |
| Memory | RSS before/after/peak, SQLite page-cache/schema/stmt/WAL bytes, decoded rows/cells. |
| Stress | Larger row counts, stream churn, high concurrency, and longer repetition stability. |

The common SQL lane should stay SQL-only. Reactive and diagnostic lanes should
remain capability-aware so unsupported peers are explicit instead of faked.

## Experiment write-up rule

Accepted experiments should state:

> This hypothesis improved metric X by Y, cleared the noise/statistical gates,
> did not regress guardrails, and the trace attributes the change to Z.

Rejected or inconclusive experiments should still be preserved when they teach
something useful:

> The result was rejected or inconclusive because of noise, insufficient
> repetitions, missing trace health, excessive complexity, or guardrail cost.
