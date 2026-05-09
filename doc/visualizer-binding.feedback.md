# Feedback: Visualizer Data Binding

Reviewed: `visualizer-binding.md`

## TLDR

The visualizer binding has the right shape: typed sources, derived nodes, frame coalescing, and background work for expensive queries. It should stay behind the aggregator/runtime specs in implementation order. The current design needs fixes around Flutter scheduling, cross-isolate data passing, scope sharing, and a few example-level type bugs before it can be a stable contract.

Recommended direction: implement the smallest probe layer that satisfies the visualizer, with explicit derivations first. Avoid building a general-purpose signals framework until the real panels force it.

## Blockers

### 1. `addPostFrameCallback` does not request a frame

The doc calls `WidgetsBinding.instance.addPostFrameCallback` the natural hook for frame coalescing. Flutter documents that post-frame callbacks run after a frame and do not request a new frame. If a probe changes outside an active frame, a post-frame callback may never fire.

Use a scheduler that explicitly requests a frame when needed, or use a microtask scheduler for non-widget contexts and a frame-start callback for Flutter contexts.

### 2. Range linking uses `updateSilently`, so the second pane may not repaint

The diff range-link example silently updates `b.range` from `a.range`. Silent updates skip listeners, which means panels bound to `b.range` can remain stale. Use a batched notification with a cycle guard instead:

- set `b.range` normally;
- tag the update origin;
- ignore the mirrored callback when it returns to the source.

### 3. Worker-isolate examples pass the wrong kind of data

The docs show async isolate derivations accepting `Trace` objects directly. Dart isolate messages copy mutable object graphs and cannot send objects with native resources such as dynamic libraries/native wrappers. If traces are mmap-backed, worker APIs should pass a serializable `TraceHandle` such as file path, format version, region id, and index manifest, then reopen read-only in the worker.

### 4. `DiffScope.diff` has an `AsyncValue` type mismatch

The example declares `late final Probe<TraceDiff> diff` but passes `initial: AsyncValue.loading()`. The type should be `Probe<AsyncValue<TraceDiff>>`, matching the later `DiffSidebar` example.

### 5. Panel-local derived probes do not satisfy multi-panel deduplication

The design promises three panels asking for "visible spans" run the filter once. But the worked examples create derived probes inside panel `State` objects, which means each panel can recompute independently. Shared expensive derivations need to be owned by `VisualizerScope` or by a scoped memoization layer keyed by query inputs.

## Important clarifications

- The explicit `Probe.derive*` API should be the default contract. Keep `Probe.computed` optional until dependency re-tracking, conditional dependencies, and disposal behavior are proven.
- Async cancellation is cooperative. If compute functions do not check the token, the worker continues and the result is discarded. State this as cost control, not true cancellation.
- Source probes using `==` with mutable `Set`, `Map`, or custom mutable values will miss changes. Prefer immutable value objects for all scope state.
- `ValueListenableBuilder` rebuild behavior is clear, but lazy derived recomputation needs exact ordering: does notify happen before or after recompute, and can `value` throw?
- `ProbeScheduler.testMode` should be scoped and nestable; tests will need deterministic "flush one cycle" helpers.
- The performance targets are good aspirations, but should be labeled as targets until validated against real trace sizes and Flutter canvases.
- CanvasKit is a web renderer. The native visualizer still uses Flutter painting APIs; call this custom-painted timeline lanes rather than CanvasKit-painted lanes unless web-only is intended.
- Scope serialization is useful, but not v0.1. Persisting file paths, selected spans, and filters requires stable trace identity and invalidation rules.

## External checks

- Flutter `addPostFrameCallback` does not request a new frame: https://api.flutter.dev/flutter/scheduler/SchedulerBinding/addPostFrameCallback.html
- Dart isolate sends copy mutable object graphs and disallow native-resource-backed objects: https://api.dart.dev/dart-isolate/SendPort/send.html
- `dart:developer` Timeline/TimelineTask already has async task concepts and DevTools integration, useful as an interop/export target: https://api.dart.dev/dart-developer/

## Suggested next edits

1. Replace post-frame scheduling with an explicit scheduler abstraction.
2. Fix range linking to notify dependents while preventing cycles.
3. Change worker APIs to pass `TraceHandle`, not `Trace`.
4. Fix `Probe<AsyncValue<TraceDiff>>` examples.
5. Move shared expensive derivations into `VisualizerScope` or a query cache.
