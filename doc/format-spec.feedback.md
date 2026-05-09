# Feedback: Trace Format Specification

Reviewed: `format-spec.md`

## TLDR

The format is directionally strong: fixed-width hot-path records, dictionaries, JSONL export, and explicit track/span/correlation concepts are the right shape for this package. Do not implement this exact v0.1 yet. The largest gaps are that event arg schemas do not work for BEGIN/END pairs, the ring-buffer behavior conflicts with `runtime-protocol.md`, and a few binary fields are too small or incorrectly sized.

Recommended direction: keep the custom format, but tighten it into a mechanically testable binary contract before any C shim work starts.

## Blockers

### 1. Span arg schemas do not match real call timing

The current model gives each span one positional arg schema. That breaks for SQLite calls where inputs are known at BEGIN and outputs are only known at END. Examples already show the mismatch:

- `sqlite3_prepare_v3` has `sql`, `stmt_out`, and `rc`, but `stmt_out` and `rc` are only known after the call.
- `sqlite3_step` examples emit no args on BEGIN and `rc` on END, while the registry says the span has fixed args.
- The aggregator says `Span.args` comes from the BEGIN event, which would lose return codes and output pointers.

Pick one of these before implementation:

- Give every span schema separate `begin_args`, `end_args`, and `instant_args`.
- Make SQLite API calls single complete events with `start_ts` and `duration_ns`, not BEGIN/END pairs.
- Keep BEGIN/END but require END to repeat all input args plus output args, and define `Span.beginArgs` / `Span.endArgs`.

The first option is the cleanest because it keeps span pairing while matching C API reality.

### 2. Ring semantics conflict with `runtime-protocol.md`

This spec says producers append with atomic increments, writes wrap and overwrite old events, and drainage advances tail. The runtime spec says SPSC rings use no CAS, drop-newest is the chosen policy, and overwritten events are rejected.

Make `format-spec.md` describe only event encoding, then delegate reservation, commit, overflow, and crash behavior to `runtime-protocol.md`. A reader should not have to reconcile two different ring-buffer contracts.

### 3. File format fields are undersized or wrong

The section preamble uses `u32 length`, but the event stream has a `u64 event_bytes`. Large traces can exceed 4 GiB, especially if live/prod replay remains in scope. Use `u64 section_length`.

The footer field `u64 sha256_of_event_section` cannot hold SHA-256. Use 32 bytes, or rename it to a 64-bit non-cryptographic hash if that is the intent.

If the binary file is intended to be content-addressable, compression flags, section ordering, dictionary insertion order, and tie-break ordering all need canonicalization rules.

### 4. Timestamp tie-breaking can reorder same-track causality

Canonical ordering breaks timestamp ties with `(track_id, span_id, tag)`. That can reorder events emitted on the same track in the same nanosecond, especially BEGIN/END pairs or nested spans. Add a per-track sequence number or make the merge stable by original per-ring order, with sequence as the final tie-breaker.

### 5. Clock-domain claims are too strong

The spec says Dart `Stopwatch.elapsedTicks` and the C runtime use the same primitives, so no offset correction is needed. Dart's public `Stopwatch` API exposes elapsed ticks and frequency, but it does not promise the same epoch/source as a native shim. Either:

- have Dart producers call the same native monotonic function through a tiny FFI clock API, or
- record per-producer calibration events and correct offsets at drain time.

## Important clarifications

- `i32` says "high 32 bits zero"; signed i32 values need either sign extension or an explicit "low 32 bits interpreted as signed" rule.
- The arg table uses `u32` and variable lists elsewhere (`flags: u32`, stack sample frame lists), but `ArgType` does not define `u32` or list encodings.
- `METADATA` needs a typed payload schema. Right now it is both a tag and a polymorphic built-in span.
- Define whether `arg_cnt` counts only regular args or also synthetic words such as correlation IDs and dropped-event counts. The text currently treats correlation separately, but dropped markers blur the line.
- `String pool` says strings can be added via metadata events, while `runtime-protocol.md` uses the string ID as a direct byte offset into a shared pool. Those are compatible only if metadata is a derived archival representation, not the primary runtime mechanism.
- The JSONL tag strings (`B`, `E`, `AB`, `AE`) should be listed in the tag table so import/export is deterministic.
- The compression flag needs framing rules. If only following sections are gzipped, random access and section skipping change.
- Unknown tag handling says "forward-compat error and skip"; decide whether that is an error or a warning. For minor-version compatibility, skipping should probably be warning-level.
- Trace artifacts can leak SQL text, file paths, pointer values, and possibly user data in literal SQL. Add an explicit redaction/fingerprinting mode before encouraging committed artifacts.

## External checks

- Dart `Stopwatch` exposes elapsed ticks/frequency, but not a native clock identity guarantee: https://api.dart.dev/dart-core/Stopwatch-class.html
- `dart:developer` timeline APIs are primarily development/runtime-tooling APIs, not a production-format substitute: https://api.dart.dev/dart-developer/
- W3C Trace Context uses a 16-byte trace id plus 8-byte parent/span id for distributed propagation; tracelite can stay local-only, but should be explicit if 64-bit correlation IDs are not meant to interoperate: https://www.w3.org/TR/trace-context/
- Linux `LD_PRELOAD` can override dynamically linked functions, but secure-execution mode can strip or ignore it: https://www.man7.org/linux/man-pages/man8/ld-linux.8.html

## Suggested next edits

1. Add an "Event payload schemas" section that defines BEGIN/END/INSTANT args separately.
2. Replace `u32 section length` with `u64` and fix the SHA-256 footer field.
3. Add `seq` or per-track order to the event model.
4. Remove ring overflow mechanics from this doc and cross-link to `runtime-protocol.md`.
5. Add a privacy/redaction section covering SQL text, db paths, strings, and pointers.
