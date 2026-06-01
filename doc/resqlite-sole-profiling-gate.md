# resqlite sole-profiling acceptance gate

Status: primary path credible, source pin integrated, sole-framework acceptance
still needs adoption sign-off, 2026-06-01

This is the merge blocker for accepting tracelite as resqlite's sole regular
profiling and benchmarking framework. Tracelite can already replace the old
profile artifact and dashboard pipeline for covered surfaces, but PR #109
should stay gated until the release criteria below are satisfied with current
artifacts and CI.

## Acceptance criteria

All criteria must be true before deleting or archiving resqlite's old profiling
path as the default regular workflow.

1. Reproducible source state
   - The resqlite PR points at a stable tracelite commit, tag, or published
     package version.
   - The passing evidence does not depend on a dirty local tracelite checkout or
     an untracked dependency override.

2. Green local and CI checks
   - Tracelite analysis and test coverage pass for the suite, history,
     decision, graph-data, and workload-summary commands.
   - The resqlite PR checks pass with the tracelite workflow wrapper and native
     hook smoke tests enabled.

3. Scoped release-gate calibration
   - `benchmark/run_tracelite.dart` records both the suite scenario scope and
     strict policy scenario scope in its manifest.
   - The suite can run diagnostic workloads, but strict release calibration
     covers only the documented release lane.
   - A strict `tracelite suite-history --profile=production --runs=5` gate for
     the resqlite release set passes with useful ceilings, not permissive
     thresholds.
   - The release set is explicit. Diagnostic or unstable workloads can remain
     out of the release gate only if that is documented.

4. Real baseline/candidate validation
   - At least one real resqlite performance experiment is decided using
     tracelite artifacts only.
   - The outcome is accepted, rejected, or inconclusive through `tracelite
     decision` or the calibrated suite-history gate, not manual interpretation
     of raw timing output.

5. Profile parity for resqlite-owned signals
   - Workload sample counts, rows/cells decoded, stream invalidation counters,
     reader-pool pressure counters, many-streams fanout summaries, RSS deltas,
     and SQLite diagnostic snapshots match the old resqlite profile JSON for
     current profile surfaces.
   - Any intentional semantic difference is documented before old artifacts are
     removed.

6. Cross-library lane validation
   - Common SQL scenarios are valid for `sqlite3`, `drift`, `sqlite_async`, and
     `resqlite`.
   - Optional reactive and diagnostic lanes mark unsupported peers explicitly
     and do not silently dilute the resqlite release gate.

7. Artifact hygiene
   - The graph-data export validates before publish.
   - Raw trace regions remain build artifacts unless intentionally attached to a
     release or investigation.
   - The dashboard points at validated graph-data bundles, not ad hoc report
     output.

## Current status

The highest-priority implementation blocker found on 2026-05-31 was release
scope drift: `suite-history` could calibrate a scenario subset while the nested
`suite` still ran the whole profile. That has been fixed so `suite` and
`suite-history` both honor `--scenarios`.

The highest-priority integration blocker found later was source reproducibility.
That is now closed in PR #109: the resqlite wrappers pin Tracelite to
`resqlite-profiling-gate-2026-06-01-r2`
(`06c00ac126b54027c14c96deb5634e5a38104973`), reject dirty or mismatched
checkouts by default, record both source states in wrapper manifests, and verify
that Tracelite resolves `resqlite` to the checkout under test.

The resqlite wrapper now separates broad suite coverage from strict policy
scope. It runs the full ten-scenario production matrix for artifacts and graph
data, while calibrating the release gate against the five scenarios that have
current production thresholds: `chat-sim`, `high-cardinality-fanout`,
`many-streams-writer-throughput`, `narrow-batch-insert`, and
`sqlite-diagnostics`. `point-select`, `feed-paging`, `sync-burst`,
`large-working-set`, and `keyed-pk-subscriptions` remain diagnostic workloads.

Calibration now uses a robust within-run noise policy: p75 within-run CV,
run-mean CV, Tukey outer-fence outlier accounting, a 10% total outlier ceiling,
and a 20% per-run outlier ceiling. This keeps isolated repetition spikes visible
without letting one bad repetition force release thresholds above useful
ceilings.

The strict current production gate is:

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

Evidence:

- `history.json` recorded 5/5 successful production suite runs.
- The suite executed all ten production scenarios for `resqlite`.
- `policy-calibration.json` reported `ready`, 5/5 release-lane groups ready.
- The calibrated policy was 48% primary threshold, 36% max regression
  guardrail, 36% max-CV gate, and 6 recommended repetitions.
- The release-lane groups had no findings. Observed noise ranged from 0.56%
  (`many-streams-writer-throughput`) to 23.9% (`chat-sim`).
- Graph-data export wrote 7,000 scenario-series rows and 50 peer-summary rows,
  and `tracelite validate-graph-data` passed.

The resqlite PR now also has a dedicated
`benchmark/decide_tracelite.dart` wrapper for baseline/candidate decisions. A
routine no-regression decision using real suite manifests from the gate above
was accepted:

```bash
/Users/dan/Coding/flutter_arm64/bin/dart benchmark/decide_tracelite.dart \
  --tracelite-root=/Users/dan/Coding/tracelite \
  --dart=/Users/dan/Coding/flutter_arm64/bin/dart \
  --baseline=build/tracelite-benchmarks/sole-gate-2026-05-31-resqlite-p75-ready-probe/run-001-20260531T143352Z/manifest.json \
  --candidate=build/tracelite-benchmarks/sole-gate-2026-05-31-resqlite-p75-ready-probe/run-005-20260531T144920Z/manifest.json \
  --policy=build/tracelite-benchmarks/sole-gate-2026-05-31-resqlite-p75-ready-probe/policy-calibration.json \
  --label=sole-gate-2026-05-31-resqlite-no-regression-decision
```

Evidence:

- `decision.json` reported `accepted`.
- Trace health, primary, and guardrail gates all passed.
- The decision used `measured_elapsed_ns` for both primary and guardrail metrics
  across the five release-lane scenarios.
- The exported decision graph data contained suite rows plus 1 decision-summary
  row and 10 decision-comparison rows, and validation passed.

The same decision path rejected a known injected read-path regression:

```bash
/Users/dan/Coding/flutter_arm64/bin/dart benchmark/decide_tracelite.dart \
  --tracelite-root=/Users/dan/Coding/tracelite \
  --dart=/Users/dan/Coding/flutter_arm64/bin/dart \
  --baseline=build/tracelite-benchmarks/sole-gate-2026-05-31-resqlite-p75-ready-probe/run-001-20260531T143352Z/manifest.json \
  --candidate=build/tracelite-decisions/known-read-delay-regression/candidate/manifest.json \
  --policy=build/tracelite-benchmarks/sole-gate-2026-05-31-resqlite-p75-ready-probe/policy-calibration.json \
  --label=known-read-delay-regression
```

Evidence:

- `decision.json` reported `rejected`.
- Trace health passed.
- Primary and guardrail gates rejected the candidate.
- The rejected primary scenarios were `chat-sim`, `narrow-batch-insert`, and
  `sqlite-diagnostics`.
- The rejected decision still exported graph data and validation passed.

The 2026-06-01 wrapper update also adds `insights.md` and `insights.json` to
benchmark, decision, and profile workflows by running `tracelite explain` over
the produced artifacts. These are review aids; acceptance still comes from the
machine policy gates above.

Remaining blockers before accepting tracelite as the sole framework:

- Preserve, demote, or intentionally remove any old resqlite profile-only
  signals that are not needed now that tracelite emits workload summaries,
  graph data, decisions, and insight artifacts.
- Keep the pinned PR CI green whenever the Tracelite pin changes.
