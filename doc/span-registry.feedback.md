# Feedback: Span ID Registry

Reviewed: `span-registry.md`

## TLDR

The registry is necessary and should stay as a first-class spec. Right now it is not consistent enough to be the source of truth: IDs disagree with examples in other docs, arg schemas assume one schema per span even when SQLite calls have distinct input/output phases, and several declared arg types do not exist in the format spec.

Recommended direction: make this file generated or machine-checkable as early as possible. If IDs are public format, hand-maintained examples will drift.

## Blockers

### 1. Built-in IDs are already drifting across docs

Examples in `format-spec.md` use IDs like `4101` for `sqlite3_prepare_v3`, while this registry assigns `sqlite3_prepare_v3` to `0x1012` (`4114`). `aggregator-api.md` sketches `SpanRef sqlite3Step = SpanRef(0x1004)`, but `0x1004` is `sqlite3_close_v2` here.

This is exactly the drift the registry is meant to prevent. Generate `BuiltinSpans` constants and example dictionaries from the registry, or add a validation script that fails when examples reference an ID/name mismatch.

### 2. SQLite arg schemas need phase awareness

Many schemas mix input args, output args, and return codes into one list. That does not fit BEGIN/END spans:

- `stmt_out`, `blob_out`, and `ptr_out` are known only after the call.
- `rc` is known only after the call.
- `sqlite3_step` has the statement pointer before the call and the result code after it.

The registry should define `begin_args` and `end_args`, or it should say these SQLite API spans are emitted as one complete duration event. Without that, decoders cannot validate event arg counts and the aggregator cannot expose return codes consistently.

### 3. Arg types do not match the format spec

The registry uses `u32` and `frames_string_ids[]`, but `format-spec.md` only defines fixed one-word arg types and does not include `u32` or list encodings. Stack samples also cannot be represented as a fixed schema if depth varies.

Add the missing arg types, or encode variable payloads through a separate sample section / blob payload mechanism.

### 4. Hook registration is not hook invocation

The hook rows describe calls like `sqlite3_update_hook`, but those calls only register callbacks. If tracelite wants to observe commit/update/preupdate events, it needs separate spans for callback invocation, with SQLite's documented caveats.

For example, SQLite documents that `sqlite3_update_hook` callbacks are not invoked for WITHOUT ROWID tables and that their ordering relative to the change is unspecified. That belongs in the registry if these hooks become analytic signals.

### 5. Partial C API coverage needs trace metadata

The doc says unwrapped APIs forward without timing. That is acceptable for v0.1, but every trace must record the shim coverage set and SQLite library identity/version. Otherwise a comparison can silently miss calls in one peer and not another.

## Important clarifications

- Hook/config APIs often take user data pointers (`pArg`, `pCtx`) and return previous user data pointers. Current rows often list callback and previous pointer but omit the user data pointer being installed.
- `sqlite3_trace_v2` is a registration API, not a replacement for per-C-function wrapping. It may still be useful as a low-overhead validation mode.
- `db: ptr` is useful for grouping but unstable across runs. A database-open metadata event should map `db` pointer to path/fingerprint/journal mode once, rather than repeating `db_id` on every event.
- SQL text should have an explicit policy: raw SQL string, normalized fingerprint, redacted SQL, or all three depending on mode.
- User span allocation is per-trace, but multiple isolates can register user spans concurrently. Define whether there is one shared allocator in the mmap region or per-producer user-span dictionaries merged at drain.
- The FFI bridge names are slightly misleading. `ffi.entry`/`ffi.exit` emitted by the C shim measure "inside wrapper before/after real SQLite", not the Dart-side time before the C wrapper starts. Dart-side marshalling spans should remain separate.
- If bind event volume is a known problem, reserve names for aggregate bind summaries now (`sqlite3_bind_batch_summary`, for example) so reports can distinguish elided detail from genuinely absent binds.
- Pointer values and SQL literals are sensitive when traces are shared. Add redaction guidance in this registry, not only in the format spec.

## External checks

- SQLite `sqlite3_trace_v2` registers one trace callback per connection and replaces prior trace callbacks: https://sqlite.org/c3ref/trace_v2.html
- SQLite commit/rollback hooks return the previous `pArg`, and callbacks must not modify the invoking connection: https://www.sqlite.org/c3ref/commit_hook.html
- SQLite update hooks have documented exclusions and unspecified ordering relative to the underlying change: https://www.sqlite.org/c3ref/update_hook.html

## Suggested next edits

1. Add begin/end arg schemas or replace SQLite call spans with complete duration events.
2. Generate `BuiltinSpans` and examples from the registry.
3. Add `u32` and variable-payload handling to the format, or remove those schemas.
4. Separate hook registration spans from hook callback-invocation spans.
5. Add coverage/version metadata required for every trace.
