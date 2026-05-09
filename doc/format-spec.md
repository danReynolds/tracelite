# tracelite — Trace Format Specification

**Status:** Draft v0.1
**Audience:** Design review for the cross-library SQLite tracing package

This document specifies the on-the-wire and on-disk format for `tracelite`, a profiling system for the Dart SQLite ecosystem. Everything else in the package — the C shim, the Dart recorder, the aggregator, the visualizer, the CLI — implements against this contract.

The format has to satisfy seven properties:

| Property | Why |
|---|---|
| **Cheap on the hot path** | Producers (especially the C SQLite shim) write events from inside SQLite calls. Sub-10ns per event, no allocation. |
| **Producer-neutral** | C, Dart isolates, and future producers (Rust, native bindings) all write the same format. |
| **Timestamp-comparable across producers** | One monotonic clock domain for the whole trace; events from any producer can be merged by timestamp. |
| **Self-describing** | A trace from version N opens correctly in tools from version M. Schema lives inside the trace. |
| **Lossless on conversion** | Binary ↔ JSONL round-trips with no information loss. |
| **Streamable** | Producers append; readers can decode incrementally without seeking the whole file. |
| **Greppable archival form** | Committed artifacts are line-oriented JSON for diff/jq/grep. |

## Outline

1. [Glossary](#1-glossary)
2. [Clock domain](#2-clock-domain)
3. [Wire format (in-memory ring buffer)](#3-wire-format-in-memory-ring-buffer)
4. [File format on disk (`.tlt`)](#4-file-format-on-disk-strace)
5. [JSONL archival format](#5-jsonl-archival-format)
6. [Tags](#6-tags)
7. [Tracks](#7-tracks)
8. [Spans](#8-spans)
9. [Args](#9-args)
10. [String pool](#10-string-pool)
11. [Correlation IDs](#11-correlation-ids)
12. [Versioning and extensibility](#12-versioning-and-extensibility)
13. [Worked examples](#13-worked-examples)
14. [Decoder reference](#14-decoder-reference)

---

## 1. Glossary

- **Event** — a single timestamped record. Smallest unit in the trace.
- **Tag** — what kind of event (begin, end, instant, async-begin, …).
- **Track** — the producer that emitted the event (an isolate, a C thread, a remote process).
- **Span** — a named interval bounded by a paired BEGIN/END. Identified by a `span_id` from the span dictionary.
- **Args** — typed, positional parameters carried with an event. Schema lives in the span dictionary.
- **Correlation ID** — a 64-bit value linking events across tracks (one logical request's lifetime).
- **String pool** — interned strings referenced by integer ID; lets hot-path events carry strings without allocating.
- **Wire format** — packed binary written into the in-memory ring buffer. Hot path producers write this.
- **File format** — the on-disk `.tlt` representation. Lossless dump of wire format + dictionaries + footer.
- **JSONL format** — line-oriented JSON. Derived archival format for grepping, diffing, archiving.

## 2. Clock domain

All timestamps are nanoseconds from a **single, explicitly-shared** monotonic clock, captured at trace start.

| Platform | Source |
|---|---|
| Linux | `clock_gettime(CLOCK_MONOTONIC)` |
| macOS | `clock_gettime(CLOCK_MONOTONIC)` |
| Windows | `QueryPerformanceCounter`, normalized to ns |

The clock primitive is exposed by the C runtime (`tracelite_now_ns()`) and called identically by both C and Dart producers. Dart producers reach this clock through a small FFI shim provided by the `tracelite` package; **Dart's `Stopwatch` is not used** because its API does not promise the same epoch or backing clock as the native primitive on every platform.

Producers MUST use the runtime's clock function. Calling `Stopwatch.elapsedTicks`, `DateTime.now()`, or any other clock and treating the result as comparable to other producers' timestamps is undefined behavior — events may be misordered.

The header records:
- `start_realtime_ns` — wall clock at trace start (Unix nanoseconds)
- `start_monotonic_ns` — monotonic clock value at trace start, read from `tracelite_now_ns()`

Event timestamps are expressed as `current_monotonic_ns - start_monotonic_ns`, giving a 64-bit relative value with ~580-year range. The realtime stamp is for human-readable display only; ordering and durations use monotonic.

Clock drift, NTP adjustments, and suspend/resume cannot affect monotonic measurements within a single trace.

### Calibration events (optional, future)

If a producer cannot use `tracelite_now_ns()` (e.g., a pre-recorded or imported trace), it MAY emit periodic `_clock_calibration` METADATA events describing its local clock's offset and skew relative to the shared clock. The aggregator applies the calibration on read. v0.1 does not require this; producers must use the shared clock directly.

## 3. Wire format (in-memory ring buffer)

The wire format optimizes for hot-path producer cost. Producers append events to a per-thread (C) or per-isolate (Dart) ring buffer using lock-free atomic increments on a head pointer.

### Event encoding

Every event is a sequence of 64-bit words. The first word is the header; subsequent words depend on the tag and span schema.

**Header word (always present):**

```
bit position →
63          56 55           48 47           32 31    24 23    16 15        0
┌─────────────┬───────────────┬───────────────┬────────┬────────┬───────────┐
│    tag      │   track_id    │    span_id    │arg_cnt │ flags  │ reserved  │
│   8 bits    │    8 bits     │    16 bits    │ 8 bits │ 8 bits │  16 bits  │
└─────────────┴───────────────┴───────────────┴────────┴────────┴───────────┘
```

| Field | Width | Range | Meaning |
|---|---|---|---|
| `tag` | 8 | 0..255 | Event type (see [§6 Tags](#6-tags)) |
| `track_id` | 8 | 0..255 | Producer identifier (see [§7 Tracks](#7-tracks)) |
| `span_id` | 16 | 0..65535 | Reference into the span dictionary (see [§8 Spans](#8-spans)) |
| `arg_cnt` | 8 | 0..255 | Number of arg words following the timestamp |
| `flags` | 8 | bitmask | See *flag bits* below |
| `reserved` | 16 | — | Must be zero. Decoders must tolerate any value. |

**Flag bits (`flags` byte):**

| Bit | Name | Meaning |
|---|---|---|
| 0 | `HAS_CORRELATION` | Event carries a correlation ID in word 2 (before regular args) |
| 1 | `IS_DROPPED_MARKER` | Synthetic event indicating *N* events were dropped (count in word 2) |
| 2..7 | reserved | Must be zero |

**Timestamp word (always present):**

```
bit position →
63                                                                          0
┌──────────────────────────────────────────────────────────────────────────┐
│            timestamp_ns relative to trace start (64 bits)                │
└──────────────────────────────────────────────────────────────────────────┘
```

**Correlation word (present iff `HAS_CORRELATION`):**

```
┌──────────────────────────────────────────────────────────────────────────┐
│                  correlation_id (64 bits, opaque)                         │
└──────────────────────────────────────────────────────────────────────────┘
```

**Arg words (`arg_cnt` words):**

Each is a 64-bit word. The interpretation (signed, unsigned, float, pointer, string-pool index) is determined by the span's schema in the dictionary. The wire format does not carry per-event type tags.

### Hot-path code shape

C side:
```c
static inline void trace_begin(uint8_t track, uint16_t span) {
    if (__builtin_expect(!g_trace_active, 1)) return;
    uint64_t* slot = ring_reserve(2);
    slot[0] = ((uint64_t)TAG_BEGIN     << 56) |
              ((uint64_t)track         << 48) |
              ((uint64_t)span          << 32);
    slot[1] = monotonic_ns_relative();
}
```

Dart side:
```dart
@pragma('vm:prefer-inline')
void traceBegin(int span) {
  if (kTraceActive) {
    final i = _ring.reserve(2);
    _ring[i]     = (TAG_BEGIN << 56) | (_trackId << 48) | (span << 32);
    _ring[i + 1] = _ticker.elapsedNanoseconds;
  }
}
```

Both compile to ~5 ns on the hot path. In release builds, `kTraceActive` (Dart) and `g_trace_active` (C) const-fold or branch-predict to false; the body is empty / never executed.

### Ring buffer mechanics

The wire format describes how events are *encoded*. Reservation, commit ordering, drop semantics, drainage, crash safety, and the cross-language mmap protocol are defined in [`runtime-protocol.md`](runtime-protocol.md). Readers of *this* spec only need to know:

- Each producer owns a private ring buffer in a shared mmap region.
- An event occupies `2 + arg_cnt + (HAS_CORRELATION ? 1 : 0)` 64-bit words.
- A drained ring is a sequence of completed events from `tail` to `head`; partial / uncommitted slots are not visible to drainage.

For the actual atomics, header word ordering, drop policy, and mmap layout, see `runtime-protocol.md`. The two specs together form the producer/consumer contract; do not re-derive ring mechanics from this doc alone.

## 4. File format on disk (`.tlt`)

The on-disk format is a lossless serialization of the wire-format events plus the dictionaries that interpret them.

```
┌─────────────────────────────────────────────────────────────┐
│ Section 0: Header (fixed 64 bytes)                          │
├─────────────────────────────────────────────────────────────┤
│ Section 1: Track dictionary                                 │
├─────────────────────────────────────────────────────────────┤
│ Section 2: Span dictionary                                  │
├─────────────────────────────────────────────────────────────┤
│ Section 3: Initial string pool                              │
├─────────────────────────────────────────────────────────────┤
│ Section 4: Event stream                                     │
│   • merged from all producers, ordered by timestamp         │
│   • may contain inline `METADATA` events extending dicts    │
├─────────────────────────────────────────────────────────────┤
│ Section 5: Footer                                           │
│   • per-track event counts, dropped counts, trace duration  │
└─────────────────────────────────────────────────────────────┘
```

Each section is preceded by a 24-byte preamble: `[u32 section_id, u32 reserved, u64 length, u64 flags]`. Decoders that don't understand a section ID skip ahead by `length` bytes, preserving forward compatibility.

Section length is u64 because traces from production-replay or long-running profiling can exceed 4 GiB; cropping to u32 would silently truncate. The trailing `flags` field is reserved for per-section flags (e.g., `0x01 = gzipped`, `0x02 = checksummed`).

### Header (Section 0)

64 bytes, fixed layout:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | Magic: ASCII `"TLTE"` (0x54 0x4C 0x54 0x45) |
| 4 | 2 | Format major version (currently 1) |
| 6 | 2 | Format minor version (currently 0) |
| 8 | 8 | Trace start realtime (Unix ns) |
| 16 | 8 | Trace start monotonic (ns) |
| 24 | 1 | Endianness (0x01 = little, 0x02 = big) |
| 25 | 1 | Flags (bit 0 = gzipped following sections) |
| 26 | 6 | Reserved (must be zero) |
| 32 | 32 | Producer string (null-padded UTF-8, e.g. `"tracelite 0.1.0"`) |

Backward compatibility rule: minor version increments are additive (decoders ignore unknown additions). Major version increments require new decoder support.

### Track dictionary (Section 1)

```
[u16 count]
for each track:
  [u8 track_id]
  [u8 kind]                   (0 = unknown, 1 = isolate, 2 = c_thread, 3 = process)
  [u16 process_name_len] [bytes utf8 process_name]
  [u16 thread_name_len]  [bytes utf8 thread_name]
  [u32 metadata_count]
  for each metadata k/v:
    [u16 key_len]   [bytes utf8 key]
    [u16 value_len] [bytes utf8 value]
```

Tracks are typically declared upfront, but new tracks can also be introduced mid-stream via `METADATA` events in the event section (see §6).

### Span dictionary (Section 2)

A span definition has *three* arg schemas, one per event phase:

- `begin_args` — args observable at the BEGIN event (inputs to a function, or fields known when an interval starts).
- `end_args` — args observable at the END event (outputs, return codes, fields known only when the interval ends).
- `instant_args` — args carried by an INSTANT event using this span ID.

Each phase's arg list can be empty. ASYNC_BEGIN uses `begin_args`; ASYNC_END uses `end_args`. A span ID can be used in any of {BEGIN, END, ASYNC_BEGIN, ASYNC_END, INSTANT} as long as the corresponding schema is non-empty (or the producer emits zero args, which is always valid).

Why three schemas and not one: SQLite C calls have inputs known at BEGIN (`sql`, `stmt`, `idx`, `len`) and outputs known only at END (`rc`, `stmt_out`, `blob_out`). A single positional schema cannot represent that without lying about which values are observable at which event.

```
[u16 count]
for each span:
  [u16 span_id]
  [u8 category]               (enum: 0=unknown, 1=sqlite_c, 2=ffi, 3=dart, 4=user)
  [u16 name_len] [bytes utf8 name]
  [u8 begin_arg_count]
  for each begin arg:
    [u8 type]                 (see §9 Arg type codes)
    [u16 name_len] [bytes utf8 arg_name]
  [u8 end_arg_count]
  for each end arg:
    [u8 type]
    [u16 name_len] [bytes utf8 arg_name]
  [u8 instant_arg_count]
  for each instant arg:
    [u8 type]
    [u16 name_len] [bytes utf8 arg_name]
```

Decoders match an event's `arg_cnt` against the schema for the event's tag:
- `BEGIN` / `ASYNC_BEGIN` → `begin_args`
- `END` / `ASYNC_END` → `end_args`
- `INSTANT` → `instant_args`

`COUNTER`, `METADATA`, and `FLOW` events use a fixed schema documented per-tag in §6, not the span dictionary.

Span IDs partition into ranges:
- `0x0000–0x0FFF` reserved for tracelite built-ins
- `0x1000–0x1FFF` reserved for the C SQLite shim (one ID per SQLite C API)
- `0x2000–0x2FFF` reserved for the Dart recorder built-ins
- `0x3000–0x3FFF` reserved for the FFI bridge
- `0x4000–0xFFFF` available for user/library spans

Reserved IDs and their schemas are enumerated in `tools/spans.yaml`; the format-spec appendix and `span-registry.md` are generated from that source-of-truth file. Hand-edits to ID/name/schema in those generated tables will be lost on regeneration.

### String pool (Section 3)

```
[u32 count]
for each string:
  [u32 string_id]
  [u32 len] [bytes utf8 string]
```

Initial pool. Strings can also be added mid-stream via `METADATA` events.

### Event stream (Section 4)

A length-prefixed run of events in the wire format described in [§3](#3-wire-format-in-memory-ring-buffer).

```
[u64 event_bytes]
[event_bytes of packed event data]
```

Events are merged across all producers and ordered by timestamp. Within a single track, events appear in the original order they were appended to that track's ring buffer; per-track order is the strict tie-break for events with equal timestamps. Across tracks, ties of equal `(timestamp, per-ring sequence)` break by ascending `track_id`. This guarantees same-track BEGIN→END pairing is preserved across canonicalization, which a `(track_id, span_id, tag)` tie-break does not.

The merged ordering is canonical: writers and readers should produce identical bytes for identical event sequences, so traces are content-addressable for caching.

### Footer (Section 5)

```
[u32 track_count]
for each track:
  [u8 track_id]
  [u8 reserved[3]]
  [u64 event_count]
  [u64 dropped_count]
[u64 first_event_ts_ns]
[u64 last_event_ts_ns]
[u64 total_events]
[u8 sha256_of_event_section[32]]    (for content addressing / cache validation)
```

The 32-byte field is the full SHA-256 of the event section bytes. It is for cache invalidation and dedup, not authentication.

## 5. JSONL archival format

Generated by the `tracelite export --format=jsonl` command (or equivalent API). Lossless round-trip with the binary format.

Each line is a JSON object with a `t` field discriminator. Lines are emitted in order: header, tracks, spans, strings, events, footer.

```jsonl
{"t":"hdr","ver":[1,0],"start_rt":1736337692000000000,"start_mono":12345,"producer":"tracelite 0.1.0"}
{"t":"trk","id":1,"kind":"isolate","process":"resqlite","thread":"main"}
{"t":"trk","id":2,"kind":"isolate","process":"resqlite","thread":"writer"}
{"t":"trk","id":3,"kind":"c_thread","process":"libtracelited","thread":"writer-c"}
{"t":"spn","id":4096,"cat":"sqlite_c","name":"sqlite3_step","args":[{"name":"stmt","type":"ptr"},{"name":"rc","type":"i32"}]}
{"t":"str","id":1,"v":"UPDATE wide SET a = ? WHERE id = ?"}
{"t":"e","tag":"B","trk":2,"spn":8192,"ts":1024,"args":[1]}
{"t":"e","tag":"B","trk":3,"spn":4096,"ts":1180,"args":[140295843,0]}
{"t":"e","tag":"E","trk":3,"spn":4096,"ts":12340,"args":[140295843,100]}
{"t":"e","tag":"E","trk":2,"spn":8192,"ts":12410,"args":[1]}
{"t":"ftr","tracks":[{"id":1,"events":47,"dropped":0}, ...],"first_ts":0,"last_ts":104230,"total":2003}
```

Conventions:
- Field names are short to keep line size down.
- Timestamps are integer ns, relative to trace start.
- `args` is a positional array; types resolved against the span dictionary.
- `string_id` args are emitted as integers; the consumer joins to the string pool.
- Diff and grep work naturally because each event is one line.

## 6. Tags

Closed enumeration. Decoders MUST treat unknown tag values as a forward-compat error and skip the event according to the schema (using `arg_cnt`).

| Tag | Value | Meaning |
| Tag | Value | JSONL token | Args source | Meaning |
|---|---|---|---|---|
| `BEGIN` | 0x01 | `"B"` | span schema's `begin_args` | Span starts. Matched by `END` with same `(track_id, span_id)`. Stack-discipline within a track. |
| `END` | 0x02 | `"E"` | span schema's `end_args` | Span ends. |
| `INSTANT` | 0x03 | `"I"` | span schema's `instant_args` | Single-point event with no duration. |
| `ASYNC_BEGIN` | 0x04 | `"AB"` | span schema's `begin_args` | Span starts; matched by `ASYNC_END` with same `correlation_id`, possibly on a different track. |
| `ASYNC_END` | 0x05 | `"AE"` | span schema's `end_args` | Span ends. |
| `COUNTER` | 0x06 | `"C"` | fixed: `[value: i64]` | Sample of a numeric counter. The span's `name` identifies the counter; `value` is its sampled value. |
| `METADATA` | 0x07 | `"M"` | fixed per-kind (see §6.1) | Adds/extends a dictionary entry mid-stream. |
| `FLOW` | 0x08 | `"F"` | fixed: `[from_track: u64, from_seq: u64]` | Visual link between events on different tracks. |

JSONL token values are case-sensitive; both encoders and decoders MUST use the exact strings above.

`BEGIN/END` pairs are *strict stack discipline within a track*: an `END` on track `T` matches the most recent open `BEGIN` on track `T` with the same `span_id`. This makes them cheap to pair (single linear pass), and it matches how SQLite C calls actually nest in a single thread.

`ASYNC_BEGIN/END` is the cross-track equivalent: same span_id, matched by `correlation_id` regardless of which track sent each end.

### 6.1 METADATA payload schemas

A `METADATA` event's `span_id` field is reused as `metadata_kind`. Args are fixed per kind, not from the span dictionary.

| `metadata_kind` (carried in `span_id`) | Name | Args |
|---|---|---|
| 0x0001 | `m.add_span` | span_id: u64, name_string_id: string_id, category: u32, [begin/end/instant arg schema as `list_string_id` of `"<type>:<name>"` strings] |
| 0x0002 | `m.add_track` | track_id: u64, kind: u32, name_string_id: string_id, process_string_id: string_id |
| 0x0003 | `m.add_string` | string_id: u32, content_offset: u64, length: u64 |
| 0x0004 | `m.process_info` | pid: u64, exec_path_string_id: string_id |
| 0x0005 | `m.hardware_info` | cpu_count: u32, page_size: u64, arch_string_id: string_id |
| 0x0006 | `m.annotation` | range_start: duration_ns, range_end: duration_ns, label_string_id: string_id |
| 0x0007 | `m.coverage` | covered_span_ids_list: list_u64 (which span IDs the producer was actually able to wrap) |
| 0x0008 | `m.sqlite_engine` | library_name_string_id: string_id, version_string_id: string_id, compile_options_string_id: string_id |
| 0x0009 | `m.scenario_info` | scenario_name_string_id: string_id, scenario_version: u32, parameters_json_string_id: string_id |
| 0x000A | `m.peer_info` | peer_name_string_id: string_id, peer_version_string_id: string_id, capabilities_json_string_id: string_id |
| 0x000B | `m.clock_calibration` | producer_track: u64, offset_ns: i64, skew_ppb: i64 |

Decoders that don't recognize a `metadata_kind` skip the event using `arg_cnt` (additive forward-compat). Producers MUST emit `m.coverage`, `m.sqlite_engine`, `m.scenario_info`, and `m.peer_info` once per trace before any non-metadata event from the corresponding subsystem; this is the source of the trace's coverage and version manifest.

## 7. Tracks

A track is a producer of events. Tracks are typed:

| Kind | Description | Examples |
|---|---|---|
| `isolate` | A Dart isolate | `main`, `writer`, `reader-1` |
| `c_thread` | A native thread | C SQLite shim writes from whichever thread calls SQLite |
| `process` | A separate process | for distributed tracing (future) |
| `unknown` | Producer didn't declare itself | fallback |

The track dictionary carries `process` and `thread` name strings for human display and `kind` for tooling. Custom k/v metadata is for things like "library name" (e.g., `library=drift`), used by the aggregator to attribute spans to peer libraries.

Up to 256 tracks per trace (8-bit ID). For most workloads this is plenty; if needed, multi-process traces could federate by exporting per-process traces and merging offline.

## 8. Spans

A span is a *named interval* (BEGIN/END pair) or a *named instant* (INSTANT event). Span IDs are 16-bit; the dictionary carries name, category, and arg schema.

Reserved built-in spans (initial set; full list in appendix):

| Range | Owner | Examples |
|---|---|---|
| `0x1000` | SQLite C shim | `sqlite3_prepare_v3`, `sqlite3_step`, `sqlite3_bind_text`, `sqlite3_column_text`, `sqlite3_reset`, `sqlite3_finalize`, `sqlite3_exec` |
| `0x2000` | Dart recorder built-ins | `dart.gc.minor`, `dart.gc.major`, `dart.isolate.spawn` |
| `0x3000` | FFI bridge | `ffi.entry`, `ffi.exit`, `ffi.string_marshal` |
| `0x4000+` | User-defined | application spans (Resqlite's `writer.execute`, drift's `query.compile`, etc.) |

User spans are registered at startup via the recorder API:

```dart
final querySpan = Span.register(
  'drift.query.compile',
  category: SpanCategory.user,
  args: [ArgSchema('rowCount', ArgType.i64)],
);
```

Registration emits a `METADATA` event extending the span dictionary, so the trace remains self-describing.

## 9. Args

Arg schemas are declared in the span dictionary as ordered, typed positional parameters. Each arg occupies exactly one 64-bit word on the wire.

| Type code | Name | Wire encoding | Decoded as |
| Type code | Name | Wire encoding | Decoded as |
|---|---|---|---|
| 0x01 | `i64` | two's complement | signed integer |
| 0x02 | `u64` | unsigned | unsigned integer |
| 0x03 | `i32` | low 32 bits, sign-extended on read; high 32 bits MUST be zero on write | signed integer |
| 0x04 | `u32` | low 32 bits, zero-extended on read; high 32 bits MUST be zero on write | unsigned integer |
| 0x05 | `f64` | IEEE 754 binary64 | floating point |
| 0x06 | `ptr` | unsigned pointer-sized value | opaque pointer (for object identity) |
| 0x07 | `string_id` | unsigned, references string pool | string |
| 0x08 | `bytes_len` | unsigned | integer (semantically a byte count, hint for renderers) |
| 0x09 | `duration_ns` | unsigned ns | duration |
| 0x0A | `bool` | 0 or 1 | bool |
| 0x0B | `count` | unsigned | element count (precedes a list arg) |
| 0x0C | `list_string_id` | one preceding `count` arg + N words, each a `string_id` | list of strings |
| 0x0D | `list_u64` | one preceding `count` arg + N words, each a `u64` | list of unsigned integers |
| 0x10–0xFF | reserved | — | — |

Renderers and aggregators can use the type to format arg values for display (e.g., `bytes_len → "1.4 KB"`, `duration_ns → "1.4 ms"`). The hot path doesn't care: every arg is a 64-bit memcpy.

### List args

A list arg occupies `1 + N` arg slots: one `count` slot holding `N`, followed by `N` slots of the element type. Lists exist for events that genuinely need variable-length payload (e.g., stack samples carrying frame string IDs); they are not a general-purpose type. The `arg_cnt` field in the event header MUST count both the `count` slot and the element slots — i.e., `arg_cnt = sum over args of (1 + N)` for list args, `1` for scalar args.

When decoding, the schema's positional arg list specifies which positions are `count`-prefixed list types; the decoder reads the count, then `N` element words.

Span schemas with list args MAY appear at most once per schema, and the list arg MUST be the last positional arg (no fixed args may follow a list).

## 10. String pool

Strings (SQL text, file paths, names) are interned at registration and referenced by ID on the hot path. This keeps the wire format alloc-free.

```dart
final sqlId = stringPool.intern('UPDATE wide SET a = ? WHERE id = ?');
traceBeginWith(Span.executeRequest, sqlId);
```

C side:
```c
uint32_t sql_id = trace_intern_string(sql, len);  // hash + cache
trace_begin_args(SPAN_EXECUTE_REQUEST, sql_id);
```

The intern operation is amortized O(1) (hash table lookup); on first registration it emits a `METADATA` event extending the pool. After registration it's a hash lookup returning a cached ID.

The pool is per-trace, not per-process. A new trace starts with an empty pool.

## 11. Correlation IDs

64-bit values that link events across tracks. Used for one logical request's lifetime spanning isolate boundaries.

```dart
final reqId = TraceId.next();  // atomic counter

// On main isolate:
traceAsyncBegin(Span.executeRequest, reqId);
sendPort.send(ExecuteRequest(..., traceId: reqId));

// On writer isolate (received the message, extracts traceId):
traceAsyncBegin(Span.writerHandle, reqId);
// ... handler runs ...
traceAsyncEnd(Span.writerHandle, reqId);

// Back on main isolate when response arrives:
traceAsyncEnd(Span.executeRequest, reqId);
```

The aggregator can now reconstruct the full lifecycle of every request by joining on correlation ID.

Correlation IDs flow over Dart `SendPort`s as ordinary `int` fields on the message types — no special infrastructure. The C shim doesn't generate correlation IDs but receives them via thread-local context: a Dart isolate sets a thread-local correlation ID before crossing into FFI, the C shim reads it and tags any events fired during the FFI call.

## 12. Versioning and extensibility

| Change | Allowed in minor version? | Allowed in major version? |
|---|---|---|
| Add new tag value | No | Yes |
| Add new arg type code | No | Yes |
| Add new span ID in reserved range | Yes | Yes |
| Add new track kind | Yes | Yes |
| Add field to track dictionary entry | Yes (as new metadata k/v) | Yes |
| Add new section to file format | Yes (decoders skip unknown sections) | Yes |
| Change header layout | No | Yes |
| Repurpose a tag value | Never | Never (allocate a new one) |

Decoders handle minor-version traces from future producers transparently. Major-version traces require explicit support.

## 13. Worked examples

### Example A: A single Resqlite write, fully traced

Suppose Resqlite's main isolate calls `db.execute('UPDATE wide SET a = ? WHERE id = ?', ['x', 42])`. With the C shim loaded and Resqlite's Dart-side instrumentation active, the trace contains:

```jsonl
{"t":"hdr","ver":[1,0],"start_rt":...,"start_mono":...,"producer":"tracelite 0.1.0"}
{"t":"trk","id":1,"kind":"isolate","process":"resqlite","thread":"main"}
{"t":"trk","id":2,"kind":"isolate","process":"resqlite","thread":"writer"}
{"t":"trk","id":3,"kind":"c_thread","process":"libtracelited","thread":"writer"}
{"t":"spn","id":16384,"cat":"user","name":"db.execute","args":[{"name":"sql","type":"string_id"}]}
{"t":"spn","id":16385,"cat":"user","name":"writer.handle.ExecuteRequest","args":[]}
{"t":"spn","id":4101,"cat":"sqlite_c","name":"sqlite3_prepare_v3","args":[{"name":"sql","type":"string_id"},{"name":"rc","type":"i32"}]}
{"t":"spn","id":4102,"cat":"sqlite_c","name":"sqlite3_bind_text","args":[{"name":"idx","type":"i32"},{"name":"len","type":"bytes_len"}]}
{"t":"spn","id":4103,"cat":"sqlite_c","name":"sqlite3_bind_int","args":[{"name":"idx","type":"i32"},{"name":"val","type":"i64"}]}
{"t":"spn","id":4104,"cat":"sqlite_c","name":"sqlite3_step","args":[{"name":"rc","type":"i32"}]}
{"t":"spn","id":4105,"cat":"sqlite_c","name":"sqlite3_reset","args":[{"name":"rc","type":"i32"}]}
{"t":"str","id":1,"v":"UPDATE wide SET a = ? WHERE id = ?"}
{"t":"e","tag":"AB","trk":1,"spn":16384,"ts":0,"corr":42,"args":[1]}
{"t":"e","tag":"AB","trk":2,"spn":16385,"ts":108,"corr":42,"args":[]}
{"t":"e","tag":"B","trk":3,"spn":4101,"ts":150,"args":[1,0]}
{"t":"e","tag":"E","trk":3,"spn":4101,"ts":3210,"args":[1,0]}
{"t":"e","tag":"B","trk":3,"spn":4102,"ts":3290,"args":[1,1]}
{"t":"e","tag":"E","trk":3,"spn":4102,"ts":3380,"args":[1,1]}
{"t":"e","tag":"B","trk":3,"spn":4103,"ts":3410,"args":[2,42]}
{"t":"e","tag":"E","trk":3,"spn":4103,"ts":3450,"args":[2,42]}
{"t":"e","tag":"B","trk":3,"spn":4104,"ts":3490,"args":[]}
{"t":"e","tag":"E","trk":3,"spn":4104,"ts":11200,"args":[101]}
{"t":"e","tag":"B","trk":3,"spn":4105,"ts":11240,"args":[]}
{"t":"e","tag":"E","trk":3,"spn":4105,"ts":11290,"args":[0]}
{"t":"e","tag":"AE","trk":2,"spn":16385,"ts":11420,"corr":42}
{"t":"e","tag":"AE","trk":1,"spn":16384,"ts":11580,"corr":42}
{"t":"ftr","tracks":[...],"first_ts":0,"last_ts":11580,"total":15}
```

Reading this trace, an analyst can:
- Compute total wall: 11580 - 0 = 11.58 µs.
- Attribute it: 108ns main→writer dispatch, 42ns writer setup, 150ns to first FFI call, 3060ns prepare, 90ns + 40ns binds, 7710ns step, 50ns reset, 220ns response back to main.
- See that **prepare took 26% of the call** — directly visible, no inference needed.
- Compare against the same workload run through `drift` and see whether drift's prepare cost differs.

### Example B: Cross-library comparison

Same workload through two libraries:

```bash
tracelite run --interface=resqlite --output=resqlite.tlt narrow_batch_insert
tracelite run --interface=drift    --output=drift.tlt    narrow_batch_insert
tracelite diff resqlite.tlt drift.tlt --by-span
```

Output:

```
Span                       │ resqlite        │ drift           │ Δ
────────────────────────────┼─────────────────┼─────────────────┼──────────
sqlite3_prepare_v3 (count)  │ 1               │ 1000            │ +99900%
sqlite3_prepare_v3 (p50)    │ 28µs (one-time) │ 14µs            │ –
sqlite3_step (count)        │ 1000            │ 1000            │ —
sqlite3_step (p50)          │ 7.4µs           │ 7.6µs           │ +2.7%
sqlite3_reset (count)       │ 1000            │ 0               │ —
sqlite3_finalize (count)    │ 1               │ 1000            │ +99900%
ffi.entry (count)           │ 4002            │ 6000            │ +49.9%
```

Now we can see *exactly* why one is faster: drift prepares + finalizes per query, Resqlite caches the prepared statement. The difference is not "Resqlite is faster" — it's "Resqlite avoids 999 prepare/finalize cycles per workload run."

### Example C: Tail latency analysis

```dart
final trace = await Trace.load('trace.tlt');
final stepDurations = trace.spans
    .where((s) => s.id == BuiltinSpans.sqlite3Step)
    .map((s) => s.duration);

print(stepDurations.distribution());
// p50: 7.2µs  p90: 8.1µs  p99: 14.3µs  max: 142µs

// What were the slow ones?
final slow = trace.spans
    .where((s) => s.id == BuiltinSpans.sqlite3Step && s.duration > 50_000)
    .map((s) => s.context);  // co-occurring spans on same track during this span
print(slow.first); // shows what else was happening — GC pause? FK check?
```

## 14. Decoder reference

A correct decoder for format v1.x:

1. Read the 64-byte header. Verify magic = `TLTE` and major version = 1.
2. Read sections in order. For each section preamble, read `section_id` and `length`.
3. If `section_id` is unknown, skip `length` bytes; do not error.
4. For known sections, parse per the schema in §4.
5. Inside the event stream:
   - Read header word, extract tag and arg_cnt.
   - If `HAS_CORRELATION` flag is set, read correlation word.
   - Read `arg_cnt` arg words.
   - If tag value is unknown, advance per `arg_cnt` and continue (forward-compat).
   - Pair `BEGIN`/`END` per stack discipline within a track.
   - Pair `ASYNC_BEGIN`/`ASYNC_END` by correlation_id.
6. Inline `METADATA` events extend dictionaries; updates are visible to subsequent events.

### Unknown tag handling

A decoder that encounters an unknown tag value MUST:

- Read `arg_cnt` from the header (its position is stable across format versions).
- Skip `2 + arg_cnt + (HAS_CORRELATION ? 1 : 0)` words.
- Continue reading the next event.
- Emit one warning per unique unknown tag value encountered (not per event), naming the value.

Unknown tags are *warnings*, not errors. Format minor versions are additive; a v1.1 producer emitting a v1.1-only tag must be readable (with degraded fidelity) by a v1.0 decoder.

A decoder MAY refuse to decode entirely if the format major version is unknown.

## Privacy and redaction

Traces can contain sensitive data: SQL text (which may include PII in literal values), file paths, pointer values that reveal heap layout, and any user-supplied strings interned into the pool. Trace files are intended to be *committed* alongside benchmark results, so this is a real concern.

Producers and exporters MUST support three redaction modes:

| Mode | Default | What's preserved | What's redacted |
|---|---|---|---|
| `raw` | only when explicitly enabled | everything | nothing |
| `fingerprinted` | default for committed artifacts | normalized SQL fingerprints (literals → `?`), structural metadata | SQL literal values, paths beyond a configurable root, pointer values (replaced with stable per-trace IDs) |
| `redacted` | for traces shared externally | structural metadata only | all string-pool entries replaced with `<redacted>` except built-in identifiers; pointers nulled |

The redaction mode is recorded as a `m.process_info` extension arg. Decoders display the mode prominently; tools that compare or aggregate traces refuse to mix raw and redacted unless explicitly opted in.

Default mode for committed artifacts is `fingerprinted`. The CLI's `tracelite export` flips to `redacted` when the user passes `--redact-shared`.

## Open questions

These need decisions before implementation:

1. **String pool eviction.** For long-running traces, the pool grows unboundedly. Cap or LRU? For audit-style benchmarks (our primary use case), unbounded is fine; for live tracing it isn't.
2. **Multi-process federation.** Dart `Isolate.spawnUri` creates a new VM process. Should `tracelite` natively support multi-process traces, or require offline merging?
3. **Sampling counter cadence.** `COUNTER` events are sampled (heap size, queue depth). What's the default sample rate, and is it producer-driven or consumer-pulled?
4. **Compression.** Should `.tlt` files be gzipped by default? Saves significant disk space; minor decode cost.
5. **Stable span IDs across versions.** The reserved-range scheme works, but any rename/renumber breaks old traces. Probably need a "deprecated, see ID X" mechanism in the dictionary.

## Related work

- **Perfetto / Chrome Trace Event format** — closest cousin. Our format is intentionally simpler (closed tag set, fixed-width header, no protobuf dependency) but covers the same conceptual ground.
- **CTF (Common Trace Format)** — Linux's tracing format. Heavier; requires metadata files.
- **Linux `ftrace` ring buffer** — direct inspiration for our wire format. Lock-free per-cpu rings.
- **Dart's `dart:developer.Timeline`** — emits a JSON format readable by DevTools. Compatible bridge possible (export adapter).
