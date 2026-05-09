# Feedback: Peer Interface Contract

Reviewed: `peer-interface-contract.md`

## TLDR

This is the most product-defining spec. The narrow common interface and fairness flags are the right idea, and the doc is refreshingly honest about what it cannot measure. The contract needs a stricter lifecycle, more precise execution result semantics, and formal scenario capability requirements before benchmark numbers would be defensible.

Recommended direction: keep the API lean, but make benchmark fairness machine-readable instead of prose-only.

## Blockers

### 1. Scenario lifecycle is internally inconsistent

The lifecycle opens the database once, then calls `setup()` repeatedly when `freshDbPerRep` is true. That can recreate schema or seed data on an already-open database unless every setup is manually idempotent. It also says setup is excluded, but warmup setup/teardown behavior varies by fresh/shared mode.

Define two explicit lifecycle templates:

- Fresh DB per repetition: open -> setup -> warmup run(s) if any for that DB -> measured run -> teardown -> close -> delete DB, repeated.
- Shared DB across repetitions: open -> setup once -> warmup runs -> measured runs -> teardown -> close.

If warmup mutates the DB, either reset to a snapshot before measured runs or require fresh DB mode.

### 2. The API claims row access by name and index, but only exposes maps

The scope says result columns can be read by name and index. `select` returns `List<Map<String, Object?>>`, which loses stable column order and duplicate column names. Use a row abstraction:

```dart
abstract class SqliteRow {
  Object? operator [](String column);
  Object? at(int index);
  List<String> get columnNames;
  Map<String, Object?> asMap();
}
```

If the benchmark truly only needs by-name maps, remove "and index" from the scope.

### 3. `execute` affected-row semantics are underspecified

SQLite's `sqlite3_changes()` reports rows modified by the most recent INSERT/UPDATE/DELETE only, excludes auxiliary trigger/FK/REPLACE effects, and does not change for other SQL statements. Returning `Future<int>` for DDL, PRAGMA, and statements with RETURNING will create inconsistent adapter behavior.

Use an `ExecutionResult` with fields like `directChanges`, `lastInsertRowId`, `returnedRows`, and `statementKind`, or specify that `execute` is only for statements where direct changed rows are meaningful.

### 4. `executeBatch` needs exact atomicity and fairness semantics

The interface says adapters ideally execute one SQL with many parameter sets as a single transaction. The sample report says "single batch call inside autocommit." Those are different. For fair comparison, define:

- whether `executeBatch` must be atomic;
- whether the harness wraps it in a transaction or the adapter does;
- whether prepare reuse is expected;
- whether per-row fallback is allowed and how it is reported.

Native batching vs fallback should be a structured capability, not a single boolean.

### 5. Scenario capability requirements should be mandatory

The open question already points at this. Make it part of v0.1: every scenario declares required capabilities such as `concurrentReads`, `transactions`, `batching`, `isolateSafe`, `returnsRows`, and `supportsInMemory`. The harness should report explicit unsupported/N/A with the reason, never silently skip or fail late.

## Important clarifications

- Current package docs show `package:sqlite3` bundles SQLite with build hooks on native platforms, while drift's `NativeDatabase` is built on `package:sqlite3`. The high-level claim that every peer links to the same SQLite C library should become an assumption verified per adapter/run, with recorded SQLite version, library path, compile options, and encryption variant.
- Sync-vs-async is not really excluded if every method returns `Future`; the overhead of wrapping sync calls is included. Make that an explicit fairness flag.
- `forceGc()` between reps is not a normal stable Dart API. If done through VM service or debug-only hooks, report when it was unavailable.
- Raw SQL deliberately excludes drift's typed DSL and reactive query strengths. The report should warn that tracelite compares SQL execution paths, not overall library quality.
- Transaction cancellation should be documented as out of scope for benchmark scenarios. Dart futures are not generally preemptively cancellable.
- Standard scenario versioning should be decided now. Use `scenarioId`, `scenarioVersion`, and a stable parameter block in every trace.
- Adapter packaging should probably move to separate packages by v1.0. Pulling every peer dependency into core `tracelite` will make installation and version solving noisy.
- Embedded mode should be a first-class companion spec. Synthetic scenarios are useful, but the README's promise of "point it at any Dart program" depends on a non-scenario path.

## External checks

- `package:sqlite3` currently documents bundled SQLite via hooks and prebuilt native SQLite for many platforms: https://pub.dev/packages/sqlite3
- drift `NativeDatabase` is documented as using `dart:ffi` to access sqlite3 APIs through `package:sqlite3`: https://pub.dev/documentation/drift/latest/native/
- SQLite `sqlite3_changes()` has narrow direct-change semantics: https://www.sqlite.org/c3ref/changes.html
- Dart isolate messages can have linear copy cost, relevant for concurrent-read scenarios that move large result sets between isolates: https://api.dart.dev/dart-isolate/SendPort/send.html

## Suggested next edits

1. Rewrite the scenario lifecycle as two explicit state machines.
2. Replace map-only rows or remove by-index claims.
3. Replace `Future<int> execute` with `ExecutionResult` or narrow its allowed SQL.
4. Expand `PeerCapabilities` and make scenario requirements mandatory.
5. Add an embedded-mode spec and record SQLite engine identity in every run.
