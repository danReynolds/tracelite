# tracelite — Span ID Registry

**Status:** Draft v0.2
**Companion to:** `format-spec.md`, `runtime-protocol.md`
**Audience:** Design review for the cross-library SQLite tracing package

The format spec reserves 16-bit span IDs across four ranges. This doc defines the *rules* for those ranges (allocation, stability, naming) and points at the **single source of truth** for span definitions: [`tools/spans.yaml`](../tools/spans.yaml).

## What's where

| Artifact | Maintained how |
|---|---|
| **`tools/spans.yaml`** | **Hand-authored. The source of truth.** |
| `tools/generate.dart` | Hand-authored. The generator that reads `spans.yaml`. |
| `lib/src/builtin_spans.g.dart` | Generated. Dart constants. |
| `native/builtin_spans.g.h` | Generated. C `#define`s. |
| `doc/format-spec.appendix.md` | Generated. Compact ID table. |
| `doc/span-registry.generated.md` | Generated. Full per-category schemas with arg lists. |

CI runs `dart run tools/generate.dart --check`. If any generated file is out of date relative to `spans.yaml`, CI fails. This means span IDs, names, and arg schemas cannot drift across docs and code — they all derive from one file.

## 1. ID space allocation

| Range | Owner | Allocation policy |
|---|---|---|
| `0x0000`–`0x0FFF` | tracelite built-ins | Reserved; assigned by tracelite maintainers only |
| `0x1000`–`0x1FFF` | SQLite C API | One ID per public SQLite C function we wrap |
| `0x2000`–`0x2FFF` | Dart recorder built-ins | Dart-side runtime events (GC, isolate lifecycle, etc.) |
| `0x3000`–`0x3FFF` | FFI bridge | Events at the Dart↔C boundary |
| `0x4000`–`0xFFFF` | User-defined | Library authors and end users register here at runtime |

The 64K span-ID space is comfortably larger than needed; reserved ranges have ~4K slots each, of which most current entries fit in <100. Headroom is for additions across the lifetime of the format.

The generator validates range membership: a span declared in `spans.yaml` with `category: sqlite_c` whose ID falls outside `0x1000..0x1FFF` is a build error.

User spans are runtime-registered: a peer library calling `Span.register('drift.query.compile', ...)` gets allocated a span ID in the user range and emits a METADATA event extending the trace's span dictionary. Two different traces from the same library may end up with different IDs for the same name; the *name* is what's stable across traces, the ID is what's stable within a single trace.

## 2. Stability rules

For built-in ranges (`0x0000`–`0x3FFF`):

| Change | Minor version | Major version |
|---|---|---|
| Add a new ID | Yes | Yes |
| Add a new arg to an existing ID's `begin_args` / `end_args` / `instant_args` | No (breaks readers expecting fixed arg count) | Yes |
| Change an arg's type | Never | Yes |
| Rename a span | No (changes user-visible identity) | Yes |
| Repurpose an ID for a different concept | Never | Never (allocate a new ID instead) |
| Remove an ID | No (use `deprecated: true` and `superseded_by` instead) | Yes |

Deprecation cycle: a removed ID gets `deprecated: true` and (optionally) `superseded_by: 0xMMMM` in `spans.yaml`. The generator emits the deprecated entry into all outputs with a deprecation note. Old traces remain readable; new producers don't emit the deprecated ID. After at least one major version, the deprecated entry can be removed.

User spans don't have these constraints — they're registered at runtime per-trace and are inherently per-trace artifacts.

### BEGIN/END/INSTANT phase model

Every built-in span declares one or more of `begin_args`, `end_args`, and `instant_args` in `spans.yaml`. The format-spec §6 defines which event tags consume which schema:

| Tag | Schema |
|---|---|
| `BEGIN` / `ASYNC_BEGIN` | `begin_args` |
| `END` / `ASYNC_END` | `end_args` |
| `INSTANT` | `instant_args` |

A span can have at most one of (`begin_args`/`end_args`) vs `instant_args`; the generator rejects `spans.yaml` entries that mix both. SQLite C calls have inputs known at BEGIN (`sql`, `stmt`, `idx`, `len`) and outputs known at END (`rc`, `stmt_out`, `blob_out`); event-only spans (drops, registrations) use `instant_args`.

## 3. Built-in span tables

**Hand-edits to the tables below would be silently overwritten on regeneration.** Read them in the generated companion file:

- [`span-registry.generated.md`](span-registry.generated.md) — full schemas per category.
- [`format-spec.appendix.md`](format-spec.appendix.md) — compact ID table.

The categories covered by the registry today:

| Category | Range | Status |
|---|---|---|
| `tracelite` (built-ins) | `0x0000`–`0x0FFF` | Stable |
| `sqlite_c` (SQLite C API) | `0x1000`–`0x1FFF` | Partial coverage. v0.1 wraps prepare/step/reset/bind/column/exec/finalize. Hooks (0x1120+), blob I/O (0x1140+), DB status (0x1150+), and friends pending. |
| `dart_recorder` | `0x2000`–`0x2FFF` | Initial set: GC events, isolate lifecycle, stack samples |
| `ffi_bridge` | `0x3000`–`0x3FFF` | Initial set: entry/exit, string marshalling |

Coverage is recorded per-trace via the `m.coverage` METADATA event (see format-spec §6.1). A trace from a producer that wraps only a subset of SQLite spans is correct; the aggregator just won't have those spans available for queries against that trace.

## 4. Hook registration vs hook invocation

SQLite hook APIs (`sqlite3_commit_hook`, `sqlite3_update_hook`, etc.) come in two semantic flavors:

1. **Registration calls** — when the host *installs* a callback. These are wrapped like any SQLite C function; spans for these go in `0x1120`–`0x113F`.
2. **Callback invocations** — when SQLite *fires* an installed callback. These are *separate spans* in `0x1200`–`0x12FF`.

These are conceptually distinct: registration is one-shot setup; invocation is the runtime signal an analyst usually wants. Putting them under the same ID would make queries like "how many commits fired?" answer-able only by inferring from `commit_hook` registration counts, which is wrong.

v0.1 ships registration spans only. Invocation spans (in `0x1200+`) are deferred to v0.2 because wrapping callbacks requires the C shim to interpose between SQLite and the host's callback function, which is a separate engineering pass from wrapping the public C API.

When invocation spans land, SQLite-documented caveats apply:

- `sqlite3_update_hook` callbacks are not invoked for WITHOUT ROWID tables, and their ordering relative to the underlying change is unspecified. (See [sqlite3_update_hook docs](https://www.sqlite.org/c3ref/update_hook.html).)
- `sqlite3_trace_v2` registers one trace callback per connection and replaces prior trace callbacks. (See [sqlite3_trace_v2 docs](https://sqlite.org/c3ref/trace_v2.html).)
- Commit / rollback hooks return the previous `pArg`, and callbacks must not modify the invoking connection. (See [commit_hook docs](https://www.sqlite.org/c3ref/commit_hook.html).)

These caveats will be encoded as notes in the relevant `spans.yaml` entries when the invocation spans are added.

## 5. User span range (0x4000–0xFFFF)

Library and application authors register user spans at runtime:

```dart
final querySpan = Span.register(
  'drift.query.compile',
  category: SpanCategory.user,
  beginArgs: [ArgSchema('sql', ArgType.stringId)],
  endArgs:   [ArgSchema('rowCount', ArgType.i64)],
);

trace.begin(querySpan, [sqlId]);
// ... compile work ...
trace.end(querySpan, [rowCount]);
```

Allocation:
- The recorder keeps a process-local registry of registered names.
- On first registration of a name, the recorder allocates a fresh ID in `0x4000`+, monotonically increasing per-trace.
- A `m.add_span` METADATA event is emitted to the trace.
- Subsequent registrations of the same name return the cached ID.

ID allocation is per-trace: two separate traces from the same library may end up with different IDs for the same name. Span *names* are the stable identity across traces. Aggregator queries that compare across traces match by name, never by ID.

There's no global "drift owns 0x4100" convention. Two libraries could pick the same name; the convention is to prefix with the library/package name (`drift.…`, `resqlite.…`, `your_app.…`).

User-span schemas use the same `begin_args` / `end_args` / `instant_args` model as built-ins, declared at registration time and serialized into the trace's span dictionary via the `m.add_span` METADATA event.

## 6. Adding a new built-in span

1. Edit [`tools/spans.yaml`](../tools/spans.yaml). Pick a free ID in the appropriate sub-range; declare `begin_args`, `end_args`, or `instant_args` per the call's reality.
2. Run `dart run tools/generate.dart`. This regenerates the four output files.
3. Commit `spans.yaml`, the generated files, and any C/Dart code that emits the new span.
4. CI's `--check` step verifies all generated files are consistent with `spans.yaml` on every PR.

Schema changes (renaming, retyping, adding required args) are breaking and require a format major version bump per §2 stability rules. Always prefer adding a new ID over mutating an existing one's schema.

## 7. Required per-trace metadata

Every trace MUST contain these METADATA events before the first non-metadata event from the corresponding subsystem:

| METADATA kind | When required | Why |
|---|---|---|
| `m.process_info` | Always | pid, executable path |
| `m.hardware_info` | Always | CPU count, page size, arch — needed to interpret per-call wall |
| `m.coverage` | Always (per producer with a partial-coverage shim) | Tells the aggregator which span IDs the shim could/couldn't wrap |
| `m.sqlite_engine` | Always (per trace involving SQLite) | SQLite library identity, version, compile options, cipher variant |
| `m.scenario_info` | Always (per scenario-driven trace) | Scenario name, version, parameter block |
| `m.peer_info` | Always (per peer-library trace) | Peer name, version, capabilities JSON |

Without these, a trace cannot be safely compared to another trace — engine versions, coverage gaps, and parameter changes silently invalidate comparisons. The aggregator's `TraceDiff.compare` refuses to run on traces lacking these metadata events unless `--allow-bare-trace` is passed.

## Open questions

1. **Wide vs narrow API coverage.** v0.1 wraps the most common SQLite calls (~40 of ~150). Should the C shim grow to wrap *every* SQLite API or stay narrow? Wide coverage future-proofs the shim; narrow keeps the binary small. Probably driven by encountered gaps in real peer benchmarks.

2. **String IDs for parameterized SQL.** When a peer library calls `prepare(sql)` repeatedly with the same SQL, the string-id arg points at the same pool entry — perfect dedup. But ORM-generated SQL is often slightly different per call (reordered WHERE clauses, etc.). Need a `sql_fingerprint_id` arg derived from a normalized form for fair grouping. Reserved as a future arg type / METADATA extension.

3. **`bind` event volume.** A 10-column INSERT generates 10 `sqlite3_bind_*` events. Wide-batch inserts (10K rows) = ~130K events per call, which sizes the ring at audit-time. Optionally elide bind events at the shim level (configurable via env var); the aggregator sees a single `sqlite3_bind_batch_summary` instead. Reserved span ID `0x107F` for the summary form when it lands.

4. **`db: ptr` vs `db_id: string_id`.** Pointer values are useful for grouping but unstable across runs. A `m.add_db_handle` METADATA event mapping `db: ptr` → opened path / fingerprint / journal mode once-per-database would let aggregator queries display readable database identifiers without bloating every event with a string_id arg.

5. **Counter sampling.** SQLite's internal counters (`sqlite3_db_status`, `sqlite3_status`) are query-able. Should the runtime poll them on a timer and emit `COUNTER` events? Probably yes; useful for tracking page-cache size / spill / etc. over time. Reserved range `0x1190`–`0x119F` for counter span IDs.

6. **Hook callback wrapping.** Implementing `0x1200`+ requires a separate C shim pass that interposes between SQLite and registered host callbacks. Non-trivial and tied to specific peer needs. Defer to v0.2; tracking issue rather than spec work.
