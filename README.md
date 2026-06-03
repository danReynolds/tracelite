# tracelite

Standalone SQLite profiling and benchmark-decision tooling for Dart.

tracelite records SQLite C API timing, optional Dart spans/counters, calibrated
regression decisions, graph-data exports, and desktop visualizer inputs from one
workflow. It can profile any supported Dart SQLite peer that routes through the
SQLite C API shim, and it can also accept library-specific semantic events.

## Status

Production-calibrated for the validated macOS/Dart SQLite path. Current peer
lanes cover `sqlite3`, `drift`, `sqlite_async`, and `resqlite`.

resqlite is the first production integration and the current pre-publish gate
consumer. It is mentioned because it validates the end-to-end workflow, not
because tracelite's runtime or artifact model depends on resqlite.

This is not a universal, language-agnostic SQLite profiler or a finalized
multi-package distribution yet. macOS and the Dart SQLite package ecosystem are
the calibrated production path. Linux has native shim smoke coverage and a
pinned four-peer `ci` suite for the same Dart SQLite lanes, but production
profile history is still macOS-validated. Windows now validates the
platform-independent Dart artifact surface, native runtime attach, and
visualizer package in CI. Windows SQLite shim tracing has an embedded
`sqlite_traced.dll` build and package:sqlite3 smoke lane using a pinned SQLite
amalgamation, but peer-suite production history on Windows is still pending
real runner evidence.

## What It Does

- Native SQLite timing through a `libsqlite3` shim or embedded-library wrapper.
- Dart-side spans/counters through `TraceRecorder`.
- Common SQL workloads across validated peers.
- SQL query-shape fingerprints by default; raw SQL capture is explicit opt-in.
- Calibrated thresholds, CV gates, outlier policy, and decisions.
- Artifact interpretation through `explain` and visualizer insight panels:
  trace health, noise, bottlenecks, peer spread, and harness overhead.
- Decision Review in the desktop visualizer for verdicts, policy thresholds,
  gate status, primary comparisons, and guardrail findings.
- Schema-validated graph data for dashboards and the visualizer.
- Source-checkout benchmark artifacts record the tracelite git revision and
  dirty state; release gates can require a clean checkout.

## How It Works

tracelite treats SQLite as the shared boundary between database libraries. For
packages that FFI-link to SQLite, a `libsqlite3` shim wraps high-value calls such
as prepare, step, bind, reset, finalize, and close. For libraries that embed
SQLite into their own native asset, the same wrapper layer can be compiled into
that asset with the real SQLite symbols renamed behind it.

On macOS and Linux, unwrapped SQLite symbols are supplied by the platform link
strategy while the shim times the wrapped calls. Windows needs a different
contract: Dart resolves symbols from `sqlite_traced.dll` itself, so a production
Windows shim must export or forward the full `sqlite3` ABI instead of only
loading a real SQLite DLL internally. Tracelite's Windows path is the embedded
variant: compile the SQLite amalgamation with the wrapped entry points renamed
to `tlt_sqlite3_*`, then link it with the exported wrapper layer so
`sqlite_traced.dll` supplies both traced and untraced SQLite symbols.

Native events and Dart `TraceRecorder` events write into one shared-memory
region on the same monotonic clock. After a workload finishes, tracelite reads
that region into artifacts: span timings, workload summaries, peer comparisons,
policy calibration, regression decisions, and graph-data datasets.

SQLite prepare calls are grouped by normalized `sqlfp:v1` fingerprints by
default. Literal values are replaced with `?` before the query shape is interned
or written to compare artifacts. Raw SQL is only captured for local debugging
when `TRACELITE_SQL_CAPTURE=raw` or `TRACELITE_RAW_SQL=1` is set.

The key design choice is that profiling data is queried from artifacts, not
hand-coded into each benchmark. A release gate can keep broad diagnostic data
while calibrating a narrow blocking policy, and unsupported peer capabilities
are represented explicitly instead of hidden behind incomparable numbers.

## Common Commands

```bash
# Complete CLI usage; command-level help works too, for example
# `dart run bin/tracelite.dart doctor --help`.
dart run bin/tracelite.dart help

# Source-checkout setup check. On Windows, pass sqlite3.c to print the
# embedded sqlite_traced.dll build plan.
dart run bin/tracelite.dart doctor --sqlite-amalgamation=third_party/sqlite3.c

# Source-checkout SQLite shim build helper.
dart --packages=.dart_tool/package_config.json tool/build_sqlite_shim.dart \
  --sqlite-amalgamation=third_party/sqlite3.c

# Source-checkout SQLite shim smoke without invoking package:test hooks.
dart --packages=.dart_tool/package_config.json tool/sqlite_shim_smoke.dart

# Published/core command: inspect an existing trace.
dart run bin/tracelite.dart report build/example.tlt-region

# Published/core command: make a regression decision from artifacts.
dart run bin/tracelite.dart decision \
  --baseline=build/baseline/manifest.json \
  --candidate=build/candidate/manifest.json \
  --policy=build/policy-calibration.json

# Published/core command: inspect benchmark deltas without peer libraries.
dart run bin/tracelite.dart diff \
  --baseline=build/baseline/compare.json \
  --candidate=build/candidate/compare.json

# Published/core command: explain trust, noise, and bottleneck signals.
dart run bin/tracelite.dart explain build/candidate/manifest.json

# Published/core command: export dashboard-ready graph data.
dart run bin/tracelite.dart export-graph-data \
  --suite-history=build/history.json \
  --out=build/graph-data

# Source-checkout peer benchmark command.
dart run bin/tracelite.dart suite \
  --profile=experiment \
  --interfaces=sqlite3,drift,sqlite_async

# Source-checkout compare; auto uses app-JIT where native assets allow it.
dart run bin/tracelite.dart compare \
  --scenario=narrow-batch-insert \
  --interfaces=sqlite3,resqlite \
  --repetitions=5

# Native-assets-heavy repeated runs can opt into a long-lived worker.
dart run bin/tracelite.dart compare \
  --scenario=narrow-batch-insert \
  --interfaces=resqlite \
  --repetitions=5 \
  --runner=worker

# Source-checkout desktop visualizer launcher for traces, artifacts, or dirs.
dart run bin/tracelite.dart visualize build/graph-data
dart run bin/tracelite.dart visualize build/decision.json

# Source-checkout visualizer readiness and packaged host release evidence.
dart run bin/tracelite.dart visualizer-check --package=host
```

## Benchmark Profiles

Use `ci` for routine pull-request smoke checks, `experiment` for a new
performance idea's baseline/candidate run, and `production` only for release
calibration or threshold changes. All profiles write the same manifest and
compare artifacts, so a run can move from quick signal to audited decision
without changing artifact shape. `suite-history` repeats whole suite runs for
noise calibration; each run is bounded by a profile-aware timeout (`ci`: 3
minutes, `experiment`: 10 minutes, `production`: 20 minutes, override with
`--suite-run-timeout-seconds`). Repeated source-checkout compares use an
app-JIT child runner when the selected peers can safely share a prepared
snapshot, so artifacts still have isolated repetitions without paying
`dart run` startup for every sample. Native-asset peers such as `resqlite`
stay on the direct script runner in `auto` mode because prepared snapshots do
not preserve the native-assets metadata they need. For repeated native-assets
runs, pass `--runner=worker`: it keeps one child process alive, retargets each
sample to a fresh trace region, and records startup in `runner.build_elapsed_ns`
instead of hiding it in repetition timings. For reactive native-asset peers that
can finish Dart work before every native producer has fully gone quiet, the
worker leaves the runtime inactive briefly after reset before attaching the next
sample. Worker startup also runs a tiny preflight trace in that same long-lived
process; if the selected peer cannot emit shim events, the command fails before
any benchmark sample is trusted.
Worker artifacts record both `runner.preflight` and the filtered
`runner.native_assets` binding used for the selected peers, so shim path problems
are auditable from the artifact instead of local `.dart_tool` state.
Source-checkout suites reuse one prepared child runner across the selected
scenario matrix when available, so production suites still write one compare
artifact per scenario while avoiding repeated runner setup for every scenario.

For publish or release evidence, add `--require-clean-source=true` to
`compare`, `suite`, `suite-history`, or `calibrate`. The command fails if the
tracelite checkout is dirty or not auditable, and successful artifacts include
`tracelite_source` with the git revision, branch, tag when present, and
dirty-file count.

## Integrations

The published dependency graph is core-only: runtime code depends on `ffi` and
`yaml`, not on peer SQLite libraries. The repository also ships source-checkout
peer adapters so one CLI can run comparable workloads against Dart SQLite
packages during development and resqlite release-gate validation.

The pub archive excludes source-checkout tests and tools (`test/` and `tool/`),
including the peer runner, visualizer app, release checks, and CI smoke scripts.
Published users get the recorder/runtime library and artifact CLI; repository
checkouts get the peer benchmark suite and visualizer workflow.

The long-term package split is core library plus peer-benchmark CLI. Today the
public recorder APIs are standalone, while the source checkout keeps the
dev-dependency-backed peer CLI in-tree so resqlite and other Dart SQLite
libraries can run one benchmark workflow during the pre-1.0 phase.

resqlite has the deepest integration today: it can emit semantic spans/counters
for its reader pool, writer isolate, stream invalidation, diagnostics, and old
profile-parity metrics. Its gate pins the exact Tracelite revision in
resqlite's benchmark source audit, records both Tracelite and resqlite source
states in every wrapper manifest, and validates repeated production runs,
policy calibration, no-regression acceptance, injected-regression rejection,
graph-data export, insight artifacts, and clean-clone publish dry-run behavior.

For release hygiene, run `dart run tool/publish_check.dart` from a clean
repository checkout. It validates a clean git archive, so ignored local
overrides used for sibling checkout testing do not affect the publish dry-run.
It also runs the core CLI from an archive-shaped tree after source-checkout
tools are removed. The check script itself is a checkout-only tool and is not
shipped in the pub archive.
The macOS CI lane runs the same publish archive smoke before the benchmark
suite.

For visualizer release hygiene, run
`dart run bin/tracelite.dart visualizer-check --package=host`. It resolves the
Flutter app dependencies, runs `flutter analyze`, runs `flutter test`, builds
the host release bundle, creates a platform archive under
`build/visualizer-release/`, and writes a manifest with source state, archive
size, SHA-256 checksum, and signing/notarization status. Add
`--require-clean-source=true` for attachable release evidence. On macOS, pass
`--macos-sign-identity` and `--macos-notary-profile` to run the credentialed
Developer ID signing, notarytool submission, stapling, and final archive path.
Linux and Windows signing remain release-system responsibilities and are
recorded as external in the manifest.
The `Visualizer Release` GitHub workflow runs this package path on macOS,
Linux, and Windows, uploads the archive/manifest evidence, and can publish
those artifacts to a draft GitHub release from a tag or manual dispatch. Before
publish, the workflow downloads the uploaded package artifacts and runs doctor
with required macOS/Linux/Windows coverage, archive size/SHA validation, clean
source validation, and signed macOS validation when `sign_macos=true`. macOS
signing/notarization is optional and requires the release secrets documented in
the workflow. Hosted release packaging skips only the tagged heavyweight
dense-trace widget stress test; run the direct visualizer check or `flutter test`
locally for full visualizer stress coverage.
After downloading release artifacts, `tracelite doctor --visualizer-release=...`
audits manifest schema, platform coverage, archive size, SHA-256, clean source,
and macOS signing/notarization evidence.
For visualizer-only source-checkout validation, `dart tool/visualizer_check.dart`
runs the same checks directly without rebuilding the root peer native assets.

## Architecture

`native/` contains the shared-memory runtime and SQLite shim. `lib/` contains
the recorder, trace reader, decision logic, graph-data export, and vocabularies.
`bin/` contains the thin published launcher. Core artifact commands live in
`lib/src/core_cli.dart` so the published executable and source-checkout
development CLI use the same implementation. In a repository checkout,
`tool/tracelite_dev.dart` contains the dev-dependency-backed benchmark implementation, and
`tool/visualizer_app/` contains the Flutter desktop visualizer.

## Docs

- [Production readiness](doc/production-benchmark-readiness.md)
- [resqlite gate](doc/resqlite-sole-profiling-gate.md)
- [Decision standard](doc/profiling-decision-standard.md)
- [Graph-data contract](doc/graph-data-export.md)
- [Trace/runtime specs](doc/format-spec.md), [runtime](doc/runtime-protocol.md),
  and [peer contract](doc/peer-interface-contract.md)
- [Visualizer design](doc/visualizer-product-design.md)

`PLAN.md` remains the detailed implementation/status tracker.

## Non-Goals

- Live production telemetry.
- A replacement for Dart DevTools.
- A universal SQLite profiler across every language/runtime today.

## License

MIT. See [LICENSE](LICENSE).
