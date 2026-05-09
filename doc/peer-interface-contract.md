# tracelite — Peer Interface Contract

**Status:** Draft v0.1
**Companion to:** `format-spec.md`, `aggregator-api.md`, `runtime-protocol.md`
**Audience:** Design review for the cross-library SQLite tracing package

The package's most distinctive capability is **comparing peer SQLite libraries on identical workloads**. This requires three things:

1. A **scenario** — a workload spec, library-agnostic.
2. An **interface** — a small abstract API every peer library implements.
3. An **adapter** per peer library — translates the interface into that library's native API.

This doc defines all three. It also defines the rules that keep comparisons fair: what's measured, what's excluded, how warmup and repetition work.

The contract has to satisfy six properties:

| Property | Why |
|---|---|
| **Library-neutral surface** | The interface API has to be implementable by drift, sqlite_async, sqlite3, Resqlite, and any plausible future library — without favoring any of them. |
| **Comparable wall** | Two libraries running the same scenario must spend wall in comparable phases. The scenario contract excludes setup wall from the comparison window. |
| **Reproducible** | Same machine, same library version, same scenario → same trace within noise. Determinism in the workload (no randomness without explicit seeding). |
| **Extensible** | Adding a new peer (e.g., a new Dart SQLite library) is a matter of writing a single adapter file. |
| **No reactive bias** | Resqlite has reactive streams; drift has watchers; sqlite_async has neither. The interface excludes reactive features so the comparison is on shared SQL execution paths. |
| **Honest about what it doesn't measure** | If a feature isn't in the interface, it isn't in the comparison. Differences in reactivity, encryption, type system, or developer ergonomics aren't visible in tracelite output. |

## Outline

1. [Scope and non-goals](#1-scope-and-non-goals)
2. [The interface API](#2-the-interface-api)
3. [The scenario contract](#3-the-scenario-contract)
4. [Standard scenarios](#4-standard-scenarios)
5. [Peer adapters](#5-peer-adapters)
6. [Fairness rules](#6-fairness-rules)
7. [Adding a new peer](#7-adding-a-new-peer)
8. [Adding a new scenario](#8-adding-a-new-scenario)
9. [What's not in the interface](#9-whats-not-in-the-interface)
10. [Worked examples](#10-worked-examples)

---

## 1. Scope and non-goals

### In scope

The interface covers operations every Dart SQLite library implements:

- Open / close a database
- Execute a SQL statement with bound parameters (no result set)
- Execute a SQL statement with bound parameters (returning a result set)
- Bulk-execute a single SQL with many parameter sets (batch inserts)
- Run a transaction (begin / body / commit / rollback)
- Read result columns by name and index

### Explicitly out of scope

- **Reactive features.** `db.stream()` (Resqlite), `db.watch()` (drift), or change notifications. Some libraries have them; some don't; comparing wall time of "a stream that emits N rows" across libraries with different reactive models is apples-to-oranges.
- **Type-safe DSLs.** drift compiles type-safe Dart queries to SQL; sqlite_async takes raw SQL. Comparing "drift's query DSL" against "sqlite_async's raw SQL" measures DSL overhead, not SQL performance. The interface uses raw SQL strings for comparability.
- **Schema migration / management.** Each library has different opinions on schema versioning. Out of scope.
- **Encryption.** Resqlite supports sqlite3mc; drift supports cipher; sqlite3 has SEE if you license it. The shim handles the underlying SQLite layer; encrypted-vs-not is a separate axis from peer comparison.
- **Connection pooling, isolate models.** Each library has different concurrency stories. The interface measures *one* logical execution thread; pooling/isolate-side gains are visible in the trace's track structure, but the interface doesn't prescribe them.
- **Library-specific extensions.** drift's joins, Resqlite's column-level dependency tracking. Use the user-span API to instrument these privately; don't expose them in the cross-library interface.

### Why this scope

The scope is the intersection of what every peer library exposes. It's deliberately narrow. Wider would force libraries to "implement" features they don't have natively, distorting the comparison. Narrower would miss too much real-world workload.

The result is that tracelite measures **how each library executes the SQL**, not **how each library exposes APIs to users**. That's the right axis: API ergonomics is a separate quality dimension, not measurable by a tracing system.

## 2. The interface API

```dart
abstract class SqliteInterface {
  /// Library-friendly name (e.g. "drift", "sqlite_async", "resqlite", "sqlite3").
  /// Used as the track-name suffix for Dart-side spans, and in scenario reports.
  String get name;

  /// Library version (read from package metadata).
  String get version;

  /// Open a database at [path], or `:memory:` for an in-memory database.
  /// Adapters do whatever setup their library requires (spawning isolates,
  /// opening connections, etc.) before the scenario's stopwatch starts.
  Future<void> open(String path);

  /// Close the database and release all resources.
  Future<void> close();

  /// Execute a SQL statement with optional bound parameters. Returns
  /// an [ExecutionResult] describing what happened.
  ///
  /// Allowed for: INSERT, UPDATE, DELETE, DDL, PRAGMA, and statements
  /// with RETURNING. Different statement kinds populate different
  /// fields of the result; see [ExecutionResult.statementKind].
  Future<ExecutionResult> execute(
    String sql,
    [List<Object?> params = const []],
  );

  /// Execute a SELECT and return its rows. Returns [SqliteRow]s, which
  /// preserve stable column order and support both name and index access.
  Future<List<SqliteRow>> select(
    String sql,
    [List<Object?> params = const []],
  );

  /// Execute one SQL statement with many parameter sets.
  ///
  /// **Atomicity:** the harness wraps this call in a transaction unless
  /// the adapter declares `nativeBatchingMode: native` (in which case
  /// the adapter is responsible for atomic execution itself). All peers
  /// see all-or-nothing semantics: if any row fails, the entire batch
  /// is rolled back and the error is rethrown.
  ///
  /// Adapters MAY map this to library-native batching (drift's `batch`,
  /// Resqlite's `executeBatch`). Adapters without batching support
  /// declare `nativeBatchingMode: txWrappedLoop`, in which case the
  /// adapter implements the loop itself; the report flags this as a
  /// fairness note.
  Future<void> executeBatch(String sql, List<List<Object?>> paramSets);

  /// Run [body] in a transaction. The body receives a [SqliteInterface]
  /// scoped to the transaction. Calls on the inner interface MUST see
  /// writes from earlier statements in the same transaction
  /// (read-after-write within-tx; check `capabilities.transactionVisibility`).
  ///
  /// On body throw, the transaction rolls back and the error rethrows.
  /// On normal return, the transaction commits.
  ///
  /// Cancellation: Dart futures are not generally preemptively
  /// cancellable. Scenarios MUST NOT rely on cancelling a tx-body's
  /// future to abort the transaction; only thrown exceptions trigger
  /// rollback. This is documented as out-of-scope for benchmarks.
  Future<T> transaction<T>(Future<T> Function(SqliteInterface tx) body);

  /// Required: report capabilities for fairness flags. Adapters MUST
  /// override this with honest values. Inaccurate capability flags
  /// invalidate the comparison.
  PeerCapabilities get capabilities;
}

/// A single row returned from a SELECT.
abstract class SqliteRow {
  /// Read by column name. Returns null for unknown columns AND for SQL
  /// NULL values; check `containsKey` to distinguish.
  Object? operator [](String column);

  /// Read by column index. Stable across rows in the same result set.
  Object? at(int index);

  /// Number of columns.
  int get length;

  /// Column names, in result-set order.
  List<String> get columnNames;

  /// True if [column] is one of the result-set's columns. Distinguishes
  /// "SQL NULL" from "no such column".
  bool containsKey(String column);

  /// Materialize as a Map. Loses column order if the result has duplicate
  /// column names; in that case [at]/[columnNames] are the safer access.
  Map<String, Object?> asMap();
}

/// What an [SqliteInterface.execute] call did.
class ExecutionResult {
  const ExecutionResult({
    required this.statementKind,
    required this.directChanges,
    required this.lastInsertRowId,
    required this.returnedRows,
  });

  /// What kind of statement this was — affects which fields are meaningful.
  final SqlStatementKind statementKind;

  /// Number of rows directly modified by INSERT/UPDATE/DELETE.
  /// Excludes auxiliary trigger / FK / REPLACE effects (matches
  /// SQLite's `sqlite3_changes()` semantics).
  /// Zero for DDL, PRAGMA, and SELECT.
  final int directChanges;

  /// Rowid of the last successful INSERT against this connection's
  /// most recent INSERT statement. Zero / undefined for non-INSERT.
  final int lastInsertRowId;

  /// Rows returned by RETURNING clauses. Empty for non-RETURNING.
  final List<SqliteRow> returnedRows;
}

enum SqlStatementKind {
  insert, update, delete, ddl, pragma, returning, other,
}

class PeerCapabilities {
  const PeerCapabilities({
    required this.batchingMode,
    required this.transactionVisibility,
    required this.isolateBoundary,
    required this.syncUnderneath,
    this.nativeNamedParameters = false,
    this.supportsConcurrentReads = false,
    this.supportsInMemory = true,
    this.supportsReturning = true,
  });

  /// How the adapter implements `executeBatch`.
  final BatchingMode batchingMode;

  /// Whether the library supports `:name` parameters natively.
  final bool nativeNamedParameters;

  /// Whether reads inside a transaction see writes from earlier in the
  /// same transaction.
  final TransactionVisibility transactionVisibility;

  /// Whether the library executes work on a separate isolate. Affects
  /// causal-chain interpretation in the generated report.
  final bool isolateBoundary;

  /// Whether the library's underlying SQLite call is synchronous (the
  /// adapter wraps it in `Future.value`). Sync-underneath libraries
  /// have lower per-call overhead but block the calling isolate.
  final bool syncUnderneath;

  /// Whether the library supports concurrent reads from the same DB.
  final bool supportsConcurrentReads;

  /// Whether the library supports the `:memory:` path.
  final bool supportsInMemory;

  /// Whether the library handles INSERT...RETURNING / UPDATE...RETURNING.
  final bool supportsReturning;
}

enum BatchingMode {
  /// Adapter implements `executeBatch` natively — the library has its
  /// own batch API that it dispatches once across whatever isolate
  /// boundary it has.
  native,

  /// Adapter falls back to a `transaction` wrapper around per-row
  /// `execute` calls. Functionally correct, but per-row dispatch cost.
  /// Flagged as a fairness note in the report.
  txWrappedLoop,

  /// Adapter has no transactional batching; runs in autocommit. Slowest;
  /// some peers may not support this at all.
  perRowAutocommit,
}

enum TransactionVisibility { readAfterWrite, snapshot, undefined }
```

That's the entire surface. ~100 LOC of Dart, no library-specific concepts.

### Result row representation

`select` returns `List<Map<String, Object?>>` — same shape as Resqlite's `select`. Values are SQLite-native types: `int`, `double`, `String`, `Uint8List` (BLOB), or `null`.

Every adapter normalizes its native row representation into this shape. drift's typed query results are converted; sqlite3's `Row` becomes a Map; Resqlite already produces this. The conversion cost is included in the wall — adapters that produce a native shape with less conversion are appropriately faster, which is fair signal.

### Error handling

All operations are `async` and may throw. The exception type is library-specific (drift's `DriftException`, Resqlite's `ResqliteException`, etc.); scenarios catch broadly and report as scenario failure rather than dispatching by type.

### Versioning

The interface itself is versioned via the package's semantic version. Breaking changes to the interface bump the major version of `tracelite` and require all adapters to be updated.

## 3. The scenario contract

A scenario is a self-contained workload that runs against any `SqliteInterface`. Two phases are distinguished:

1. **Setup** — schema creation, seed data insertion, warmup. Wall during setup is **excluded** from the comparison window.
2. **Workload** — the actual measured phase. tracelite emits `_trace_start` at the beginning and `_trace_end` at the end. All cross-library comparisons run against this window.

```dart
abstract class Scenario {
  /// Stable identifier (also used as the trace artifact filename).
  /// Use kebab-case: 'narrow-batch-insert', 'wide-row-streaming', etc.
  String get name;

  /// Bumped when the scenario's workload semantics change. Reports
  /// distinguish `narrow-batch-insert@v1` from `narrow-batch-insert@v2`.
  int get version;

  /// Human-readable one-liner describing what the scenario tests.
  String get description;

  /// Required peer capabilities. The harness fails fast (with a clear
  /// message) when a peer's `PeerCapabilities` doesn't satisfy these.
  /// Scenarios that need all capabilities can return an empty set.
  Set<RequiredCapability> get required;

  /// Per-DB lifecycle mode. See `LifecycleMode`. Defaults to `freshPerRep`.
  LifecycleMode get lifecycle => LifecycleMode.freshPerRep;

  /// Setup phase. NOT included in measurement window. Schema creation,
  /// seed data insertion, anything that should not perturb measurements.
  /// Called per the lifecycle (see below).
  Future<void> setup(SqliteInterface db);

  /// The measured workload. Wall during this method is what's compared
  /// across peers. tracelite emits trace-start before this is called and
  /// trace-end after it returns.
  Future<void> run(SqliteInterface db);

  /// Teardown phase. NOT included in measurement window. Default: no-op.
  Future<void> teardown(SqliteInterface db) async {}

  /// Default repetitions for measurement (excluding warmup).
  int get repetitions => 5;

  /// Default warmup repetitions; their traces are discarded.
  int get warmupRepetitions => 2;
}

enum RequiredCapability {
  transactions,
  batching,
  concurrentReads,
  inMemory,
  returning,
  isolateSafe,
}

enum LifecycleMode {
  /// Each repetition gets a brand-new database. Default. Strongest
  /// independence across repetitions.
  freshPerRep,

  /// All repetitions share one DB created at scenario start. Cheaper,
  /// but reps are no longer independent — second-run cache state is
  /// different from first-run. Use only when the scenario is testing
  /// steady-state behavior, not cold-start.
  sharedAcrossReps,
}
```

### Scenario lifecycle (state machines)

The lifecycle is two explicit state machines, one per `LifecycleMode`. Both expose the same fundamental phases (open, setup, warmup, measured, teardown, close) but differ in what's repeated and what's torn down between reps.

#### `LifecycleMode.freshPerRep` (default, strongest independence)

```
loop for each (warmup + measured) repetition:
  open(temp_db_path)
    setup(db)
    [warmup-only or measured]
      if measured:  emit _trace_start
      run(db)
      if measured:  emit _trace_end
    teardown(db)
  close()
  unlink(temp_db_path)
```

Each repetition is fully independent: fresh files, fresh page cache (from the OS perspective; the OS may still cache the schema bytes, but the SQLite page cache is empty). This is the default because cross-rep variance is purely workload-driven, not carryover-driven. Significance testing over reps (the diff API's `unit: repetition`) is statistically clean.

The cost is more I/O — every rep creates and destroys a DB. Acceptable for audit-style runs; not viable for very long workloads.

#### `LifecycleMode.sharedAcrossReps` (steady-state)

```
open(persistent_db_path)
  setup(db)                   ← runs ONCE; idempotent or overwrites
  loop warmupRepetitions:
    run(db)
  loop measuredRepetitions:
    emit _trace_start
    run(db)
    emit _trace_end
  teardown(db)
close()
unlink(persistent_db_path)
```

Setup runs once; warmup and measured repetitions all execute against the *same* DB. SQLite caches, prepared-statement caches, and any library-level state carry forward across reps. Use this mode when the scenario is testing *steady-state* behavior (e.g., "what does ongoing chat-app traffic look like after the cache is warm?"); don't use it for cold-start measurements.

Independence across reps is weaker because cache state, fragmented free space, etc., compound. Diff with `unit: repetition` is still defensible but has lower power.

#### What's required of `setup()` in shared mode

Setup is called once, before any rep. If `run()` mutates the DB (most do), setup MUST either:

- Be **idempotent** (re-runnable without changing the DB's observable state). For example, `CREATE TABLE IF NOT EXISTS` + `INSERT OR REPLACE`.
- Or be designed alongside `run()` so the DB's mutations don't affect subsequent reps' fairness — e.g., the workload only reads.

If setup is not idempotent and `run()` mutates state, **use `freshPerRep`**. The harness has no way to reset to a snapshot between reps in shared mode.

Wall outside `_trace_start`/`_trace_end` is recorded but flagged as setup/teardown. Reports separate setup wall from workload wall.

### Determinism

Scenarios should be deterministic given a seeded RNG. The base class provides a seeded `math.Random`:

```dart
abstract class Scenario {
  /// Seeded RNG. Same seed across runs → same workload sequence.
  /// Override to use a custom seed if needed.
  math.Random get rng => math.Random(scenarioSeed);
  static const int scenarioSeed = 0xBEEF;
}
```

Random walks (e.g., key-PK miss-path) use this RNG, not `DateTime.now()`-derived seeds. Two runs of the same scenario produce identical workloads.

## 4. Standard scenarios

The package ships an initial library of scenarios covering common SQLite usage patterns. These are the apples-to-apples comparison points.

### Read-heavy

| Scenario name | What it does | Why it matters |
|---|---|---|
| `point-query` | 10K random PK lookups against a 100K-row table | Tests prepare-cache effectiveness, FFI overhead, row-decode cost |
| `range-scan-narrow` | 1K range scans returning ~10 rows each from a narrow (3-col) table | Tests row materialization for small results |
| `range-scan-wide` | 1K range scans returning ~10 rows each from a wide (20-col) table | Tests column-decode cost as schema width grows |
| `large-result` | 10 queries returning 10K rows each | Tests bulk-read throughput, result-set transfer cost |
| `text-heavy` | 1K queries returning rows with ~1KB TEXT columns | Tests UTF-8 decode and string allocation |
| `blob-heavy` | 1K queries returning rows with ~10KB BLOB columns | Tests blob copy-out cost |
| `concurrent-reads` | 4 concurrent isolates each running 1K point queries | Tests reader-pool concurrency models |

### Write-heavy

| Scenario name | What it does | Why it matters |
|---|---|---|
| `single-inserts` | 1K sequential single-row inserts in autocommit mode | Tests per-statement overhead, autocommit transaction cost |
| `narrow-batch-insert` | 1 batch of 10K rows × 2 columns | Tests bulk-insert throughput, prepare-cache, batch-API efficiency |
| `wide-batch-insert` | 1 batch of 10K rows × 20 mixed-type columns | Tests parameter-binding cost as parameter count grows |
| `tx-mixed` | Transaction with 100 inserts + 50 selects + 25 updates | Tests cross-statement transaction cost, read-after-write visibility |
| `large-tx` | Transaction with 100K inserts (no batching) | Tests transaction journaling overhead |

### Schema / lifecycle

| Scenario name | What it does | Why it matters |
|---|---|---|
| `connect-close` | 100 open / close cycles on a fresh db | Tests connection setup overhead |
| `prepare-only` | 1K prepare/finalize cycles for distinct SQLs | Tests SQL-compilation cost |

### Realistic-mix

| Scenario name | What it does | Why it matters |
|---|---|---|
| `feed-paging` | Simulate a social-feed pager: 100 paged reads + 20 inserts + 50 updates | Tests realistic read-write mix |
| `chat-sim` | Simulate a chat: 1K interleaved inserts + per-conversation queries | Tests read-write interleaving with locality |
| `keyed-pk-lookups` | 1K lookups by random PKs from a deterministic distribution | Tests primary-key index path |

### Optional capability lanes

These are standard tracelite scenarios, but they are not part of the narrow
common SQL contract. Peers that do not expose the required capability are
reported as `unsupported` instead of being forced through a distorted fallback.

| Scenario name | Required capability | What it does | Why it matters |
|---|---|---|---|
| `keyed-pk-subscriptions` | `reactive` | Many streams watch individual primary-key rows while random updates land | Tests precise invalidation for common row-detail screens |
| `high-cardinality-fanout` | `reactive` | Many partitioned streams watch indexed owner buckets while random updates fan out | Tests watcher cardinality and dependency-intersection cost |
| `many-streams-writer-throughput` | `reactive` | Measures writer throughput with many active streams and both disjoint and overlapping column updates | Tests whether reactive bookkeeping slows unrelated writes |
| `sqlite-diagnostics` | `diagnostics` | Imports SQLite/resqlite diagnostic snapshots as gauges | Tests whether semantic memory/WAL/stream facts can live in the shared trace artifact |

Each scenario is a Dart class in `scenarios/` implementing the `Scenario` interface. Standard library has ~15 scenarios at v1.0; users add custom scenarios for their own workloads.

## 5. Peer adapters

Each adapter is a single Dart file, typically <200 LOC, that implements `SqliteInterface` against a peer library's native API. The adapter is the only library-specific code in the entire comparison.

The sketches below are illustrative — they show the shape but elide the `ExecutionResult` / `SqliteRow` plumbing for brevity. A real adapter must construct an `ExecutionResult` from each `execute` call (capturing `directChanges`, `lastInsertRowId`, any RETURNING rows, and the inferred `statementKind`) and wrap each query result row in an `SqliteRow` implementation that preserves column order.

### drift adapter sketch

```dart
class DriftInterface implements SqliteInterface {
  @override
  String get name => 'drift';

  @override
  String get version => '<read from pubspec>';

  late final QueryExecutor _executor;
  late final GenericDatabase _db;

  @override
  Future<void> open(String path) async {
    _executor = NativeDatabase(File(path));
    _db = GenericDatabase(_executor);
  }

  @override
  Future<int> execute(String sql, [params = const []]) {
    return _db.customStatement(sql, params);
  }

  @override
  Future<List<Map<String, Object?>>> select(String sql, [params = const []]) async {
    final result = await _db.customSelect(sql, variables: params.map(Variable.new).toList()).get();
    return result.map((row) => row.data).toList();
  }

  @override
  Future<void> executeBatch(String sql, List<List<Object?>> paramSets) async {
    await _db.batch((batch) {
      for (final params in paramSets) {
        batch.customStatement(sql, params);
      }
    });
  }

  @override
  Future<T> transaction<T>(Future<T> Function(SqliteInterface tx) body) {
    return _db.transaction(() => body(this));
  }

  @override
  Future<void> close() => _db.close();

  @override
  PeerCapabilities get capabilities => const PeerCapabilities(
    batchingMode: BatchingMode.native,
    transactionVisibility: TransactionVisibility.readAfterWrite,
    isolateBoundary: false,
    syncUnderneath: true,  // drift's NativeDatabase wraps sync sqlite3 calls
  );
}
```

### sqlite_async adapter sketch

```dart
class SqliteAsyncInterface implements SqliteInterface {
  @override String get name => 'sqlite_async';
  late final SqliteDatabase _db;

  @override Future<void> open(String path) async {
    _db = SqliteDatabase(path: path);
  }

  @override Future<int> execute(String sql, [params = const []]) =>
      _db.execute(sql, params).then((r) => r.affectedRows ?? 0);

  @override Future<List<Map<String, Object?>>> select(String sql, [params = const []]) =>
      _db.getAll(sql, params);

  @override Future<void> executeBatch(String sql, List<List<Object?>> paramSets) =>
      _db.writeTransaction((tx) async {
        for (final params in paramSets) {
          await tx.execute(sql, params);
        }
      });
  // ... etc.

  @override PeerCapabilities get capabilities => const PeerCapabilities(
    batchingMode: BatchingMode.txWrappedLoop,  // we wrap a tx around per-row execute
    transactionVisibility: TransactionVisibility.readAfterWrite,
    isolateBoundary: true,
    syncUnderneath: false,
  );
}
```

### Resqlite adapter

Trivial — Resqlite's API is already very close to the interface:

```dart
class ResqliteInterface implements SqliteInterface {
  @override String get name => 'resqlite';
  late final Database _db;

  @override Future<void> open(String path) async => _db = await Database.open(path);
  @override Future<int> execute(String sql, [p = const []]) async =>
      (await _db.execute(sql, p)).affectedRows;
  @override Future<List<Map<String, Object?>>> select(String sql, [p = const []]) =>
      _db.select(sql, p);
  @override Future<void> executeBatch(String sql, List<List<Object?>> ps) =>
      _db.executeBatch(sql, ps);
  @override Future<T> transaction<T>(Future<T> Function(SqliteInterface tx) body) =>
      _db.transaction((tx) => body(_TxAdapter(tx, this)));
  @override Future<void> close() => _db.close();

  @override PeerCapabilities get capabilities => const PeerCapabilities(
    batchingMode: BatchingMode.native,
    transactionVisibility: TransactionVisibility.readAfterWrite,
    isolateBoundary: true,
    syncUnderneath: false,
    supportsConcurrentReads: true,
  );
}
```

### sqlite3 adapter

Direct binding; lowest overhead:

```dart
class Sqlite3Interface implements SqliteInterface {
  @override String get name => 'sqlite3';
  late final Database _db;

  @override Future<void> open(String path) async => _db = sqlite3.open(path);
  @override Future<int> execute(String sql, [p = const []]) async {
    _db.execute(sql, p);
    return _db.updatedRows;
  }
  @override Future<List<Map<String, Object?>>> select(String sql, [p = const []]) async {
    final rs = _db.select(sql, p);
    return rs.map((row) => Map<String, Object?>.from(row)).toList();
  }
  // ...
}
```

### Adapter authoring guidelines

1. **Use the peer library's most idiomatic path.** If drift has a "compiled query" mode that's faster than `customStatement`, the adapter uses it (and reports `nativeBatching: true`).
2. **Don't add caching the library doesn't natively do.** The point is to measure the library, not a tracelite-decorated version.
3. **Don't add timing or instrumentation.** The C shim instruments the C side; the adapter just delegates. Adapters should be ~boring.
4. **Report capabilities honestly.** A library without batching gets `nativeBatching: false` and the report shows the fairness flag.

## 6. Fairness rules

### What's measured

Wall time inside `Scenario.run()`, between `_trace_start` and `_trace_end` events. This is what the report compares.

### What's excluded

- Adapter `open()` and `close()`.
- Scenario `setup()` and `teardown()`.
- Warmup repetitions (their traces are discarded).
- Garbage collection that happens between repetitions (forced via `forceGc()` between reps to prevent carryover).

### Repetition and aggregation

Default: 2 warmup runs, 5 measured runs. The report shows:

- Per-rep wall and per-rep counter values
- Median across reps for headline numbers
- Min/max for noise visibility
- Standard deviation for variability flag

### Fairness flags in the report

When a peer's capabilities limit the comparison, the report annotates:

```
narrow-batch-insert (10000 rows × 2 params):

| peer          | median wall | nativeBatching | notes                  |
|---------------|------------:|----------------|------------------------|
| resqlite      | 12.4ms      | yes            |                        |
| drift         | 18.7ms      | yes            |                        |
| sqlite_async  | 41.2ms      | NO             | tx-wrapped fallback    |
| sqlite3       | 9.8ms       | yes            | sync API; no isolate   |
```

Readers see what they're comparing. "sqlite_async is 3x slower" is contextualized: it doesn't have a native batch API, so it's running the slow fallback. Comparing the two means comparing "drift's batch" vs "sqlite_async's transaction-wrapped loop" — both are valid implementations, but the fairness flag tells you that.

For optional capability lanes, the harness should prefer `unsupported` over a
fallback that changes the feature being measured. For example, the current
raw-SQL drift adapter does not implement the reactive lane because drift's
stream semantics depend on generated/table-registry-aware queries; pretending a
raw `NativeDatabase` watch is equivalent would make the benchmark misleading.

### Fixed-version requirement

A report's metadata includes the version of every peer:

```
peers:
  resqlite: 0.3.1
  drift: 2.21.0
  sqlite_async: 0.10.5
  sqlite3: 2.4.6
```

Comparisons across different machine configs or different library versions are explicitly tagged. The diff tool refuses to compare two runs with different peer versions unless `--allow-version-mismatch` is passed.

## 7. Adding a new peer

Steps:

1. Create `interfaces/<peer>.dart` implementing `SqliteInterface`.
2. Add a `PeerCapabilities` declaration with honest flags.
3. Add the package as an optional dev_dependency in `pubspec.yaml` (under a separate dev-dep group so users who don't run the new peer don't pay the install cost).
4. Add an entry to the registry of known peers (`lib/src/peer_registry.dart`).
5. Run the standard scenarios against the new peer; verify all of them complete without errors. Report any scenarios that fail (some are not implementable on every peer; that's fine, they get reported as N/A).
6. Submit the adapter PR. Adapter PRs are mechanical and small (<200 LOC); review focuses on capability flags and idiomatic-API use.

## 8. Adding a new scenario

Scenarios live under `scenarios/`. Each is a Dart class extending `Scenario`. Author guidelines:

1. **Setup is free; run is measured.** Heavy setup is OK; the warmup loop pays for it. Iteration cost in `run()` matters.
2. **Be deterministic.** Use the seeded RNG. No `DateTime.now()`, no random UUIDs without seeds.
3. **Match a real-world pattern.** Synthetic micro-benchmarks have their place but the standard scenarios should reflect actual app usage. "100 sequential inserts" is more useful than "1 INSERT then 99 NOPs".
4. **Document why the scenario matters.** What does it test? What architectural difference would change its result?
5. **Keep run-wall under 30 seconds per repetition** so 5×repetitions × N peers fits in a reasonable CI window.

The base library scenarios (§4) cover the common cases. Domain-specific scenarios (e.g., a financial-app's transaction pattern, a chat app's read-write mix) live in user code, not the package; the `Scenario` base class is the integration point.

## 9. What's not in the interface

This list is normative — these features are excluded from the cross-library comparison and the interface contract.

| Feature | Why excluded |
|---|---|
| Reactive queries (streams, watchers, observers) | Excluded from the common SQL interface because each library has a different model. They may appear in an optional `reactive` capability lane with explicit unsupported peers. |
| Type-safe DSLs (drift's typed queries, custom ORMs) | Compares DSL overhead, not SQL execution. The interface uses raw SQL. |
| Migrations / schema versioning | Each library has different opinions; out of scope. |
| Connection pooling, isolate models | Visible in trace structure (track count, async spans across tracks); not prescribed by the interface. |
| Encryption / cipher | Separate axis. Tracelite's C shim wraps both sqlite3 and sqlite3mc; encrypted-vs-not is a flag, not a peer choice. |
| Sync (vs async) APIs | All interface methods are `Future`-returning. Synchronous libraries (`sqlite3`) wrap their calls in `Future.value`; the wrapping cost is small but real and is part of the comparison. |
| User-defined functions / collations | Each library has different APIs. Out of scope. |
| Backup / VACUUM / database utilities | Out of scope. |

If you want to compare libraries on one of these dimensions, do it outside tracelite. tracelite measures what's tractable to measure fairly.

## 10. Worked examples

### Running one peer against one scenario

```bash
tracelite run \
  --interface=resqlite \
  --scenario=narrow-batch-insert \
  --output=resqlite-narrow-batch.tlt
```

Produces a single `.tlt` file with all events from the run.

### Comparing four peers

```bash
tracelite compare \
  --scenario=narrow-batch-insert \
  --interfaces=resqlite,drift,sqlite_async,sqlite3 \
  --output-dir=results/narrow-batch/
```

Runs the scenario 5 times against each peer (with warmup), produces 4 `.tlt` files, generates a comparison markdown.

### Sample report

```markdown
# narrow-batch-insert

10000 rows × 2 params (INTEGER, TEXT). Single batch call inside autocommit.

## Headline

| peer         | median   | min      | max      | p99      | nativeBatching |
|--------------|---------:|---------:|---------:|---------:|----------------|
| resqlite     | 12.4ms   | 12.1ms   | 13.2ms   | 13.0ms   | yes            |
| drift        | 18.7ms   | 18.2ms   | 19.4ms   | 19.2ms   | yes            |
| sqlite_async | 41.2ms   | 40.1ms   | 43.8ms   | 43.0ms   | NO (fallback)  |
| sqlite3      | 9.8ms    | 9.5ms    | 10.4ms   | 10.2ms   | yes            |

## SQLite C-call breakdown (median run)

| C function           | resqlite | drift  | sqlite_async | sqlite3 |
|----------------------|---------:|-------:|-------------:|--------:|
| sqlite3_prepare_v3   | 1×       | 1×     | 1×           | 1×      |
| sqlite3_bind_int     | 10000×   | 10000× | 10000×       | 10000×  |
| sqlite3_bind_text    | 10000×   | 10000× | 10000×       | 10000×  |
| sqlite3_step         | 10000×   | 10000× | 10000×       | 10000×  |
| sqlite3_reset        | 9999×    | 9999×  | 9999×        | 9999×   |
| sqlite3_finalize     | 1×       | 1×     | 1×           | 1×      |

(All peers issue the same SQLite call sequence; the wall difference is in
Dart-side dispatch, FFI marshalling, isolate boundaries, and result handling.)

## Per-call wall (median, µs)

| C function           | resqlite | drift  | sqlite_async | sqlite3 |
|----------------------|---------:|-------:|-------------:|--------:|
| sqlite3_step (avg)   | 0.78µs   | 0.92µs | 1.15µs       | 0.71µs  |
| sqlite3_bind_text    | 0.31µs   | 0.41µs | 0.67µs       | 0.28µs  |
| sqlite3_bind_int     | 0.18µs   | 0.22µs | 0.29µs       | 0.15µs  |

## Dart-side wall (median, ms)

| phase                     | resqlite | drift  | sqlite_async | sqlite3 |
|---------------------------|---------:|-------:|-------------:|--------:|
| Total Dart-side wall      | 4.6ms    | 9.1ms  | 28.4ms       | 1.2ms   |
| Param marshalling         | 1.8ms    | 3.2ms  | 6.1ms        | 0.4ms   |
| Result decoding (n/a)     | —        | —      | —            | —       |
| Isolate dispatch          | 1.2ms    | 0ms    | 14.8ms       | 0ms     |
| Other                     | 1.6ms    | 5.9ms  | 7.5ms        | 0.8ms   |

## Notes

- sqlite_async runs in tx-fallback mode (no native batch); 14.8ms of its wall
  is isolate dispatch overhead from the per-statement crossing.
- sqlite3 has no isolate boundary; this lowers wall but means SQLite blocks
  the main thread.
- resqlite's batch path is dispatched once across the isolate boundary;
  marshalling cost is amortized across rows.
```

The report shows wall *and* the architectural reasons for it. Readers can decide whether `sqlite3`'s 9.8ms (with main-thread blocking) is a better trade than `resqlite`'s 12.4ms (off-main-thread) for their use case — that's a values judgment, not a benchmark winner.

## Open questions

1. **Read-after-write inside transactions.** Some peers don't expose this (or don't expose it the same way). Should `transaction(body)` give the body a `SqliteInterface` that's the same as the outer one, or a new one scoped to the tx? The example sketches above pass `this`, which works for most peers but elides a meaningful semantic distinction.

2. **Async transaction body cancellation.** If the body throws, we roll back. If the body's Future is cancelled (which is rare in Dart but possible), what happens? Not all peers handle this consistently. Probably document as undefined and have scenarios avoid cancellation.

3. **Per-peer scenario opt-out.** Some scenarios are unsuitable for some peers (e.g., a sync-only peer can't do "concurrent reads"). Should the scenario declare which peer capabilities it requires, or should we accept silent N/A entries in the comparison table? Probably the former.

4. **Adapter package boundaries.** Should each adapter be its own pub.dev package (`tracelite_drift`, `tracelite_sqlite_async`) so users only install what they need? Or all in `tracelite` as optional imports with conditional loading? The latter is simpler for v0.1; the former is right for v1.0+.

5. **Standard scenario versioning.** Once `narrow-batch-insert v1` is published, can it ever change? Realistic answer: scenario evolution is fine if the reported numbers from v1 and v2 are clearly distinguished. Probably name them `narrow-batch-insert@v1`, `narrow-batch-insert@v2`, etc., and reports surface the version.

6. **Running on real apps.** Some users will want to run tracelite against their actual app's SQLite usage, not synthetic scenarios. Need a "scenario from existing code" path: just load the C shim, run the app, drain the trace. The peer interface contract doesn't apply (the app uses its peer library directly), but the trace is still valid. Probably worth a separate "embedded mode" doc.
