# tracelite — Visualizer Data Binding

**Status:** Draft v0.1
**Companion to:** `format-spec.md`, `aggregator-api.md`
**Audience:** Design review for the cross-library SQLite tracing package

The format spec defines what's *in* a trace. The aggregator API defines how programs *query* one. This doc defines how the *visualizer* keeps queries and rendering in sync — the contract between the aggregator's stats engine and the Flutter widget tree.

The binding layer has to satisfy six properties:

| Property | Why |
|---|---|
| **Sub-frame requery on scope change** | Pan/zoom on a 60fps timeline produces 16ms-cadence range updates. Each one must complete + render before the next frame. |
| **Cache reuse across overlapping scopes** | Dragging the scrub bar by 10% should recompute ~10% of work, not 100%. |
| **Multi-panel deduplication** | Three panels asking for "spans during the visible range" should run that filter once, share the result. |
| **Offload expensive work** | Some queries (full-trace diff, p99 over millions of events) take seconds. They must not block the frame. |
| **Composable** | A panel deriving its display from "selected span + visible range + active filters" should declare those dependencies, not orchestrate them. |
| **Idiomatic Flutter** | Standard `ValueListenable`/`Listenable` interop so widgets bind via `ValueListenableBuilder` with no special infrastructure. |

## Outline

1. [The problem](#1-the-problem)
2. [Conceptual model: probes, scope, derivation](#2-conceptual-model-probes-scope-derivation)
3. [Probe API](#3-probe-api)
4. [Built-in scope sources](#4-built-in-scope-sources)
5. [Derived probes (composition)](#5-derived-probes-composition)
6. [Frame coalescing](#6-frame-coalescing)
7. [Background-isolate probes](#7-background-isolate-probes)
8. [Flutter widget integration](#8-flutter-widget-integration)
9. [Cross-trace probes (diff mode)](#9-cross-trace-probes-diff-mode)
10. [Lifecycle and disposal](#10-lifecycle-and-disposal)
11. [Worked examples](#11-worked-examples)
12. [Performance contract](#12-performance-contract)
13. [Open questions](#13-open-questions)

---

## 1. The problem

The visualizer has at least seven panels that all share state and must update reactively:

| Panel | Inputs | Output |
|---|---|---|
| Timeline | trace, visible range, track filters, span filters, selection | painted spans on track lanes |
| Aggregations table | trace, visible range, span filters | per-span statistics |
| Selection details | trace, selected span | args, chain, concurrent spans |
| Distribution panel | trace, visible range, selected span type | histogram |
| Attribution panel | trace, visible range | per-package wall time |
| Filter UI | filter state | filter chips, active count |
| Diff panel (if A/B mode) | trace A, trace B, both ranges, filters | per-span deltas |

A naïve implementation gives every panel its own `setState` plumbing and every interaction (zoom, scrub, click, filter toggle) imperatively notifies every panel. That's how visualizers turn into bug factories.

The right shape is a **directed acyclic graph of typed reactive nodes**, where:

- **Sources** are the things that change in response to user input (visible range, filter set, selection, loaded trace).
- **Derived nodes** compute values from sources or other derived nodes. They cache their last result and only recompute when an input changes.
- **Subscribers** (widgets) subscribe to a node and rebuild when its value changes.

A scrub-bar drag mutates a single source (the range). Dirty propagation marks dependents stale. Subscribers get notified at the next frame. Each derived node recomputes once, no matter how many panels depend on it.

This is reactive state management — the same shape as Riverpod, MobX, Recoil, signals — applied to trace queries.

## 2. Conceptual model: probes, scope, derivation

Three primitives:

### Probe

A `Probe<T>` is a typed reactive node holding a value. Subscribers can read its current value or listen for changes. Probes implement `ValueListenable<T>` so Flutter's standard widget machinery binds to them directly.

```dart
abstract class Probe<T> implements ValueListenable<T> {
  T get value;
  void addListener(VoidCallback listener);
  void removeListener(VoidCallback listener);
  void dispose();
}
```

Two kinds of probe:

- **Source probes** — hold mutable state. `value` setter notifies listeners. Used for things the user changes directly (visible range, active filters, selection).
- **Derived probes** — compute value from other probes. Read-only. Recompute only when an input notifies.

### Scope

A `Scope` is a bundle of source probes that together describe "what the user is currently looking at." The visualizer has one root `VisualizerScope`:

```dart
class VisualizerScope {
  final TraceProbe trace;             // currently loaded trace
  final RangeProbe range;             // visible time window
  final FilterProbe filters;          // active span/track filters
  final SelectionProbe<Span> spanSelection;
  final SelectionProbe<Track> trackSelection;
  // ... other UI state
}
```

Panels never reach for global state; they read from a scope passed in by the host widget. This makes panels reusable — a diff view instantiates *two* scopes, one per loaded trace, and renders the same panels twice.

### Derivation

`Probe.derive(...)` builds a new probe from inputs and a compute function. The compute runs once at construction (or first read), then re-runs only when an input notifies.

```dart
final visibleSpans = Probe.derive(
  inputs: (scope.trace, scope.range, scope.filters),
  compute: (trace, range, filters) => trace.spans
      .during(range)
      .where(filters.matches),
);
```

The graph is implicit: tracelite tracks which source probes are read inside `compute` and registers listeners automatically. When any input changes, downstream probes are marked dirty; subscribers are notified at the next frame.

## 3. Probe API

### Source probes

```dart
class SourceProbe<T> extends Probe<T> {
  SourceProbe(T initial);

  @override
  T get value;

  set value(T newValue);  // setter notifies if !=

  /// Update without notifying. Useful for batch updates that will
  /// trigger a single notification at the end.
  void updateSilently(T newValue);

  /// Notify all listeners immediately, even if value is unchanged.
  /// Rare; used when the same object's contents changed in place.
  void notifyForce();
}
```

Equality check on set: by default, source probes use `==` to skip notifying when the new value equals the old. For mutable types (Sets, Maps, custom value classes), users can pass a custom comparator.

### Derived probes

```dart
abstract class DerivedProbe<T> extends Probe<T> {
  /// True if the cached value needs to be recomputed.
  bool get isStale;

  /// Force immediate recomputation, even if not stale. Returns the
  /// new value.
  T recomputeNow();
}
```

Derivation factory:

```dart
// One input
Probe.derive1<I, O>(Probe<I> input, O Function(I) compute);

// Tuple inputs
Probe.derive2<A, B, O>(Probe<A> a, Probe<B> b, O Function(A, B) compute);
Probe.derive3<...>(...);
// up to derive5; for more, use derive(inputs: [...], compute: ...)

// Variadic
Probe.derive<O>({
  required List<Probe<dynamic>> inputs,
  required O Function() compute,
});
```

The N-ary forms preserve type info for ergonomic destructuring. The variadic form is for cases where input types vary.

### Implicit dependency tracking

A more concise pattern, inspired by signals_dart and Solid.js:

```dart
final visibleSpans = Probe.computed(() => trace.value.spans
    .during(range.value)
    .where(filters.value.matches));
```

`Probe.computed` runs `compute` once in tracking mode; `Probe<T>.value` accesses inside the body register that probe as a dependency. Re-runs whenever any tracked dependency notifies.

This is more concise but trickier: dependencies must be reachable on every code path (no conditional access without re-tracking). The explicit `Probe.derive*` form is recommended for clarity; `Probe.computed` is available for simple inline cases.

### Async derivation

For expensive computations:

```dart
final diffResult = Probe.deriveAsync2(
  scope.traceA,
  scope.traceB,
  (a, b) async => TraceDiff.compare(baseline: a, change: b),
  initial: AsyncValue.loading(),
);

// diffResult.value is AsyncValue<TraceDiff>:
//   AsyncValue.loading()
//   AsyncValue.data(diff)
//   AsyncValue.error(...)
```

Consumers handle the three states explicitly. While loading, the UI shows a spinner; on error, an error message; on data, the result.

When inputs change while loading, the in-flight computation is cancelled (via a `CancellationToken` passed to the compute function) and a new one starts.

## 4. Built-in scope sources

Standard probes the visualizer ships:

```dart
/// Currently loaded trace.
class TraceProbe extends SourceProbe<Trace?> { ... }

/// Visible time window. Pan/zoom mutates this.
class RangeProbe extends SourceProbe<TimeRange> {
  /// Convenience: zoom around a center point.
  void zoom(double factor, Duration around);

  /// Convenience: pan by a delta.
  void pan(Duration delta);

  /// Reset to full trace range.
  void resetToFull();
}

/// Set of active span/track/category filters.
class FilterProbe extends SourceProbe<FilterSet> {
  void toggleSpan(SpanType s);
  void toggleTrack(Track t);
  void toggleCategory(SpanCategory c);
  void clearAll();
}

/// Currently selected span (or null). Click on timeline updates this.
class SelectionProbe<T> extends SourceProbe<T?> {
  void select(T item);
  void clear();
}

/// Currently focused chain (correlation ID), if user is in chain-view mode.
class ChainSelectionProbe extends SourceProbe<int?> { ... }

/// Annotation set — user-created bookmarks/notes on the timeline.
class AnnotationProbe extends SourceProbe<List<Annotation>> {
  void add(Annotation a);
  void remove(Annotation a);
  void update(Annotation a);
}
```

These cover the standard visualizer state. Custom panels can introduce additional source probes scoped to themselves.

### Shared derived probes (deduplication)

The promise that "three panels asking for visible spans run the filter once" requires those three panels to bind to **the same derived probe instance**, not three independently-created derivations. The scope owns the shared derivations:

```dart
class VisualizerScope {
  final TraceProbe trace;
  final RangeProbe range;
  final FilterProbe filters;
  final SelectionProbe<Span> spanSelection;
  // ... other source probes ...

  // Shared derived probes — built once per scope, owned by the scope,
  // disposed when the scope is. Panels that need these results bind
  // here instead of constructing their own.
  late final Probe<List<Span>> visibleSpans = Probe.derive3(
    trace, range, filters,
    (t, r, f) => t == null ? const [] : t.spans.during(r).where(f.matches).toList(),
  );

  late final Probe<Map<SpanType, DurationStats>> spanStatsByType =
      Probe.derive1(visibleSpans, (spans) =>
          spans.byType.aggregate((g) => g.durations.stats()));

  // ... other shared derivations ...
}
```

Panels that need *panel-local* derivations (something only that panel cares about) own those probes themselves and dispose them in `dispose()`. The rule of thumb: if any other panel might want the same answer, hoist the derivation into the scope. The visualizer's standard panels (timeline lanes, aggregations table, distribution panel, attribution panel) all read shared scope-level derivations.

## 5. Derived probes (composition)

The visualizer's panels are mostly stacks of derived probes:

```dart
// Layer 1: spans visible in the current range, after filters
final visibleSpans = Probe.derive3(
  scope.trace,
  scope.range,
  scope.filters,
  (trace, range, filters) {
    if (trace == null) return const <Span>[];
    return trace.spans.during(range).where(filters.matches).toList();
  },
);

// Layer 2: per-span-type statistics (used by aggregations panel)
final spanStats = Probe.derive1(visibleSpans, (spans) =>
  spans.byType.aggregate((g) => g.durations.stats()));

// Layer 3: top 10 spans by total wall (used by hot-list widget)
final topByWall = Probe.derive1(spanStats, (stats) {
  final entries = stats.entries.toList()
    ..sort((a, b) => b.value.sum.compareTo(a.value.sum));
  return entries.take(10).toList();
});

// Layer 4: detail for currently selected span (used by detail panel)
final selectedDetail = Probe.derive2(scope.spanSelection, scope.trace, (sel, t) {
  if (sel == null || t == null) return null;
  return SpanDetail(
    span: sel,
    chain: sel.chain,
    concurrent: sel.concurrent.toList(),
    args: sel.args,
  );
});
```

Each panel binds to whichever leaf-or-intermediate probe matches its needs. Multiple panels reading `visibleSpans` share the computation.

### Lazy evaluation

Probes don't recompute eagerly. A derived probe is marked stale when an input changes; recomputation happens on the next read of `value` or the next subscriber notification. This means:

- Panels not currently visible (collapsed sidebar, hidden tab) don't pay for queries they're subscribed to but no one reads.
- Listeners are notified only when actually-read values change.
- Diamond dependency graphs (A → B and A → C, both feeding D) recompute D once per A change, not twice.

### Custom equality / change detection

By default, derived probes use `==` to compare new vs. old computed value. For expensive structural comparisons, override:

```dart
Probe.derive1(
  visibleSpans,
  (spans) => spans.length,
  // Default == is fine for int. For complex values:
  // equals: (a, b) => deepEquals(a, b),
);
```

Returning `==`-equal values doesn't notify downstream — even if `compute` ran. This lets expensive intermediate computations short-circuit upward when the user-visible result didn't change.

## 6. Frame coalescing

Pan/zoom drags can fire scope changes faster than the screen refreshes. Without coalescing, the visualizer recomputes every panel on every drag event — wasted work.

Tracelite's binding scheduler coalesces by frame:

```
[frame N]   range.value = T0          ← marks dependents dirty
            range.value = T1          ← still dirty, no extra work
            range.value = T2          ← still dirty, no extra work
            ━━━━━━━━━━━━━━━━━━━━━━ frame boundary
[frame N+1] notify subscribers        ← derived probes recompute once with T2
            widgets rebuild
```

Source probes don't notify synchronously; they enqueue a notification on the next frame. Multiple changes to the same probe within a frame collapse. Multiple probes changing within a frame produce a single batched notification cycle.

### Scheduler abstraction

The binding uses a `ProbeScheduler` interface, not Flutter APIs directly:

```dart
abstract class ProbeScheduler {
  /// Schedule [callback] to run at the next coalescing boundary.
  /// Calling repeatedly with different callbacks within one boundary
  /// MAY coalesce them (only the last is guaranteed to run if the
  /// scheduler folds duplicates by key).
  void scheduleNotify(VoidCallback callback);

  /// Synchronous flush. For tests and CLI use.
  void flush();
}
```

Three concrete implementations:

| Scheduler | Boundary | Used by |
|---|---|---|
| `FrameScheduler` | Next vsync frame | Flutter visualizer |
| `MicrotaskScheduler` | Next microtask | CLI report generation, non-Flutter consumers |
| `SynchronousScheduler` | Immediate | Tests, debugging |

The Flutter implementation explicitly *requests a frame* (`SchedulerBinding.instance.scheduleFrame()`) before registering its callback, then uses `scheduleFrameCallback` (which fires *during* the next frame) — **not** `addPostFrameCallback`, which only fires after a frame the engine independently scheduled. The previous draft of this doc named `addPostFrameCallback` incorrectly: post-frame callbacks don't request a frame, so a probe change outside an active frame could cause indefinite delay before notifying.

For headless / non-Flutter consumers, the microtask scheduler runs at the next event-loop turn, which is sufficient because there are no UI frames to coalesce against.

### Opt out for tests

Tests often want synchronous notification:

```dart
ProbeScheduler.testMode(() {
  range.value = newRange;
  expect(visibleSpans.value, ...);  // already updated
});
```

## 7. Background-isolate probes

Some queries are too expensive to run on the UI isolate even with caching. Examples:

- `TraceDiff.compare` over millions of events
- p99.999 over a multi-million-event distribution
- attribution by leaf-frame across long sample streams
- gzip decompression of a freshly loaded trace

For these, derive on a background isolate:

```dart
final diff = Probe.deriveAsyncIsolate2(
  scope.traceA,
  scope.traceB,
  (ah, bh, ct) async {  // handles, not Trace objects; ct = CancellationToken
    final a = await Trace.attachReadOnly(ah);
    final b = await Trace.attachReadOnly(bh);
    return TraceDiff.compare(baseline: a, change: b);
  },
  initial: const AsyncValue.loading(),
);
```

### Worker inputs are TraceHandles, not Trace objects

`Probe.deriveAsyncIsolate*` cannot ship a `Trace` to a worker. `Trace` carries native resources (mmap'd file descriptors, FFI references to runtime tables, lazy decoders) that aren't `SendPort`-transferable. The worker compute function receives a `TraceHandle` — a small serializable record containing:

```dart
class TraceHandle {
  final String filePath;          // path to the .tlt file
  final List<int> formatVersion;  // [major, minor]
  final String regionId;          // optional: live-mode region path
  final IndexManifest indices;    // which indices the loader built
}
```

Inside the worker, `await Trace.attachReadOnly(handle)` re-opens the file (mmap'd shared, read-only) and rebuilds the lazy view. Worker-side `Trace` instances are independent of the UI-side instance; they don't compete for memory.

Implementation:
- A worker isolate is spawned lazily on first use.
- Handle inputs are passed via `Isolate.run` (or a long-lived `SendPort` for repeated use). Handles are `Object`s, copyable across isolates.
- A `CancellationToken` is checked periodically inside the compute fn; when scope changes mid-flight, the token is signaled and the worker bails.
- Results return as `AsyncValue.data(...)` on the UI isolate.

### Cancellation is cooperative

```dart
abstract class CancellationToken {
  bool get isCancelled;
  void throwIfCancelled();   // shortcut for `if (isCancelled) throw CancelledError()`
  Future<void> get whenCancelled;
}
```

Compute functions that don't periodically check `isCancelled` are not actually cancellable — they run to completion in the worker, and only the result is discarded on the UI side. This is *cost control* (the UI doesn't block waiting for a stale result), not a hard cancellation contract. Treat the token as a hint; expensive long-running computes should poll it at natural checkpoints.

## 8. Flutter widget integration

Probes implement `ValueListenable<T>`, so the standard pattern is `ValueListenableBuilder`:

```dart
ValueListenableBuilder<Map<SpanType, DurationStats>>(
  valueListenable: spanStats,
  builder: (context, value, _) => StatsTable(value),
)
```

For multi-probe panels, compose probes first into a derived one:

```dart
final timelinePanelData = Probe.derive3(
  scope.trace,
  scope.range,
  scope.filters,
  (trace, range, filters) => TimelinePanelData(...),
);

ValueListenableBuilder<TimelinePanelData>(
  valueListenable: timelinePanelData,
  builder: (context, data, _) => TimelinePainter(data: data),
)
```

For idiomatic Flutter consumers who prefer hooks-style, a small helper:

```dart
class ProbeScope extends InheritedWidget {
  final VisualizerScope scope;
  // ...
}

extension ProbeContext on BuildContext {
  T watch<T>(Probe<T> probe) {
    /* register listener, trigger rebuild on change */
  }

  T read<T>(Probe<T> probe) => probe.value;  // no listener, no rebuild
}

// Usage:
@override
Widget build(BuildContext context) {
  final stats = context.watch(spanStats);
  return StatsTable(stats);
}
```

This is the same shape as Provider's `context.watch`, but bound directly to probes.

### Custom paint integration

The timeline track lanes are CanvasKit-painted, not widget-tree-driven. They subscribe to probes directly and call `markNeedsPaint` on change:

```dart
class TimelinePainter extends CustomPainter {
  TimelinePainter({required this.data});
  final TimelinePanelData data;

  @override
  bool shouldRepaint(TimelinePainter old) => old.data != data;
  // ...
}

// Hosting widget:
@override
Widget build(BuildContext context) {
  return ValueListenableBuilder<TimelinePanelData>(
    valueListenable: timelinePanelData,
    builder: (_, data, __) => CustomPaint(painter: TimelinePainter(data: data)),
  );
}
```

The painter rebuilds with new data; `shouldRepaint` skips a repaint if data is identity-equal (which happens when an upstream probe's compute returned an `==`-equal value).

## 9. Cross-trace probes (diff mode)

Diff mode loads two traces simultaneously. Each gets its own scope:

```dart
class DiffScope {
  final VisualizerScope a;
  final VisualizerScope b;
  final SourceProbe<bool> linkRanges;  // sync zoom across panes?

  // Diff-specific derived probes:
  late final Probe<AsyncValue<TraceDiff>> diff = Probe.deriveAsyncIsolate2(
    a.traceHandle,
    b.traceHandle,
    (ah, bh, ct) async {
      // Workers receive a serializable handle (path + format version +
      // index manifest), not the in-memory Trace object. Each worker
      // re-attaches read-only via Trace.attachReadOnly(handle).
      final ta = await Trace.attachReadOnly(ah);
      final tb = await Trace.attachReadOnly(bh);
      return TraceDiff.compare(baseline: ta, change: tb);
    },
    initial: const AsyncValue.loading(),
  );
}
```

When `linkRanges` is true, both ranges are kept in sync. The link uses **batched notification with a cycle guard**, not silent updates — silent updates skip listeners, which would mean panels bound to `b.range` see no change and don't repaint.

```dart
class _RangeLink {
  _RangeLink(this.scope) {
    scope.linkRanges.addListener(_onLinkToggle);
    scope.a.range.addListener(_aChanged);
    scope.b.range.addListener(_bChanged);
  }

  // Cycle guard: while we're propagating from a→b, ignore the b→a
  // mirror callback that fires when our `b.range = ...` runs.
  bool _propagating = false;

  void _aChanged() {
    if (!_propagating && scope.linkRanges.value && scope.a.range.value != scope.b.range.value) {
      _propagating = true;
      try {
        scope.b.range.value = scope.a.range.value;  // normal set; notifies listeners
      } finally {
        _propagating = false;
      }
    }
  }

  void _bChanged() {
    if (!_propagating && scope.linkRanges.value && scope.a.range.value != scope.b.range.value) {
      _propagating = true;
      try {
        scope.a.range.value = scope.b.range.value;
      } finally {
        _propagating = false;
      }
    }
  }

  void _onLinkToggle() {
    if (scope.linkRanges.value) {
      // Snap both ranges together when linking activates.
      _aChanged();
    }
  }

  void dispose() {
    scope.linkRanges.removeListener(_onLinkToggle);
    scope.a.range.removeListener(_aChanged);
    scope.b.range.removeListener(_bChanged);
  }
}
```

Either pane can drive the other (the `_aChanged` / `_bChanged` symmetry); the cycle guard prevents an infinite ping-pong without skipping notifications. Listeners on `b.range` see the change normally and repaint.

The diff panel renders timelines from both scopes side by side, with the precomputed `diff` probe overlaying delta annotations.

## 10. Lifecycle and disposal

### Probe creation

Source probes are owned by their `Scope` and disposed when the scope is. Derived probes are owned by whoever calls `Probe.derive*` — typically a panel widget's `State` object.

### Listener cleanup

The standard `ValueListenable` contract: listeners must be removed or the probe disposed. In `StatefulWidget`:

```dart
class _PanelState extends State<Panel> {
  late final Probe<...> _probe;

  @override
  void initState() {
    super.initState();
    _probe = Probe.derive2(/* ... */);
  }

  @override
  void dispose() {
    _probe.dispose();  // releases input listeners
    super.dispose();
  }
}
```

`Probe.derive*` automatically registers listeners on inputs. `dispose()` unregisters them, so derived probes don't leak listeners after their scope ends.

### Scope disposal

When the user closes a trace (or in diff mode, swaps the loaded traces):

```dart
visualizerScope.dispose();
// disposes: trace, range, filters, selection, all derived probes that
// were registered with the scope as their owner.
```

This cascades through any derived probes registered as owned by the scope; widgets bound to them see the listener removed and rebuild empty.

## 11. Worked examples

### Example A: Aggregations panel

The bottom panel that shows per-span statistics for the visible time range.

```dart
class AggregationsPanel extends StatelessWidget {
  const AggregationsPanel({required this.scope});
  final VisualizerScope scope;

  @override
  Widget build(BuildContext context) {
    // Bind directly to the scope's shared derivation. Three panels
    // reading scope.spanStatsByType will recompute it ONCE per
    // scope-input change, not three times.
    return ValueListenableBuilder<Map<SpanType, DurationStats>>(
      valueListenable: scope.spanStatsByType,
      builder: (_, statsByType, __) {
        final rows = statsByType.entries
            .map((e) => AggregationRow(spanType: e.key, stats: e.value))
            .toList();
        return DataTable(rows: rows);
      },
    );
  }
}

// Note: the panel is now StatelessWidget — there's no panel-local
// derivation to dispose. The scope owns the lifetime of
// `spanStatsByType`. The earlier draft of this doc showed
// `_AggregationsPanelState` creating its own `Probe.derive3` in
// initState; that pattern means N panels = N derivations, defeating
// the deduplication promise. Don't do it.
//
// For panel-local derivations (truly local state, like a panel's
// own scroll position), use the StatefulWidget pattern with
// `initState` / `dispose`:

class _LocalPanelState extends State<LocalPanel> {
  late final Probe<...> _localOnlyDerivation;

  @override
  void initState() {
    super.initState();
    _localOnlyDerivation = Probe.derive2(
      widget.scope.someSharedProbe,
      _ourLocalSourceProbe,
      _compute,
    );
  }

  @override
  void dispose() {
    _localOnlyDerivation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<AggregationRow>>(
      valueListenable: _rows,
      builder: (_, rows, __) => DataTable(rows: rows),
    );
    return ValueListenableBuilder(
      valueListenable: _localOnlyDerivation,
      builder: (_, value, __) => /* render */,
    );
  }
}
```

The user drags the scrub bar; `range` updates; on the next frame, the scope's `visibleSpans` derivation recomputes once, and downstream of it `spanStatsByType` recomputes once. Every `ValueListenableBuilder` reading either probe rebuilds — but the *computation* happens once per scope change, not once per panel.

### Example B: Timeline + selection coupling

Click a span on the timeline → detail panel updates. Two probes communicate via the scope:

```dart
class TimelineLane extends StatelessWidget {
  const TimelineLane({required this.scope, required this.track});
  final VisualizerScope scope;
  final Track track;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Span>>(
      valueListenable: _spansForTrack,  // derived earlier
      builder: (_, spans, __) => GestureDetector(
        onTapDown: (details) {
          final clicked = _findSpanAt(spans, details.localPosition);
          if (clicked != null) scope.spanSelection.value = clicked;
        },
        child: CustomPaint(painter: LanePainter(spans: spans, /* ... */)),
      ),
    );
  }
}

class DetailPanel extends StatelessWidget {
  const DetailPanel({required this.scope});
  final VisualizerScope scope;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Span?>(
      valueListenable: scope.spanSelection,
      builder: (_, span, __) {
        if (span == null) return const Text('Click a span');
        return SpanDetailView(span: span);
      },
    );
  }
}
```

The `TimelineLane` doesn't know `DetailPanel` exists. They communicate exclusively through `scope.spanSelection`. Decoupled by the scope.

### Example C: Diff view

```dart
class DiffView extends StatefulWidget {
  const DiffView({required this.scope});
  final DiffScope scope;

  @override
  State<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends State<DiffView> {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: TraceView(scope: widget.scope.a)),
        VerticalDivider(),
        Expanded(child: TraceView(scope: widget.scope.b)),
        SizedBox(width: 320, child: DiffSidebar(diff: widget.scope.diff)),
      ],
    );
  }
}

class DiffSidebar extends StatelessWidget {
  const DiffSidebar({required this.diff});
  final Probe<AsyncValue<TraceDiff>> diff;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AsyncValue<TraceDiff>>(
      valueListenable: diff,
      builder: (_, value, __) => switch (value) {
        AsyncLoading() => const CircularProgressIndicator(),
        AsyncError(:final error) => Text('Diff failed: $error'),
        AsyncData(:final data) => DiffTable(diff: data),
      },
    );
  }
}
```

The diff computation runs on a background isolate. While loading, the sidebar shows a spinner. The two trace panels remain interactive.

### Example D: Live aggregation as the user scrubs

This is the visualizer's most-exercised path. The aggregations panel updates 60 times per second as the user drags.

```dart
// Without frame coalescing — bad:
//   60 drag events/sec → 60 range.value sets/sec → 60 recomputes/sec → 60 widget rebuilds/sec
//   Each recompute is sub-ms, but cumulative cost dominates the frame budget.

// With frame coalescing — good:
//   60 drag events/sec → 60 range.value sets/sec, but only 1 notify/frame
//                      → 60 recomputes/sec (capped at vsync) → 60 paints/sec (vsync rate)
//
// And with cache reuse:
//   Range from [T0..T1] → range expanded to [T0..T1+10ms]
//   Span index lookup is O(log N), so the "during" filter answers in <100µs.
//   The aggregator caches t-digest state from the prior range and incrementally adds
//   the spans newly in-range.
```

The performance contract (§12) makes this concrete.

## 12. Performance contract

| Operation | Target |
|---|---|
| Source probe `value =` | <1 µs (no notify; just dirty mark + frame schedule) |
| Frame boundary notify | <100 µs to walk dirty graph for typical UI (a few dozen nodes) |
| Derived probe recompute (cached aggregator query) | <500 µs for typical queries |
| Derived probe recompute (uncached scan over visible spans) | <5 ms for traces with up to 100K visible spans |
| Async-isolate diff (1M events × 1M events) | <500 ms |
| Frame budget (16.6 ms at 60Hz) | not exceeded by binding overhead even with all panels visible |

The budget breakdown for a worst-case scrub event with 7 panels visible:

- Source probe set: 1 µs
- Frame boundary notify walk: 100 µs
- 7 derived probes recompute: 7 × 500 µs = 3.5 ms
- 7 widget rebuilds + paint: ~5 ms (Flutter's accounting)
- **Total: ~8.6 ms** — within the 16.6 ms frame budget with headroom for the painting.

If the cumulative cost approaches the budget, the binding system has tools:

- **Debouncing**: a probe can opt to recompute only every N frames or after M ms of stability.
- **Throttling**: rapid input changes batch into one recompute instead of one-per-frame.
- **Background offload**: expensive probes move to the worker isolate, becoming `AsyncValue<T>`.

## 13. Open questions

1. **Cycles.** Mutual derivation (A depends on B which depends on A) is a programming error but easy to introduce by accident. Detect and throw at construction time? Detect and break the cycle with a snapshot? Default: throw with a clear stack-trace. Configurable via `Probe.config.cycleHandling`.

2. **Initial values for async probes.** `AsyncValue<T>.loading()` is a sensible default, but some panels want "show last successful result while recomputing" semantics. Add a `keepPrevious: true` flag to `deriveAsync*` that returns `AsyncValue.data(staleValue)` until the new compute resolves.

3. **Scope serialization.** Should scope state be serializable so the visualizer can restore session state across app restarts (last opened trace, last visible range, last selected span)? Probably yes; would require source probes to be JSON-encodable or have user-provided codecs.

4. **Multi-pane shared scope.** When two panes share a single trace but show different views, do they share a scope (so range updates propagate) or get sibling scopes (so they pan independently)? Probably both, configurable per-pane.

5. **Test ergonomics.** `ProbeScheduler.testMode` is a coarse hammer. Should there be finer-grained "fire one frame" / "fire and assert no further updates" helpers for testing reactive flow?

6. **Devtool integration.** Can we expose the probe DAG to Dart DevTools for debugging? "Why did this widget rebuild?" — surface the dependency chain. Probably worth a small inspector after the binding lands.

## What's next

The three remaining design docs before any implementation:

| Doc | Scope |
|---|---|
| Runtime mmap protocol | Slot reservation atomics, dropped-event marker semantics, drainage handshake |
| Span ID registry | Full enumerated list of every reserved span ID across all categories |
| Peer interface contract | What a "scenario" is, what shape `--interface=drift` adapters take, how scenarios stay comparable |

The mmap protocol is the highest-risk: it's the cross-language, cross-process plumbing that the format spec hand-waves over. If anything in the format spec turns out to be wrong, it surfaces here.
