# resqlite sole-profiling acceptance gate

Status: regular workflow accepted in merged PR #109; r12 point/keyed policy
promotion merged downstream, 2026-06-04

This is the evidence gate for accepting tracelite as resqlite's regular
profiling and benchmarking framework. Tracelite can replace the old profile
artifact and dashboard pipeline for covered surfaces. The legacy direct profile
runner remains available as a compatibility/parity harness because
`benchmark/profile/run_tracelite_profile.dart` uses it to write the old
`profile.json` shape beside trace-backed workload summaries, insights, graph
data, and parity diffs.

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
That is now closed in merged PR #109: the resqlite wrappers pin Tracelite in
the benchmark source audit, reject dirty or mismatched checkouts by default,
record both source states in wrapper manifests, and verify that Tracelite
resolves `resqlite` to the checkout under test.

The resqlite wrapper now separates broad suite coverage from strict policy
scope. The r12 production gate runs the current resqlite release-policy surface
with production thresholds: `high-cardinality-fanout`,
`many-streams-writer-throughput`, `point-select`, and
`keyed-pk-subscriptions`. It also runs `sqlite-diagnostics` as trace-health and
diagnostic coverage, but diagnostics are not a strict elapsed-time blocker.
`narrow-batch-insert`, `feed-paging`, `sync-burst`, `chat-sim`, and
`large-working-set` remain diagnostic or experiment workloads unless an
operator explicitly requests them with scenario overrides. A follow-up
Tracelite probe calibrated `feed-paging`, `large-working-set`, and `sync-burst`
under the same ceiling for `measured_elapsed_ns`; they remain outside the
downstream blocking policy until that broader gate is intentionally adopted
with non-macOS production-history evidence.

Calibration now uses a robust within-run noise policy: p75 within-run CV,
run-mean CV, Tukey outer-fence outlier accounting, a 10% total outlier ceiling,
and a 20% per-run outlier ceiling. This keeps isolated repetition spikes visible
without letting one bad repetition force release thresholds above useful
ceilings.

The strict current production gate is:

```bash
dart run benchmark/run_tracelite.dart \
  --preset=production \
  --tracelite-root=/path/to/tracelite \
  --resqlite-root="$PWD" \
  --label=production-pin-r12-point-keyed-policy-2026-06-04-r1 \
  --out-dir=build/tracelite-benchmarks/production-pin-r12-point-keyed-policy-2026-06-04-r1 \
  --graph-data-dir=build/tracelite-benchmarks/production-pin-r12-point-keyed-policy-2026-06-04-r1/graph-data
```

Evidence:

- Tracelite source:
  `b92ec4fa8410b074f77bea840c2fa53cfdf759b4`
  (`resqlite-profiling-gate-2026-06-04-r12`).
- The downstream resqlite PR #120 pin/policy update merged at
  `aabcce733240b8586216f8c32bcc1a16f806586f` with green Tracelite smoke.
- The local downstream production wrapper evidence
  `production-pin-r12-point-keyed-policy-2026-06-04-r1` recorded 5/5
  successful production suite runs from a fresh r12 Tracelite clone.
- `policy-calibration.json` reported `ready` for all four strict
  release-policy groups: `high-cardinality-fanout`,
  `many-streams-writer-throughput`, `point-select`, and
  `keyed-pk-subscriptions`.
- The policy recommended 7 repetitions, 13% primary threshold, 10% guardrail,
  and 10% max CV for the combined strict release surface.
- `tracelite explain` completed and preserved the remaining
  harness-dominated/noisy-CV findings as operator review aids.
- The wrapper recorded clean Tracelite source and
  `tracelite_resqlite_dependency.matches_requested_root=true`.
- Observed strict-lane noise was 3.05% for `high-cardinality-fanout`, 2.14%
  for `many-streams-writer-throughput`, 6.35% for `point-select`, and 4.87%
  for `keyed-pk-subscriptions`; all were within their calibrated max-CV gates.
- The suite-history phase remains acceptable for a pre-publish gate, but still
  the next runtime optimization target.

The current CI smoke gate is:

```bash
dart run benchmark/run_tracelite.dart \
  --preset=ci \
  --tracelite-root=/tmp/tracelite \
  --resqlite-root="$PWD" \
  --label=ci-<sha>
```

Evidence:

- PR #120's `Tracelite smoke` job checks out the r12 tag, runs the `ci` preset
  through the resqlite wrapper, uploads wrapper artifacts, and passed before
  merge.
- The merged main commit `aabcce733240b8586216f8c32bcc1a16f806586f` passed
  raw-profile-JSON hygiene, tests, generated-data freshness, and the Tracelite
  smoke job in CI run `26965785549`.

The resqlite PR now also has a dedicated
`benchmark/decide_tracelite.dart` wrapper for baseline/candidate decisions. A
routine no-regression decision using real suite manifests from the gate above
was accepted:

```bash
dart run benchmark/decide_tracelite.dart \
  --tracelite-root=/path/to/tracelite \
  --baseline=build/tracelite-benchmarks/sole-gate-2026-05-31-resqlite-p75-ready-probe/run-001-20260531T143352Z/manifest.json \
  --candidate=build/tracelite-benchmarks/sole-gate-2026-05-31-resqlite-p75-ready-probe/run-005-20260531T144920Z/manifest.json \
  --policy=build/tracelite-benchmarks/sole-gate-2026-05-31-resqlite-p75-ready-probe/policy-calibration.json \
  --label=sole-gate-2026-05-31-resqlite-no-regression-decision
```

Evidence:

- `decision.json` reported `accepted`.
- Trace health, primary, and guardrail gates all passed.
- The decision used `measured_elapsed_ns` for both primary and guardrail metrics
  across the then-current release-lane scenarios.
- The exported decision graph data contained suite rows plus 1 decision-summary
  row and 10 decision-comparison rows, and validation passed.

The same decision path rejected a known injected read-path regression:

```bash
dart run benchmark/decide_tracelite.dart \
  --tracelite-root=/path/to/tracelite \
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

Current acceptance position:

- Criteria 1 and 2 are satisfied by merged PR #109: it source-pins Tracelite in
  resqlite's benchmark audit, records both source states in wrapper manifests,
  and keeps the Tracelite smoke lane green.
- Criteria 3 and 4 are satisfied by the five-run release gate, routine
  no-regression decision, and injected-regression rejection artifacts above.
- Criteria 5 through 7 are satisfied for the covered resqlite profile surfaces,
  graph-data exports, and explicit unsupported peer lanes documented above.

Remaining upkeep:

- Keep the legacy direct profile runner as a compatibility/parity helper while
  `run_tracelite_profile.dart` still emits old-shape `profile.json`.
- Keep the pinned PR CI green whenever the Tracelite pin changes.
