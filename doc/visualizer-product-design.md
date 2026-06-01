# tracelite visualizer product design

Status: design draft, 2026-05-12

This document defines the product and architecture target for the standalone
tracelite visualizer. It complements `visualizer-binding.md`, which describes
reactive UI state and panel wiring. This document answers what the visualizer is,
who uses it, which workflows it must support, and why it should be built
desktop-first.

Implementation checkpoint: the generic desktop app now lives in
`tool/visualizer_app`. It opens raw traces, compare artifacts, suite manifests,
decision artifacts, workload summaries, and graph-data directories; renders a
workspace browser, trace timeline, minimap viewport brush, searchable linked
span index, span inspector, span aggregation table, peer comparison table,
graph-data validation rows, and workload tables; and is reachable through
`dart run bin/tracelite.dart visualize [--release|--profile] <path>`. The
timeline has explicit zoom controls, scroll/double-click zoom, keyboard
navigation, enlarged dense-span hit targets, nearest-span picking, range-aware
visible-span queries, density rendering for large trace windows, and a
virtualized linked span index so small SQLite calls remain inspectable. The
workspace and compare screens also use the core insight layer to surface trust,
trace-health, noise, peer-spread, and bottleneck findings before users drill
into raw tables.

Production readiness checkpoint: the app is suitable for local developer
dogfooding and release-mode smoke testing. `tracelite visualizer-check` resolves
the Flutter app, runs analyze/tests, and can build plus verify the current host
release bundle with `--build=host`. External distribution still requires
signed/notarized packaging and a published release process. The product should
not be advertised as a hosted dashboard; downstream public pages should continue
to consume graph-ready JSON rather than embed this local deep-inspection UI.

## Verdict

The tracelite visualizer should be a desktop-first Flutter app, with an optional
web build only for lightweight artifact viewing.

The visualizer is not a reusable UI component layer for downstream projects.
Project dashboards should consume graph-ready JSON from
`tracelite export-graph-data` and render their own public dashboards. The
visualizer is the local deep-inspection tool for `.tlt-region`/`.tlt` traces,
compare artifacts, suite manifests, decision artifacts, workload summaries, and
graph-data bundles from any SQLite library or application.

Desktop-first is the right default because the primary workflows are local and
file-heavy:

- opening raw trace regions and artifact directories from disk;
- preserving raw traces as private experiment evidence without uploading them;
- indexing potentially large traces in background isolates;
- linking graph rows back to local raw trace evidence;
- eventually watching benchmark output directories and launching from the CLI.

Flutter is still the right implementation stack. The core query/aggregation
engine is Dart, the visualizer-binding design is Flutter-oriented, and Flutter
ships native desktop targets for macOS, Windows, and Linux. A web build remains
useful later for small, shareable graph-data bundles, but it should not constrain
the deep trace viewer.

## Research baseline

Mature profiling tools converge on the same model: one trace artifact, several
ways to interrogate it.

Perfetto pairs a timeline UI with a query engine. Its UI opens local trace files,
supports track pinning, range selections, command/macro workflows, and event
detail panes. PerfettoSQL and TraceProcessor are the more important lesson:
visual inspection and repeatable metrics are two faces of the same trace model.
Tracelite should follow that split with `Trace`, `TraceIndex`, and artifact query
APIs underneath the UI, not with one-off widget computations.

Chrome DevTools Performance uses a flame/timeline surface plus Summary,
Call tree, Bottom-up, and Event log views over the selected range. That validates
the core tracelite panel set: timeline, selection details, top-down/grouped
structure, bottom-up aggregate cost, and chronological event tables must all
stay linked to the same visible range.

Speedscope keeps the UI focused by exposing three modes: chronological time
order, left-heavy aggregate grouping, and a "sandwich" table that shows callers
and callees for the selected function. Tracelite should adopt the product
principle, not the exact flamegraph UI: give users a small number of opinionated
modes that answer distinct questions.

Firefox Profiler separates statistical samples from deterministic markers.
That maps directly to tracelite's model: SQLite/Dart spans and counters are
deterministic markers; future Dart/OS stack samples are attribution data. The
visualizer should label these differently so users do not confuse observed span
durations with sampled CPU attribution.

pprof's web UI and diff mode are a useful warning: aggregate and diff views are
as important as raw timelines, and differential visual encodings must distinguish
gross movement from net movement. For tracelite this means peer and experiment
diffs should show count delta, total-time delta, p90/p99 delta, and guardrail
status rather than only one "faster/slower" color.

## Product jobs

The visualizer has four jobs.

1. Standalone trace inspection.
   Open one trace and answer: what happened, where was time spent, which spans
   caused the selected work, how healthy is the trace, and which semantic
   counters changed?

2. Peer comparison.
   Open a compare artifact or suite manifest and answer: how did each SQLite
   peer differ on the same scenario? Which differences are SQL work, library
   overhead, setup/warmup, reactive semantics, or unsupported capability lanes?

3. Experiment review.
   Open baseline/candidate compare artifacts and a decision artifact, then answer:
   should this experiment be accepted, rejected, or marked inconclusive? Where did
   the time move, did trace health hold, and which guardrails changed?

4. Artifact forensics.
   Open a graph-data bundle or workload-summary output and answer: what public
   dashboard rows were generated, are they schema-valid, and which raw traces or
   compare artifacts support them?

## Input model

The app should accept these inputs:

| Input | Purpose |
|---|---|
| `.tlt-region` | Current raw mmap region trace from local runs. |
| `.tlt` | Future finalized trace archive format. |
| compare artifact JSON | One scenario across peers and repetitions. |
| suite manifest | A matrix of compare artifacts plus logs. |
| decision artifact JSON | Baseline/candidate verdict and guardrail gates. |
| workload-summary JSON | Workload-scoped summaries derived from traces. |
| graph-data directory | Public-dashboard datasets generated by `export-graph-data`. |

Opening a directory should discover known files by schema, not by fragile
filename conventions. The app's internal root object should be a `RunWorkspace`
containing zero or more `TraceDocument`, `CompareDocument`, `SuiteDocument`,
`DecisionDocument`, `WorkloadSummaryDocument`, and `GraphDataDocument` records.

Raw trace documents should be optional. Public graph-data bundles may only have
summary rows; the UI must still render useful comparison and validation views
without requiring raw traces.

## Primary screens

### Workspace browser

The first screen should be a dense artifact browser, not a landing page. It
should show detected runs, scenarios, peers, repetitions, trace-health status,
artifact schemas, and linked raw traces. Dragging a file or directory into the
app opens or merges it into the current workspace.

### Trace inspector

The trace inspector is the equivalent of a DevTools/Perfetto trace view:

- timeline lanes grouped by process, isolate, C thread, async chain, and counters;
- range selection, track pinning, track hiding, search, and category filters;
- selected-span details including args, duration, self/concurrent time,
  correlation ID, begin/end metadata, and related events;
- visible-range aggregations by span type, category, track, SQL fingerprint, and
  correlation chain;
- event log for chronological inspection;
- counter/gauge charts over the selected time range;
- trace-health panel for dropped events, unmatched spans, missing producers,
  ring utilization, string-pool overflow, and schema mismatch.

### Peer comparison

Peer comparison should make the benchmark artifact understandable before the
user opens a raw trace:

- scenario x peer matrix with measured elapsed as the default metric;
- scenario elapsed and setup/warmup elapsed shown as context, not as the primary
  experiment metric;
- repetition distributions, CV, outliers, and status per peer;
- SQLite call accounting: `sqlite3_step`, prepare, bind, column, reset, finalize,
  total SQLite time, and call count;
- event/span volume and trace-health columns;
- unsupported capability lanes displayed explicitly.

Clicking a peer/scenario cell should open the matching repetition list; clicking
a repetition should open its raw trace if the artifact links are present.

### Experiment diff

Experiment diff is the visual counterpart to `tracelite decision`:

- verdict summary: accepted, rejected, inconclusive, or too noisy;
- primary metric delta with confidence/noise context;
- guardrail deltas and trace-health gates;
- side-by-side peer or scenario rows;
- span-group diff table with count delta, total delta, p50/p90/p99 deltas, and
  category/track attribution;
- optional linked trace panes with synchronized ranges.

The diff UI must not imply statistical certainty from within-run spans. The
default significance unit remains independent repetitions.

### Workload profile

The workload profile view exists for library-local or application-local
profiling:

- workload summary rows emitted by tracelite workload boundaries;
- operation metrics such as median, p99, and work-adjusted timing;
- memory/RSS and diagnostics deltas;
- semantic counters emitted by the library or application, such as decoded rows,
  decoded cells, invalidation counts, dispatcher pressure, cache pressure, or
  queue depth;
- links into raw traces showing where each workload and operation appears.

## Query architecture

The app should be layered so the UI is thin over reusable query APIs.

1. Import layer.
   Schema-detect files and directories, validate them, and produce typed document
   objects. This should share code with CLI validators.

2. Trace index layer.
   Load raw traces in explicit modes: metadata-only, indexed events, indexed
   spans, and visualizer-ready. Build event, span, track, correlation-chain, and
   counter indexes in background isolates.

3. Artifact query layer.
   Expose compare/suite/decision/workload/graph-data queries without widgets.
   Peer matrices, repetition distributions, decision gates, and graph rows should
   be query objects that the CLI can test.

4. Visualizer model layer.
   Convert trace and artifact query results into stable view models:
   `TimelineLane`, `SpanRect`, `CounterSeries`, `PeerMetricCell`,
   `DiffMetricRow`, `TraceHealthBadge`.

5. Binding layer.
   Use the existing probe/scope design from `visualizer-binding.md` for visible
   range, filters, selection, linked panes, and derived panel data.

6. Rendering layer.
   Use custom painters for timeline/counter tracks and virtualized widgets for
   tables. Tables and timeline panes must read shared derived probes so dragging
   a range recomputes each query once per frame.

No downstream project should depend on layer 4 or above. Public dashboards
consume only graph-data JSON.

## Performance requirements

The app should be built around large traces from the start:

- metadata view should open a large trace quickly without indexing all spans;
- indexing should happen off the UI thread with progress and cancellation;
- timeline rendering should use level-of-detail aggregation at far zoom levels;
- tables must be virtualized and sortable without rebuilding all rows;
- visible-range queries should reuse interval indexes and cache overlapping
  windows;
- memory use should be visible in the trace-health/details panel.

The first implementation can target local prototype trace sizes, but the public
architecture should not bake in "load everything into widget state."

## CLI integration

The CLI should grow one launch command:

```bash
dart run bin/tracelite.dart visualize <path>
```

`<path>` can be a raw trace, compare artifact, suite manifest, decision artifact,
workload summary, graph-data directory, or a directory containing any mix of
those. The CLI should pass the absolute path to the app and avoid copying large
artifacts.

For headless environments, the same query layer should support:

```bash
dart run bin/tracelite.dart inspect <path> --summary=json
```

That keeps the visualizer's data model testable without launching Flutter.

## First milestone

The first useful slice should be small but real:

1. Add a Flutter desktop app package or `tool/visualizer_app`.
2. Open `.tlt-region`, compare JSON, workload-summary JSON, and graph-data
   directories.
3. Show a workspace browser with schema validation and trace-health status.
4. Implement a single-trace timeline with range selection, filters, selection
   details, and visible-range aggregation table.
5. Implement a peer-comparison table from compare artifacts with measured elapsed,
   scenario elapsed, SQLite call counts/time, repetition distribution, and trace
   health.
6. Load existing tracelite compare, workload, graph-data, and raw trace artifacts
   and make the UI reveal SQLite call volume, timing distribution, peer
   differences, and trace-health issues without hard-coded knowledge of the
   producing library.

This milestone proves the app's value without waiting for finalized `.tlt`
archives, live capture, stack sampling, or packaged installers.

## Later milestones

Milestone 2:

- experiment diff screen backed by decision artifacts;
- synchronized two-trace panes;
- counter/gauge charts;
- correlation-chain inspector;
- saved view/bookmark state.

Milestone 3:

- finalized `.tlt` writer/loader;
- Perfetto and Chrome trace export/import where useful;
- SQL fingerprinting and redacted raw SQL display;
- packaged macOS release, then Linux and Windows builds;
- optional graph-data-only web build.

Milestone 4:

- live capture design, including producer back-pressure, region reset, track-slot
  recycling, and safe string-pool handling;
- stack-sample attribution view if the sampler becomes production-worthy.

## Non-goals

- It is not a hosted SaaS trace service.
- It is not a replacement for Dart DevTools interactive debugging.
- It is not a component library for downstream project dashboards.
- It should not require raw SQL text by default; SQL grouping should use
  fingerprints/redacted summaries unless users explicitly opt into unsafe detail.
- It should not claim reactive support for a peer unless the peer adapter models
  that library's real reactive semantics.

## Open decisions

- Package shape: `tool/visualizer_app` inside this package versus a sibling
  `tracelite_visualizer` package. Start inside the repo; split only if publishing
  pressure justifies it.
- App launch in development: `dart run bin/tracelite.dart visualize` can print a
  command if no built app is available, then later launch packaged binaries.
- Artifact linking: compare/suite artifacts should gain optional relative raw
  trace paths so the visualizer can drill from summary rows into traces.
- Large-trace storage: finalized `.tlt` should probably be compressed and indexed
  sidecar-aware, but the current `.tlt-region` support should unblock the first
  app slice.
