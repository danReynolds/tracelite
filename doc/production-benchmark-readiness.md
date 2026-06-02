# Production benchmark replacement readiness

Status: resqlite pre-publish integration pass, updated 2026-06-02

## Verdict

tracelite is accepted as resqlite's current pre-publish benchmark artifact,
attribution, and decision-gating layer. The current resqlite integration has a
top-level `benchmark/run_tracelite.dart` gate, a baseline/candidate
`benchmark/decide_tracelite.dart` decision wrapper, trace-enabled profile
capture, graph-data export for the dashboard, and build-hook smoke coverage for
the native SQLite shim path, and Tracelite insight artifacts for operator
review. PR #109 now pins the Tracelite source state to
`resqlite-profiling-gate-2026-06-01-r2`
(`06c00ac126b54027c14c96deb5634e5a38104973`) and is green at
`98f08c4a1d5e8d877c6b1ef3c11697b42d846d41` with the Tracelite smoke lane
passing. The remaining adoption decision is whether to delete, archive, or keep
the old direct resqlite profile runner as a legacy compatibility/parity harness.

The core direction held up: one trace format can capture sqlite3, drift,
sqlite_async, and trace-enabled resqlite under the same SQLite call model, and
the recorder overhead is small enough for profile-mode instrumentation. The
remaining gap before using tracelite as resqlite's regular workflow is no longer
basic production-gate viability, source reproducibility, or PR CI. The current
resqlite-specific gap is adoption cleanup: resqlite needs to decide which old
profile-only signals are archived versus kept for parity. Tracelite now has a
manual/tagged `Visualizer Release` workflow for macOS, Linux, and Windows
archive/manifest evidence, optional macOS signing/notarization, and release
asset publishing. `tracelite doctor --visualizer-release=...` can now audit
downloaded release manifests against archive size, SHA-256, clean source,
required platform coverage, and macOS signing/notarization evidence; the
remaining distribution gap is a credentialed signed run and published release
artifact. Tracelite's own macOS and Linux CI pin and
verify the trace-enabled resqlite sibling checkout at
`a2e684c6861980e2fbbbc437dd7a4797ae984f2f` before peer tests, so this repo's
gate cannot accidentally benchmark the pub package. Linux now has a focused
package:sqlite3 shim smoke lane and a pinned four-peer `ci` suite in CI. Windows
now validates the platform-independent Dart artifact surface, native runtime
attach, and core CLI surface in CI, but repeated production-profile history and
Windows SQLite-shim tracing remain outside the current evidence set.

The explicit resqlite merge gate is documented in
[`resqlite-sole-profiling-gate.md`](resqlite-sole-profiling-gate.md).

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
- `tracelite suite --profile=ci|experiment|production` now runs a repeatable
  benchmark matrix and writes a suite manifest plus per-scenario compare
  artifacts and logs. `experiment` is the medium repeated preset for
  baseline/candidate work that should not pay the full release-gate cost yet.
- Source-checkout `compare` now records its child runner mode and defaults to
  an app-JIT child runner for repeated or multi-peer runs. `suite` now reuses
  one prepared child runner across the selected scenario matrix, and
  `suite-history` forwards the same runner mode into each independent suite
  run.
- `.github/workflows/ci.yml` now defines the intended macOS and Linux CI
  baseline: generated-span freshness, native runtime/shim build, source-pinned
  resqlite resolution, analysis/tests, publish archive smoke, and the four-peer
  `ci` suite. It assumes a sibling resqlite repository checkout and supports
  `CROSS_REPO_READ_TOKEN` for private installs.
- `tracelite calibrate` measures Dart recorder overhead with body-only,
  disabled-recorder, and active-recorder loops.
- Compare artifacts now include deterministic workload parameters and
  child-process setup, warmup, measured phase timings, and Dart/OS environment
  metadata.
- SQLite prepare calls now use `sqlfp:v1` normalized fingerprints by default,
  and compare samples include `sql_fingerprint_groups` for prepare-cost
  attribution without committing raw SQL literal values.
- `tracelite compare` now exits non-zero when any peer fails, emits no trace, or
  reports dropped/unmatched trace diagnostics.
- The peer harness now includes initial shared-SQL ports of resqlite's
  `feed-paging`, `sync-burst`, `chat-sim`, and scaled `large-working-set`
  workload shapes.
- Compare artifacts now include peer capability metadata and can represent
  unsupported capability-specific scenarios without failing the whole run.
- The peer harness now includes initial reactive ports for keyed PK
  subscriptions, high-cardinality fan-out, and many-stream writer throughput.
  These currently run on `drift`, `sqlite_async`, and `resqlite`; `sqlite3`
  reports unsupported.
- `package:tracelite/resqlite.dart` now includes
  `recordResqliteDecodeMetrics`, `recordResqliteStreamMetrics`,
  `recordResqliteDispatcherMetrics`, and `recordResqliteDiagnostics`, and the
  `sqlite-diagnostics` scenario records resqlite diagnostic snapshots as
  tracelite gauges.
- The trace region writer now creates sparse external region files, and
  `tracelite create-region` can provision a region for external producers such
  as resqlite profile harnesses.
- Reactive production scenarios now size trace rings from the expected event
  count instead of under-provisioning high-event stream workloads.
- The generic markdown report now recognizes `*.profile.workload` spans,
  renders workload-scoped nested span and counter summaries, and shows
  prepare-cost SQL fingerprint groups without raw literal values.
- The resqlite PR bridge now caches interned string IDs so repeated SQL strings
  do not exhaust the tracelite string pool during large profile runs.
- `tracelite workload-summary` now exports old-compatible resqlite profile
  summary JSON from trace regions, including raw measured sample lists,
  noop-floor subtraction, RSS gauges, SQLite diagnostic deltas, profile counter
  deltas, and many-streams fanout summaries.
- `tracelite decision --baseline=... --candidate=...` now turns compare
  artifacts or suite manifests into an accepted/rejected/inconclusive decision
  artifact with trace-health, primary-metric, noise, significance, and
  guardrail gates.
- `tracelite export-graph-data --out=...` now writes normalized JSON datasets
  from compare, suite, decision, and workload-summary artifacts so resqlite
  GitHub Pages can render its own charts without consuming tracelite UI code.
- `tracelite compare` now reports measured workload elapsed time next to
  scenario elapsed time so setup/warmup cost does not obscure the experiment
  metric.
- `tracelite export-graph-data` now accepts `--suite-history=history.json`,
  allowing resqlite's pre-publish gate to publish a complete repeated-suite
  graph-data bundle from a single history manifest.
- `tracelite suite-history` and `calibrate-policy` now support a robust p75
  within-run noise policy plus total and per-run outlier ceilings.
- Source-checkout `compare`, `suite`, `suite-history`, and `calibrate`
  artifacts now record `tracelite_source` with the git revision and dirty
  state, and production/release commands can pass `--require-clean-source=true`
  to fail fast on unauditable local changes.
- resqlite now has `benchmark/run_tracelite.dart`, a package-local wrapper
  around `tracelite suite-history` that fixes the release-gate scope to
  measured elapsed time, resqlite-owned scenarios, bounded threshold/noise
  gates, and dashboard graph-data export.
- `tracelite suite` and `tracelite suite-history` now both honor
  `--scenarios=...` for the actual run matrix, and resqlite's wrapper forwards
  the release-gate scenario list to both suite execution and policy
  calibration.
- resqlite now has `benchmark/decide_tracelite.dart`, a package-local wrapper
  around `tracelite decision` that applies the calibrated release-lane
  `measured_elapsed_ns` policy to baseline/candidate suite manifests and exports
  decision graph data.

## New profiling standard

The canonical standard for regressions and experiments is no longer "inspect
the benchmark output." It is:

1. Run baseline and candidate compare artifacts or suite manifests.
2. Preserve the raw trace regions where available.
3. Run `tracelite decision` with the experiment policy. In resqlite, prefer
   `benchmark/decide_tracelite.dart` so the release-lane policy scope is not
   hand-copied.
4. Run `tracelite export-graph-data` for public dashboard data when the result
   should appear on GitHub Pages.
5. Accept only `accepted`.
6. Preserve `rejected` and `inconclusive` artifacts when they teach something.

The detailed policy is documented in
[`profiling-decision-standard.md`](profiling-decision-standard.md). In short:

- trace health must be clean;
- the primary metric must clear the configured threshold;
- repeated samples must pass CV, confidence-interval, and Mann-Whitney gates;
- guardrail metrics must not show clear regressions;
- missing, neutral, or noisy primary evidence is inconclusive, not accepted.

## Evidence from this pass

### Scoped resqlite production gate, 2026-05-31

Command:

```bash
/Users/dan/Coding/flutter_arm64/bin/dart benchmark/run_tracelite.dart \
  --tracelite-root=/Users/dan/Coding/tracelite \
  --dart=/Users/dan/Coding/flutter_arm64/bin/dart \
  --label=sole-gate-2026-05-31-resqlite-p75-ready-probe \
  --out-dir=build/tracelite-benchmarks/sole-gate-2026-05-31-resqlite-p75-ready-probe \
  --graph-data-dir=build/tracelite-benchmarks/sole-gate-2026-05-31-resqlite-p75-ready-probe/graph-data \
  --runs=5 \
  --interfaces=resqlite
```

Result: every production suite run completed with `ok` status and strict policy
calibration passed. `policy-calibration.json` reported `ready`, 5/5 release
groups ready for `resqlite` on `measured_elapsed_ns`, with a 48% primary
threshold, 36% max regression guardrail, 36% max-CV gate, and 6 recommended
repetitions. The history exported graph data with 7,000 scenario-series rows
and 50 peer-summary rows, and `tracelite validate-graph-data` passed.

The current readiness split keeps unstable workloads visible without letting
them define the release threshold. `feed-paging`, `large-working-set`,
`sync-burst`, `point-select`, and `keyed-pk-subscriptions` remain diagnostic
suite workloads until their workload definitions or separate thresholds are
stable enough for release blocking.

Earlier failed calibrations are intentionally preserved as evidence for this
split. The original broad gate completed every suite run but produced
`not_ready` calibration because `feed-paging`, `large-working-set`, and
`narrow-batch-insert` were too noisy under the 50% ceilings. Later retuned
histories still exposed isolated repetition spikes. The p75/outlier policy and
five-scenario release lane are the current production answer to that evidence,
not a claim that every diagnostic workload is release-ready.

### resqlite baseline/candidate decision, 2026-05-31

Command:

```bash
/Users/dan/Coding/flutter_arm64/bin/dart benchmark/decide_tracelite.dart \
  --tracelite-root=/Users/dan/Coding/tracelite \
  --dart=/Users/dan/Coding/flutter_arm64/bin/dart \
  --baseline=build/tracelite-benchmarks/sole-gate-2026-05-31-resqlite-p75-ready-probe/run-001-20260531T143352Z/manifest.json \
  --candidate=build/tracelite-benchmarks/sole-gate-2026-05-31-resqlite-p75-ready-probe/run-005-20260531T144920Z/manifest.json \
  --policy=build/tracelite-benchmarks/sole-gate-2026-05-31-resqlite-p75-ready-probe/policy-calibration.json \
  --label=sole-gate-2026-05-31-resqlite-no-regression-decision
```

Result: `decision.json` reported `accepted`; trace health, primary, and
guardrail gates all passed. The decision used the release-lane
`measured_elapsed_ns` metric for primary and guardrail checks. Its graph-data
export included 2,800 scenario-series rows, 20 peer-summary rows, 1
decision-summary row, and 10 decision-comparison rows; validation passed.

This proves the routine no-regression decision path on real suite artifacts. It
is complemented by a known-regression validation below.

### resqlite known-regression decision, 2026-05-31

Command:

```bash
/Users/dan/Coding/flutter_arm64/bin/dart benchmark/decide_tracelite.dart \
  --tracelite-root=/Users/dan/Coding/tracelite \
  --dart=/Users/dan/Coding/flutter_arm64/bin/dart \
  --baseline=build/tracelite-benchmarks/sole-gate-2026-05-31-resqlite-p75-ready-probe/run-001-20260531T143352Z/manifest.json \
  --candidate=build/tracelite-decisions/known-read-delay-regression/candidate/manifest.json \
  --policy=build/tracelite-benchmarks/sole-gate-2026-05-31-resqlite-p75-ready-probe/policy-calibration.json \
  --label=known-read-delay-regression
```

Result: the candidate was a temporary injected resqlite read-path delay, then
the source tree was restored. `decision.json` reported `rejected`; trace health
passed; primary and guardrail gates rejected the candidate. The rejected primary
scenarios were `chat-sim`, `narrow-batch-insert`, and `sqlite-diagnostics`. The
rejected decision still exported graph data with 2,100 scenario-series rows, 15
peer-summary rows, 1 decision-summary row, and 10 decision-comparison rows;
validation passed.

### resqlite pre-publish gate smoke

Command:

```bash
/Users/dan/Coding/flutter_arm64/bin/dart benchmark/run_tracelite.dart \
  --tracelite-root=/Users/dan/Coding/tracelite \
  --label=ci-smoke \
  --profile=ci \
  --runs=1 \
  --interfaces=resqlite \
  --policy-scenarios=narrow-batch-insert \
  --threshold-ceiling-percent=1000 \
  --graph-data-dir=/tmp/resqlite-tracelite-graph-smoke \
  --no-strict
```

Result: `tracelite suite-history` completed one resqlite run, wrote
`history.json`, `policy-calibration.json`, and `policy-calibration.md`, then
`export-graph-data --suite-history=...` wrote dashboard datasets with 560
scenario-series rows and 4 peer-summary rows. The smoke uses `--no-strict`
because one CI-sized run intentionally lacks enough repetitions/history for a
production policy decision.

### resqlite trace-sqlite hook smoke

Command:

```bash
/Users/dan/Coding/flutter_arm64/bin/dart tool/trace_sqlite_smoke.dart
```

Result: a generated downstream consumer resolved dependencies, enabled
`trace_sqlite` through native-assets hook configuration, and completed the
build-hook path against resqlite's tracelite fixture runtime.

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

Result: reactive scenarios report `sqlite3` as `unsupported`, while `drift`,
`sqlite_async`, and `resqlite` complete with non-empty traces and `0/0/0`
diagnostics. The `drift` lane uses Drift's table-registry-aware
`customSelect(..., readsFrom: ...).watch()` path rather than raw
`NativeDatabase` polling. The diagnostics scenario reports `sqlite3`, `drift`,
and `sqlite_async` as unsupported and records resqlite
gauges for page-cache bytes, schema bytes, statement bytes, WAL bytes, stream
count, and reader-busy state.

## What this can replace first

Ready to migrate first:

- Markdown/JSON profile report generation.
- Repetition artifact storage.
- Cross-library SQLite call attribution.
- Low-value wall-time wrappers whose only job is operation duration.
- Timeline-style worker markers where tracelite spans already exist.
- Experiment acceptance/rejection decisions that currently rely on manual
  reading of resqlite-local profile diffs.
- Resqlite benchmark-dashboard data generation for covered compare, decision,
  and workload-summary artifacts.
- Operator-facing artifact interpretation through `tracelite explain` and the
  resqlite wrapper's `insights.md`/`insights.json` outputs.

Keep for now:

- Resqlite workload definitions.
- `Database.diagnostics()` and native SQLite status snapshots.
- Existing profile runner as a compatibility/parity harness until resqlite
  intentionally removes or archives the old direct workflow.

## Remaining blockers

### 1. Stable source and CI state

The dirty-checkout blocker is closed in the integration branch: PR #109 pins
Tracelite to `resqlite-profiling-gate-2026-06-01-r2` and the wrapper records
`tracelite_source`, `resqlite_source`, and the resolved resqlite dependency
binding in every run manifest. This should stay an acceptance criterion, not a
removed concern: future pin bumps must continue to pass resqlite CI with the
same wrapper defaults. Native tracelite source-checkout benchmark commands now
also write their own `tracelite_source` section and can enforce
`--require-clean-source=true`, so standalone artifacts no longer depend on a
downstream wrapper for source auditability.

### 2. Workload coverage is broader, but still needs production scale

`narrow-batch-insert`, `point-select`, `feed-paging`, `sync-burst`, `chat-sim`,
scaled `large-working-set`, keyed PK subscriptions, high-cardinality fan-out,
many-stream writer throughput, and `sqlite-diagnostics` are now implemented in
tracelite's peer harness. Production replacement still requires larger
parameter sets, repeated-run artifacts for each workload, and side-by-side
parity against the current resqlite profiler outputs.

The former drift reactive gap is now closed for tracelite's benchmark workload
tables: the adapter wraps `NativeDatabase` in a small generated-database
harness with explicit table registry entries and manual update notifications
for raw writes. That is enough to exercise Drift's stream-query invalidation
semantics for these scenarios. It should not be generalized into "any arbitrary
app Drift query is covered" without adding table metadata for that app's schema.

### 3. Runner startup is separated, not eliminated

Scenario elapsed time is now measured inside the child process, so startup does
not pollute the benchmark metric. The runner no longer pays `dart run` process
startup for every peer repetition: source-checkout `compare` launches direct
scripts for single-shot runs and prepares an app-JIT child runner for repeated
or multi-peer runs by default. Source-checkout `suite` reuses one prepared
runner across the selected scenario matrix, avoiding repeated runner setup for
each scenario while preserving one isolated child process per peer repetition.
`tracelite explain` flags compare artifacts where child-process wall time still
dwarfs measured workload time, so smoke-sized artifacts are visibly classified
as harness-dominated rather than quietly treated as production evidence.

### 4. Resqlite semantic parity depends on adoption

The trace format and recorder now support the needed semantic events, and the
resqlite bridge PR emits the first vocabulary. tracelite now also exposes
helpers for the migration counters and gauges so resqlite does not need to
scatter event IDs through production code. The old resqlite profile runner
should not be removed until tracelite artifacts prove parity for operation
counts, rows/cells decoded, stream invalidation cost, reader-pool pressure, and
diagnostic snapshots.

The 2026-05-09 side-by-side run closed the first semantic parity gaps:
workload-scope spans preserve the old profile workload names and sample counts,
per-workload diagnostics now appear as correlated tracelite gauges, and the
many-streams profile emits stream invalidation, dependency intersection, and
dispatcher pressure counters into the trace. The remaining resqlite migration
work was export compatibility rather than raw signal capture.

The 2026-05-10 parity run added that export path. The existing resqlite
`benchmark/profile/diff.dart` can consume a tracelite-generated
`workload-summary` JSON and reports exact parity for current profile workload
summaries, RSS deltas, SQLite diagnostics, noop floors, and many-streams
fanout medians.

### 5. Portability is still macOS-first for the production suite

The repeated production peer suite is still macOS-oriented. The shim path now
has a platform-aware resolver name, a Linux package:sqlite3 smoke job, and a
Linux four-peer `ci` suite, which proves the native-hook loading strategy and
source-pinned peer harness outside macOS at CI scale. Windows now has a
core-artifact CI lane for dependency resolution, generated-output freshness,
analysis, native runtime attach, and platform-independent
diff/insight/package-boundary tests. Windows SQLite substitution, plus full
non-macOS production-profile history, is still required before this can be
called production-quality across every Dart target.

## Recommended next iteration

1. Merge or accept PR #109 if the current non-draft, green CI state remains
   true; keep the Tracelite smoke lane as the pin-bump gate.
2. Decide whether to delete, archive, or demote resqlite's old direct profile
   runner now that tracelite emits workload summaries, graph data, decisions,
   and insight artifacts.
3. Run the `Visualizer Release` workflow from a release tag with macOS signing
   secrets configured, then run doctor over the downloaded artifacts with
   `--require-signed-macos-release=true` before attaching the archives/manifests
   to the release.
4. Add a focused stress pass for the new drift reactive adapter, including
   larger stream counts and generated-app-style table metadata.
5. Retune or resize `point-select` and `keyed-pk-subscriptions` until they can
   join the ceiling-capped release gate without raising the 50% threshold
   ceiling.
6. Stabilize or redesign `feed-paging`, `large-working-set`, and `sync-burst`
   before promoting them from diagnostic to blocking release scenarios.
