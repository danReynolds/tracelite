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
the validated production path. Linux has focused shim smoke coverage for
`package:sqlite3`; Windows shim validation and non-Dart bindings are future
work.

## What It Does

- Native SQLite timing through a `libsqlite3` shim or embedded-library wrapper.
- Dart-side spans/counters through `TraceRecorder`.
- Common SQL workloads across validated peers.
- Calibrated thresholds, CV gates, outlier policy, and decisions.
- Artifact interpretation through `explain` and visualizer insight panels.
- Schema-validated graph data for dashboards and the visualizer.

## How It Works

tracelite treats SQLite as the shared boundary between database libraries. For
packages that FFI-link to SQLite, a `libsqlite3` shim wraps high-value calls such
as prepare, step, bind, reset, finalize, and close. For libraries that embed
SQLite into their own native asset, the same wrapper layer can be compiled into
that asset with the real SQLite symbols renamed behind it.

Native events and Dart `TraceRecorder` events write into one shared-memory
region on the same monotonic clock. After a workload finishes, tracelite reads
that region into artifacts: span timings, workload summaries, peer comparisons,
policy calibration, regression decisions, and graph-data datasets.

The key design choice is that profiling data is queried from artifacts, not
hand-coded into each benchmark. A release gate can keep broad diagnostic data
while calibrating a narrow blocking policy, and unsupported peer capabilities
are represented explicitly instead of hidden behind incomparable numbers.

## Common Commands

```bash
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

# Source-checkout desktop visualizer launcher.
dart run bin/tracelite.dart visualize build/graph-data
```

## Benchmark Profiles

Use `ci` for routine pull-request smoke checks, `experiment` for a new
performance idea's baseline/candidate run, and `production` for release-gate
calibration. All profiles write the same manifest and compare artifacts, so a
run can move from quick signal to audited decision without changing artifact
shape.

## Integrations

The published dependency graph is core-only: runtime code depends on `ffi` and
`yaml`, not on peer SQLite libraries. The repository also ships source-checkout
peer adapters so one CLI can run comparable workloads against Dart SQLite
packages during development and resqlite release-gate validation.

The pub archive excludes the source-checkout peer runner
(`tool/tracelite_dev.dart` and `tool/src/`). Published users get the
recorder/runtime library and artifact CLI; repository checkouts get the peer
benchmark suite.

The long-term package split is core library plus peer-benchmark CLI. Today the
public recorder APIs are standalone, while the source checkout keeps the
dev-dependency-backed peer CLI in-tree so resqlite and other Dart SQLite
libraries can run one benchmark workflow during the pre-1.0 phase.

resqlite has the deepest integration today: it can emit semantic spans/counters
for its reader pool, writer isolate, stream invalidation, diagnostics, and old
profile-parity metrics. Its current gate is pinned to
`bcb3f3f419a09aa682948595fdb8ab002af637dc`
(`resqlite-profiling-gate-2026-05-31`) and has validated repeated production
runs, policy calibration, no-regression acceptance, injected-regression
rejection, graph-data export, and clean-clone publish dry-run behavior.

For release hygiene, run `dart run tool/publish_check.dart` from a clean commit.
It validates a clean git archive, so ignored local overrides used for sibling
checkout testing do not affect the publish dry-run.

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
