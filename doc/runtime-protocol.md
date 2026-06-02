# tracelite — Runtime mmap Protocol

**Status:** Draft v0.1
**Companion to:** `format-spec.md`, `aggregator-api.md`, `visualizer-binding.md`
**Audience:** Design review for the cross-library SQLite tracing package

The format spec defines what's in a trace at rest. This doc defines the *runtime* contract: how producers (the C SQLite shim, Dart isolates, the optional sampler) write events into a shared buffer, how the harness drains them, and what guarantees hold in the face of crashes, contention, and version skew.

This is the highest-risk doc in the corpus — if any format-spec assumption is wrong, it surfaces here first.

The protocol has to satisfy six properties:

| Property | Why |
|---|---|
| **Lock-free hot-path append** | The C shim writes events from inside SQLite calls. A futex or mutex on the hot path adds order-of-magnitude overhead and breaks "tracing must not perturb measurement." |
| **Cross-language without RPC** | C and Dart producers share one buffer that both read directly. No sockets, no IPC handshake, no marshalling. |
| **Crash-resilient** | If a producer dies mid-write, the partial event must be detectable and skippable, not corrupt the buffer. |
| **Self-describing** | A drained trace contains everything needed to interpret it — schema, dictionaries, producer registry. No external metadata. |
| **Bounded memory** | Buffer size is fixed at start. Overflow drops events, never grows. |
| **Predictable cost** | Every operation has a documented worst-case latency, suitable for putting in CI gates. |

## Outline

1. [Topology](#1-topology)
2. [Mmap region layout](#2-mmap-region-layout)
3. [Producer registry](#3-producer-registry)
4. [Per-producer ring buffers](#4-per-producer-ring-buffers)
5. [Slot reservation and the write protocol](#5-slot-reservation-and-the-write-protocol)
6. [Drop semantics](#6-drop-semantics)
7. [String pool extension](#7-string-pool-extension)
8. [Drainage protocol](#8-drainage-protocol)
9. [Memory ordering](#9-memory-ordering)
10. [Crash safety](#10-crash-safety)
11. [Cross-process attach](#11-cross-process-attach)
12. [Lifecycle](#12-lifecycle)
13. [Resource limits](#13-resource-limits)
14. [Worked examples](#14-worked-examples)

---

## 1. Topology

Tracelite uses a **single mmap'd region per trace**, owned by the harness, attached by every producer. Producers are typically all in-process (a Dart program loads the C shim through the sqlite3 native-hook resolver, so the C code and the Dart code share a process), but the protocol works for cross-process drainage as well.

Each *producer* (one Dart isolate, one C thread, one external process) gets its own private ring buffer within the shared region. This makes appends single-producer/single-consumer (SPSC). The hot path uses no compare-and-swap (CAS) and no inter-producer synchronization — only acquire/release atomics on the ring's `head` and `tail` to communicate with the consumer.

```
Process boundary (typically one process for both producers and harness)
┌───────────────────────────────────────────────────────────────────────┐
│                                                                       │
│   Dart isolate (main)        Dart isolate (writer)     C thread       │
│         │                          │                       │          │
│         ▼                          ▼                       ▼          │
│   ┌──────────┐                ┌──────────┐           ┌──────────┐     │
│   │ ring 1   │                │ ring 2   │           │ ring 3   │     │
│   │ (SPSC)   │                │ (SPSC)   │           │ (SPSC)   │     │
│   └────┬─────┘                └────┬─────┘           └────┬─────┘     │
│        │                           │                      │           │
│        └───────────────┬───────────┴──────────────────────┘           │
│                        ▼                                              │
│              ┌──────────────────┐                                     │
│              │  mmap'd region   │                                     │
│              │  (shared file)   │                                     │
│              └────────┬─────────┘                                     │
│                       ▲                                               │
│                       │                                               │
│              ┌────────┴─────────┐                                     │
│              │  Harness         │                                     │
│              │  (drainage)      │                                     │
│              └──────────────────┘                                     │
└───────────────────────────────────────────────────────────────────────┘
```

The mmap'd region is backed by a regular file. The harness creates and owns it; producers attach via `mmap` on the same path. The file lives in a temp directory for the trace's duration; the harness deletes it after writing the canonical `.tlt` output.

## 2. Mmap region layout

The shared file has a fixed-size header followed by a producer registry, the string pool buffer, and N ring buffers (one per producer).

```
Offset   Size               Section
─────────────────────────────────────────────────────────────────────
0        128 bytes          Region header (magic, version, control state)
128      4 KB               Producer registry (max 256 entries × 16 bytes)
4 KB     128 KB             String pool buffer
132 KB   variable           Ring buffer 0 (per-producer; size from header)
...      variable           Ring buffer 1
...      ...
```

Sizes are configurable at trace start (see §13 Resource limits). Defaults: 4 KB total for the producer registry (256 slots × 16 bytes), 128 KB string pool, 8 producers × 512 KB per ring buffer = 4 MB of rings, ~4.13 MB total. The 256-slot registry is fixed-size so the file layout is invariant; in practice the harness uses ≤8 of them in v0.1.

### Region header (128 bytes)

```
Offset   Size  Field                                          Notes
──────────────────────────────────────────────────────────────────────
0        4     Magic: 0x54 0x4C 0x54 0x52 ("TLTR")            Runtime magic; differs from .tlt file magic ("TLTE")
4        2     Format major version                           Must be 1
6        2     Format minor version                           Currently 0
8        8     Trace start realtime (Unix ns)                 Set by harness at start
16       8     Trace start monotonic (ns)                     Set by harness at start
24       4     Region total size (bytes)
28       4     Producer registry offset                       Currently always 128
32       4     String pool offset                             Currently always 4 KB + 128
36       4     String pool size (bytes)
40       4     Producer ring section offset                   = string pool offset + string pool size
44       4     Per-producer ring size (bytes)                 Same for all producers in this trace
48       4     Max producers                                  Hard cap 256 (8-bit track ID); typical use 8
52       1     State (0 = active, 1 = draining, 2 = closed)   Atomic; written by harness
53       1     Endianness (1 = LE, 2 = BE)                    Producer must match
54       2     Reserved
56       8     String pool head offset (bytes within pool)    Atomic; written by any producer interning
64       8     Total events written (across all rings)        Updated lazily by harness during drain; informational
72       8     Total events dropped (across all rings)
80       48    Reserved for future use
```

The header is written once at create time except for `state` and `string pool head offset`, which are atomic.

### Resilience: the magic + version pair

The runtime magic `TLTR` differs from the file magic `TLTE` deliberately. A reader that opens the mmap region of a still-active trace and tries to interpret it as a finalized trace file fails the magic check immediately, instead of producing garbage.

## 3. Producer registry

256 fixed-size slots starting at byte 128. Each slot is 16 bytes:

```
Offset   Size  Field
─────────────────────────────────────────────
0        1     state (0 = empty, 1 = claiming, 2 = registered, 3 = ended)
1        1     kind (0 = unknown, 1 = isolate, 2 = c_thread, 3 = process)
2        2     Reserved
4        4     Process name string ID (in pool)
8        4     Thread name string ID (in pool)
12       4     Producer-specific metadata string ID
```

### State machine

Slot state transitions:

```
   ┌─────────┐  CAS(0→1)   ┌──────────┐  release-store(1→2)  ┌────────────┐  store(2→3)  ┌─────────┐
   │  empty  │ ──────────► │ claiming │ ──────────────────► │ registered │ ───────────► │  ended  │
   └─────────┘             └──────────┘                      └────────────┘              └─────────┘
        ▲                       │                                                              │
        │                       │ (only the claiming producer ever sees this)                  │
        └───────────────────────┘                                                              │
              (CAS failed, slot freed by another producer's exit — not used in v0.1)           │
                                                                                                │
                                                  (slot is observable forever, never recycled) ◄┘
```

- **`empty` (0)** — Initial state. The slot is available for any producer to claim.
- **`claiming` (1)** — A producer has won the CAS and is currently filling in `kind`, process_name, thread_name, etc. **Readers MUST NOT consume slots in this state**; the metadata fields are not yet observable.
- **`registered` (2)** — The producer has finished filling in metadata and published the slot. Readers consume from this slot's ring. Events with this slot's track ID are valid.
- **`ended` (3)** — The producer has detached. No new events will come from this slot. Readers may still drain any unclaimed events from the ring.

### Claim protocol

```c
int reserve_track_id(uint8_t kind, uint32_t process_id, uint32_t thread_id) {
    // Phase 1: claim a slot atomically.
    int slot = -1;
    for (int i = 0; i < max_producers; i++) {
        uint8_t expected = 0;  // empty
        if (atomic_compare_exchange_strong_explicit(
                &registry[i].state, &expected, 1 /* claiming */,
                memory_order_acquire, memory_order_relaxed)) {
            slot = i;
            break;
        }
    }
    if (slot < 0) return -1;

    // Phase 2: fill in metadata. No reader observes these writes
    // because state is `claiming`, not `registered`.
    registry[slot].kind = kind;
    registry[slot].process_string_id = process_id;
    registry[slot].thread_string_id = thread_id;
    registry[slot].metadata_string_id = STRING_ID_OVERFLOW;

    // Phase 3: publish via release-store. Any reader that subsequently
    // observes state == 2 (acquire-load) is guaranteed to see the
    // metadata writes from phase 2.
    atomic_store_explicit(&registry[slot].state, 2 /* registered */,
                          memory_order_release);

    return slot;
}
```

The slot index *is* the track ID (8-bit, 0–255) referenced by events.

### Reader iteration

```c
for (int i = 0; i < max_producers; i++) {
    uint8_t s = atomic_load_explicit(&registry[i].state,
                                       memory_order_acquire);
    if (s < 2) continue;  // skip empty (0) and claiming (1)
    // s is 2 (registered) or 3 (ended) — metadata is fully visible.
    ...
}
```

Skipping `claiming` is the load-bearing fix relative to the previous design: a reader that consumed slots with state ≥ 1 could observe a partially-filled slot whose `kind` field hadn't been written yet, leading to an arbitrary `kind` value being attributed to the producer.

## 4. Per-producer ring buffers

Each producer owns a contiguous ring buffer. The harness allocates them at start, all the same size, contiguous in the mmap region.

```
Producer ring section (offset = producer ring section offset):

[ring 0 header (64 bytes)] [ring 0 data (size_bytes - 64)]
[ring 1 header (64 bytes)] [ring 1 data (size_bytes - 64)]
...
```

### Ring header (64 bytes)

```
Offset   Size  Field                          Atomicity
─────────────────────────────────────────────────────────
0        8     head (write index, in words)    producer-only writer
8        8     tail (read index, in words)     consumer-only writer
16       8     dropped count (events lost)     producer-only writer
24       4     size in words                   set at create, immutable
28       4     mask (size - 1)                 set at create, immutable
32       8     last write timestamp (ns)       producer-only writer; for liveness checks
40       1     producer state (mirror of registry, for liveness)
41       7     reserved
48       16    reserved
```

`head` and `tail` are 64-bit counters that wrap modulo `size`. The buffer is full when `head - tail == size`; it's empty when `head == tail`. Because they're counters, not indices, wrap-around aliasing is unambiguous (two producers writing event slot 0 are distinguishable by `head`).

Buffer size is a power of two so `& mask` replaces `% size`.

### Buffer data area

A flat array of 64-bit words. Events are variable-length, occupying 2 to ~10 words depending on tag and arg count.

## 5. Slot reservation and the write protocol

Single-producer / single-consumer (SPSC). The producer is the only writer of its own `head`; the consumer (harness, during drainage) is the only writer of `tail`. The hot path needs no CAS — only acquire/release barriers to make the writes visible to the consumer in the right order.

### Commit model: head-advances-last

The protocol uses **commit-head-last**: a slot is not visible to the consumer until `head` has been advanced past it. There is no "reserved but not yet committed" state visible across processes.

The producer's contract:

1. Snapshot `head` (own ring) and `tail` (consumer-written, acquire-load).
2. If `head + needed > tail + size_words`, the buffer is full. Increment `dropped` (relaxed) and return *without* touching `head`.
3. Otherwise, write the event's data and timestamp words to the slot.
4. Write the event's header word with `release` ordering.
5. Advance `head` with `release` ordering, by exactly `needed` words.

If a producer crashes between steps 3–5, no consumer ever observes the partial event because `head` was never advanced. There is no "zero-the-header-before-reserving" hack and no commit bit: the head pointer itself is the commitment signal.

### Producer write protocol

```c
// Write a BEGIN event with N args:
void trace_begin_args(uint8_t track, uint16_t span, int n_args, uint64_t* args) {
    if (!g_trace_active) return;                    // const-folded in release

    Ring* r = &g_rings[track];
    uint32_t needed = 2 + n_args;                   // header + timestamp + args

    // Snapshot tail; if buffer would overflow, drop.
    uint64_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    if ((head + needed) > tail + r->size_words) {
        atomic_fetch_add_explicit(&r->dropped, 1, memory_order_relaxed);
        return;
    }

    // Producer is sole writer of head and own data area; relaxed
    // ordering for the data writes is safe — the release on `head`
    // below establishes happens-before for the consumer.
    uint32_t mask = r->mask;
    uint32_t i = (uint32_t)(head & mask);

    r->data[(i + 1) & mask] = monotonic_ns_relative();
    for (int k = 0; k < n_args; k++) {
        r->data[(i + 2 + k) & mask] = args[k];
    }

    // Header word — release-store so a consumer that sees this header
    // also sees the data words above it.
    uint64_t header = build_header(TAG_BEGIN, track, span, n_args, /*flags*/ 0);
    atomic_store_explicit(&r->data[i], header, memory_order_release);

    // Commit: advance head with release so the consumer's acquire-load
    // of `head` synchronizes with everything written above. Until this
    // store, the slot is not visible to the consumer.
    atomic_store_explicit(&r->head, head + needed, memory_order_release);

    r->last_write_ts = monotonic_ns_relative();
}
```

Hot-path cost on x86_64: ~6 ns (4 stores + 1 release-store) for a 2-arg event. Atomic stores at relaxed/release on x86 compile to plain `mov`; ARM emits a `dmb ish*` barrier per release-store, costing ~1–3 ns each. Total hot-path budget on ARM is single-digit ns even with two release barriers.

### Why not "reserve head first, commit later"?

An alternative model — atomically advance `head`, then write the event, then mark a commit bit — was considered and rejected:

- It requires either a per-slot commit bit or zero-then-write semantics on the header. Both add hot-path cost.
- It exposes the consumer to *permanent holes* if a producer crashes mid-write. The consumer must distinguish "not yet committed" from "permanently dropped."
- It makes drainage non-monotonic: the consumer might see a hole where future writes will fill in.

Commit-head-last is strictly simpler. The trade-off is that a buffer-full check uses the *pre-reservation* head value, so a producer racing ahead of the consumer can underestimate available space by at most one event's worth of words. Acceptable.

### Variable-length encoding

Events are 2 to (2 + 255) words. The `arg_count` byte in the header lets readers advance correctly. Maximum event size is bounded; unknown-tag events are still skippable because `arg_count` lives in a fixed position.

### Wrap-around

`head` and `tail` are 64-bit counters that wrap modulo the buffer size on access via `& mask`. They never wrap as 64-bit values within a sane trace duration (~580 years at 2^32 events/sec).

## 6. Drop semantics

When `head + needed > tail + size`, the new event would overwrite unconsumed data. Three policy options:

| Policy | Behavior | Trade-off |
|---|---|---|
| **Drop newest (default)** | Increment `dropped`; don't write. | Loses recent events; recent events are typically what you want, but this guarantees the buffer is always consistent. |
| **Overwrite oldest** | Bump `tail` past the old event; write new. | Keeps recent events; reader must check for tail-bump between drains. |
| **Block** | Producer spins until consumer drains. | Perturbs measurement; rejected for hot-path use. |

Tracelite uses **drop newest**. Rationale:

- For audit-style runs (the primary use case), buffers are sized so drops never happen. A non-zero drop count at the end of a run is a bug in sizing.
- For long-running profiling, drop-newest preserves the *first* events, which include the warmup pattern and any setup state. The *recent* tail is replaceable by a longer rerun.
- Drop-newest needs no consumer-side bookkeeping; the reader just sees `dropped > 0` in the ring header and reports it.

When a producer drops, it tries to emit a synthetic dropped-marker event on its *next successful* write so the trace records where drops happened relative to surrounding events. **This is best-effort, not authoritative.** A producer that fills its ring and then never makes another successful write (e.g., the workload ends) will emit no marker, but the drop *did* happen.

The authoritative loss signal is the per-ring `dropped` counter in the ring header, captured into the footer at trace finalization. Drainage MUST report a non-zero footer-side dropped count to the user, even if no in-stream marker was emitted. Aggregators that compute coverage or fairness MUST consult the footer counts, not just in-stream markers.

## 7. String pool extension

The mmap region's string pool is a packed buffer of length-prefixed UTF-8 strings:

```
Offset (in pool)
0:    [u32 strlen][bytes utf8...]
N0:   [u32 strlen][bytes utf8...]
N1:   ...
```

A 64-bit atomic `string pool head offset` in the region header tracks the next free offset. Multiple producers may intern concurrently; the allocator must be safe under contention without ever rolling back another producer's successful reservation.

```c
uint32_t intern_string(const char* s, uint32_t len) {
    // Producer's local cache: hash → string_id. Avoids re-interning
    // on the hot path. Cache hit is the common case after warmup.
    uint32_t cached = local_cache_lookup(s, len);
    if (cached != STRING_ID_UNCACHED) return cached;

    uint32_t needed = 4 + len;
    uint64_t cur, next;

    // CAS loop: read head, check capacity, attempt to publish next.
    // If a competing producer publishes between our load and CAS, we
    // retry. We never decrement head — overflow returns the sentinel
    // ID instead, leaving any successful reservations intact.
    do {
        cur = atomic_load_explicit(&region->pool_head,
                                    memory_order_acquire);
        if (cur + needed > region->pool_size) {
            return STRING_ID_OVERFLOW;  // 0xFFFFFFFF
        }
        next = cur + needed;
    } while (!atomic_compare_exchange_weak_explicit(
                &region->pool_head, &cur, next,
                memory_order_acq_rel,
                memory_order_acquire));

    // We own bytes [cur, next). Write length + content.
    // (memory order is a release: we want consumers reading the
    // string_id to see these bytes, but the cross-producer visibility
    // is established by the CAS above, so plain stores suffice.)
    *(uint32_t*)&pool[cur] = len;
    memcpy(&pool[cur + 4], s, len);

    uint32_t string_id = (uint32_t)cur;  // ID is the byte offset
    local_cache_insert(s, len, string_id);
    return string_id;
}
```

`string_id` *is* the byte offset into the pool — readers index directly. This means string IDs are sparse (gap = 4 + len of each entry), but they're always valid pointers into the pool.

Why not `fetch_add`-then-`fetch_sub`-on-overflow: under contention, a second producer can observe the inflated head between fetch_add and fetch_sub, conclude the pool is full, return overflow, and never benefit from the sub. Worse, an overflow rollback can race with another producer's successful reservation in a way that loses bytes. The CAS loop is the standard correct allocator for this shape.

### Cross-language string-pool ordering

Once the CAS publishes a new `pool_head`, any consumer or other producer that subsequently reads `pool_head` (acquire) must see the bytes the publishing producer wrote. The CAS is `acq_rel`, which is sufficient as long as the byte writes happen *before* the CAS (i.e., before any other producer can compete for those bytes).

But the CAS is what reserves the bytes — we can't write them before reserving. The contract that makes this safe:

1. Producer reserves `[cur, next)` via the CAS.
2. Producer writes bytes into that range.
3. Any other producer's later CAS publishes a `pool_head` ≥ `next`, which means it has done an `acquire` after our `acq_rel`. The byte writes from our step 2 happened-before that acquire, so the other producer sees them.
4. A consumer reading the pool *up to* `pool_head` (acquire-load) is similarly synchronized.

The risk window is "another producer or consumer reads `pool[cur..next)` after we've published `pool_head = next` but before our memcpy completes." To eliminate this, the CAS uses `acq_rel` (publishes the new head) but the memcpy MUST come *before* the CAS that publishes — which means our actual implementation reverses the order:

```c
// Reserve space first via CAS, then write into it. The CAS-published
// head_offset is now strictly above our written bytes, so any later
// reader that loads >= our `next` necessarily sees our writes.
//
// Subtlety: between CAS and memcpy completion, OUR bytes are stale,
// but `pool_head` only points past `next` — readers consult
// `pool_head` to know the high-water mark, and the bytes at offsets
// in [cur, next) are claimed-but-not-written until memcpy completes.
//
// Concurrent readers must therefore not race: in v0.1, the consumer
// only reads the pool during snapshot drainage (mode A in §8), when
// producers are paused. Live-mode (continuous drainage) needs an
// additional commit signal — deferred to v0.2.
```

In practice, audit-mode drainage avoids this race entirely because producers are quiesced before the consumer reads the pool. v0.1 is correct under audit-mode; live-mode requires further design.

The producer's local cache (a hash table) avoids re-interning the same string. Misses cost a single atomic fetch-add and a memcpy.

`STRING_ID_OVERFLOW` (0xFFFFFFFF) is the sentinel for "couldn't fit"; the harness reports it as `<overflowed>` in any aggregator output.

## 8. Drainage protocol

**v0.1 supports only one drainage mode: scenario-boundary drainage.** Live-mode (continuous mid-workload drainage) and active stop-handshake mid-workload snapshots are deferred to v0.2 because they require additional protocol design (back-pressure, acknowledgement timeouts, reliable producer pause).

### Scenario-boundary drainage (v0.1)

The harness invokes drainage *between* `Scenario.run()` invocations. Producers are not actively writing — they're either between requests or already detached. Drainage requires no producer cooperation:

1. The harness has already issued an end-of-scenario boundary in its own track (e.g., the `_trace_end` event).
2. Harness `await`s any pending producer activity (e.g., joins child isolates, waits for the writer worker's reply queue to flush).
3. For each registered ring, harness reads events from `tail` to `head`, then sets `tail = head`.
4. Harness reads the string pool up to `pool_head` and the registry slots in state ≥ `registered`.
5. Harness writes a finalized `.tlt` file from the drained data; the region file is then unlinked.

Because producers are inactive during drainage, there's no race with concurrent writes. The reader uses standard acquire-loads on `head` and event header words; any event whose `head`-publication completed before the harness's check is visible.

### Ended producers

When a producer ends (e.g., an isolate exits, a C thread returns), it sets its registry slot's `state = ended` (3). After this point, no new events from that slot are written. Drainage processes ended slots identically to registered ones — it reads from `tail` to `head` once, captures any final events, and stops. Slots are never recycled within a trace.

This **is** a v0.1-mode constraint: the 256-slot registry caps the total number of producers a single trace can ever observe. For audit-style benchmarks (a handful of isolates spawned at scenario start), this is unbounded headroom. For long-running live tracing where isolates spawn/exit frequently, 256 slots is reachable in minutes. Slot recycling is a v0.2 design problem — it requires an additional generation counter per slot so consumers don't merge events from two different producers at the same slot index. Documented here as a known limitation, not a v0.1 bug.

### Live mode (deferred)

Continuous mid-workload drainage requires:

- A reliable mechanism to pause producers (current sketch — set `region.state = draining` and ask producers to spin — has the gaps the runtime feedback called out: producers may already be inside a traced SQLite call, native threads may not check state until after emitting END, and a crashed/blocked producer can stall the harness indefinitely).
- A back-pressure signal so a slow consumer can't be silently outpaced.
- Time-out policy for a producer that doesn't acknowledge a drain request within a configured window.

These add meaningful complexity. v0.1 has no production driver for live mode (audit benchmarks complete in seconds and one-shot drain), so the simpler scenario-boundary drainage is the only supported mode. Live mode is tracked as v0.2 work and will get its own design pass.

### Mid-workload snapshots in v0.1

If a v0.1 user genuinely needs a mid-workload snapshot, the supported pattern is "split your workload into multiple scenarios": run a setup, drain, run another scenario, drain again. This is sufficient for every benchmark-style use case.

### Reader iteration

Pseudocode for reading events from a ring:

```dart
void drainRing(int trackId) {
  final ring = mmap.ringForTrack(trackId);
  final head = atomic.loadAcquire(ring.headPtr);

  var pos = ring.tail;
  while (pos < head) {
    final headerWord = atomic.loadAcquire(ring.dataPtr + (pos & ring.mask));
    if (headerWord == 0) {
      // Producer reserved slot but hasn't written header yet (rare race).
      // Stop; pick up next drain.
      break;
    }

    final tag = (headerWord >> 56) & 0xFF;
    final argCount = (headerWord >> 24) & 0xFF;
    final hasCorr = (headerWord >> 16) & 0x01 != 0;
    final eventWords = 2 + argCount + (hasCorr ? 1 : 0);

    final ts = ring.read64(pos + 1);
    final corr = hasCorr ? ring.read64(pos + 2) : null;
    final argsStart = pos + 2 + (hasCorr ? 1 : 0);
    final args = [for (var i = 0; i < argCount; i++) ring.read64(argsStart + i)];

    yield Event(track: trackId, tag: tag, ts: ts, corr: corr, args: args, ...);

    pos += eventWords;
  }

  atomic.storeRelease(ring.tailPtr, pos);
}
```

The "header is zero, slot reserved but not written" case happens only in continuous-drain mode while a producer is mid-write. The reader stops reading that ring and tries again on the next drain.

## 9. Memory ordering

The hot path uses minimal memory ordering to keep cost predictable across architectures.

| Operation | Ordering | Why |
|---|---|---|
| Producer reads `head` (own ring) | relaxed | Producer is sole writer of own `head`. |
| Producer reads `tail` (own ring) | acquire | Pair with consumer's release-store of `tail`. |
| Producer writes data words | relaxed | Producer is sole writer; the release on header below establishes order. |
| Producer writes header word | release | Pair with consumer's acquire-read of header. |
| Producer writes `head` | release | Pair with consumer's acquire-load of `head`. |
| Consumer reads `head` | acquire | Pair with producer's release-store of `head`. |
| Consumer reads header | acquire | Pair with producer's release-store of header. |
| Consumer writes `tail` | release | Pair with producer's acquire-load of `tail`. |
| Atomic increment of `dropped` | relaxed | Counter; not a synchronization point. |
| String pool head fetch-add | relaxed | The pool data is written before `id` is returned to the caller; no other producer reads from a non-final offset. |

On x86, all of these compile to plain `mov`s; on ARM, the release/acquire pairs become `dmb ish*` barriers. Hot path on ARM costs ~5–10 ns more than on x86, all coming from the two release barriers per event.

## 10. Crash safety

If a producer dies mid-write:

1. **Before reserving (no slot claimed)** — buffer is unaffected. Standard.
2. **After reserving but before writing data** — `head` advanced but slot has stale data. The header word at the reserved slot is stale (from a previous wrap, possibly random); the consumer's `header == 0` check would fail. **Fix:** producers must zero the slot's header word before reserving, with `release` ordering, so a crashed reservation reads as `header == 0`.

   Updated reservation:
   ```c
   atomic_store_explicit(&r->data[i], 0, memory_order_release);
   r->data[i + 1] = ts;
   r->data[i + 2..n] = args;
   atomic_store_explicit(&r->data[i], header, memory_order_release);  // commit
   ```

3. **Mid-write, header zeroed but data partial** — consumer sees `header == 0`, treats slot as not-yet-committed, stops reading at this position. Subsequent drains (after process recovery? typically there's no recovery; the producer is dead) may still see `header == 0`. The harness eventually times out and treats the slot as a permanent gap.

4. **After writing data, before writing header commit** — same as #3; consumer sees `header == 0`.

5. **Header committed but `head` not yet advanced** — The consumer reads from `tail` to old-`head`, doesn't see the new event. Subsequent drains may see `head` advance; the event becomes visible. If the producer dies between header commit and `head` advance, the event is permanently invisible. This is acceptable: the harness has no way to know whether more events were intended.

The protocol survives any producer crash without corrupting the buffer or the trace. The worst case is some events lost.

`last_write_ts` is **not** a reliable liveness signal. A healthy producer can sit idle (between requests, between scenarios) for arbitrary periods. The harness must not assume "no write for N seconds" implies the producer is dead.

For v0.1 (audit-mode), liveness isn't needed: producers are joined explicitly by the harness before drainage. For live-mode, a future explicit heartbeat protocol (producer pings the region header on a timer) would be the right design — not a write-time check.

## 11. Cross-process attach

The mmap'd region is a regular file, so any process can attach by opening the file and `mmap`ing it. The path is communicated via three mechanisms, in priority order:

| Mechanism | When |
|---|---|
| Explicit API: `tracelite.attach(path)` (Dart) / `tlt_attach(path)` (C) | In-process Dart producers; explicit. |
| Environment variable `TRACELITE_REGION`, set by the harness *before spawning a child process* | Cross-process (e.g., spawning a benchmark binary). |
| Compile-time default path (build-time `-D TRACELITE_DEFAULT_REGION=...`) | Embedded scenarios where neither API nor env is available. |

### Why not mutate `Platform.environment`?

A previous draft of this doc suggested `Platform.environment['TRACELITE_REGION'] = path` from Dart. **This does not work.** Dart's `Platform.environment` is documented as an unmodifiable `Map<String, String>`; assignments throw at runtime.

To pass the env var to a *child process*, use `Process.run`'s `environment` parameter:

```dart
final region = await TraceRegion.create(...);
final result = await Process.run(
  'build/test_producer',
  const [],
  environment: {'TRACELITE_REGION': region.path},
);
```

To attach an *in-process* C runtime to an already-mmap'd region (typical case: a Dart program that loaded `libtracelite_runtime.so` via FFI), use the explicit attach API:

```dart
final region = await TraceRegion.create(...);
// Tell the FFI-loaded C runtime where the region lives.
final tlt = TraceliteFfi.load();
tlt.attach(region.path);
```

The C side reads `getenv("TRACELITE_REGION")` only as a fallback when no explicit path was provided to `tlt_attach(NULL)`.

### Cross-process attach for live tracing

For a profiler attaching to an already-running Dart program (where the program didn't pre-arrange a tracelite region), the producer process exposes its region path via either a signal handler or a Unix domain socket on a known path. Out of scope for v0.1.

## 12. Lifecycle

### Create

```dart
final region = await TraceRegion.create(
  path: '/tmp/tracelite-${pid}-${rnd}.tlt-region',
  totalSize: 4_500_000,                     // 4.5 MB
  perProducerRingSize: 524_288,             // 512 KB
  maxProducers: 8,
  stringPoolSize: 131_072,                  // 128 KB
);

// To attach an in-process C runtime (loaded via FFI):
TraceliteFfi.instance.attach(region.path);

// To pass the region to a child process spawned via Process.run:
final result = await Process.run(
  'build/test_producer',
  const [],
  environment: {'TRACELITE_REGION': region.path},
);
```

Steps:
1. Open the file with `O_CREAT | O_RDWR`, truncate to `totalSize`.
2. `mmap` with `PROT_READ | PROT_WRITE | MAP_SHARED`.
3. Write the region header (magic, version, timestamps, offsets, sizes).
4. Zero the registry, string pool, and ring buffers.
5. Initialize each ring's header with `size`, `mask`, `head=0`, `tail=0`.
6. Set `state = 0` (active).

### Producer attach

```c
// In the C shim's lazy init:
const char* path = getenv("TRACELITE_REGION");
int fd = open(path, O_RDWR);
size_t size = lseek(fd, 0, SEEK_END);
g_region = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
verify_magic_and_version(g_region);

// Reserve a track ID:
g_track_id = reserve_track_id();
my_ring = &rings[g_track_id];

// Register as a c_thread:
fill_registry_slot(g_track_id, KIND_C_THREAD, "writer", "main");
```

Producers attach lazily — on the first event they want to write. No cost if a process never traces.

### Drain (snapshot mode)

```dart
final events = region.drainAll();   // iterates all rings, returns merged event stream
final stringPool = region.stringPoolSnapshot();
final tracks = region.producers();
```

This is a pure read against the mmap; no synchronization with producers needed in snapshot mode (where producers have stopped).

### Finalize

```dart
final trace = await region.finalize(outputPath: 'trace.tlt');
region.dispose();   // unmaps, deletes file
```

Finalize merges all ring events (sorted by timestamp), writes the canonical `.tlt` file, and closes the region. The `.tlt` file is the durable artifact; the region file is ephemeral.

### Producer detach

```c
// In a Dart isolate's exit handler or the C shim's atexit handler:
my_ring->producer_state = 3;
// mmap stays attached (kernel will tear down on process exit anyway).
```

The harness sees `producer_state = 3` on its next drain and treats the producer
as ended.

### Quiescent reset

Long-lived benchmark workers need to reuse one process across independent
samples without writing every sample into the first `TRACELITE_REGION` they
attached. The runtime exposes `tlt_reset_runtime()` for this narrow case.

The reset contract is intentionally stricter than normal detach:

1. The harness calls it only at a quiescent boundary, after the measured
   workload has returned and before a new region is attached.
2. No producer thread may be inside a traced call or concurrently appending.
3. The runtime marks any registered/claiming tracks as ended, unmaps the
   current region, clears thread-local track state, and returns to inactive.
4. Harnesses for peers with asynchronous isolate or native-asset cleanup may
   hold this inactive state briefly after reset, so late producer calls are
   suppressed instead of landing in the next sample's region.
5. Each successful attach advances a runtime generation. Thread-local producer
   IDs from older generations are treated as detached, so threads reused by a
   long-lived worker must register a fresh producer before writing again.
6. The next sample must explicitly attach a new region or provide a new
   `TRACELITE_REGION` before producers emit again.

This is not a live-tracing control plane and it is not safe as an asynchronous
cancel operation. Its purpose is runner retargeting for native-assets-aware
workers, where process startup is expensive but samples still need isolated
region artifacts.

## 13. Resource limits

| Resource | Default | Tunable | Limit |
|---|---|---|---|
| Total region size | 4.5 MB | yes | ≤ available swap |
| Max producers | 8 | yes | 256 (8-bit track ID) |
| Per-producer ring size | 512 KB | yes | ≥ 4 KB, power of 2 |
| String pool size | 128 KB | yes | ≤ 4 GB (32-bit string ID space) |

Region size = 128 (header) + 4 KB (registry) + pool_size + maxProducers × ringSize.

For audit-style runs (~2K events × ~24 bytes/event = ~48 KB of event data total), defaults are wildly oversized — intentional, because the cost of being too small is dropped events, while the cost of being too large is a few MB of unused mmap pages.

For multi-hour profiling runs, sizing matters. The harness exposes a sizing helper:

```dart
final size = TraceRegion.recommendedSize(
  expectedEventsPerSecond: 50_000,
  durationSeconds: 600,
  producers: 4,
);
```

## 14. Worked examples

### Example A: Snapshot-mode drainage at scenario boundary

```dart
// Harness setup
final region = await TraceRegion.create(...);

// Tell the in-process FFI runtime where the region lives (no env var
// mutation; Platform.environment is unmodifiable).
TraceliteFfi.instance.attach(region.path);

// Run scenario (producers write to their rings via the C shim or Dart recorder)
await scenario.run(driftInterface);

// Drain
final trace = await region.finalize(outputPath: '${scenario.name}.tlt');

// Now the .tlt file is the canonical artifact; the region file is gone.
```

### Example B: Cross-language causal chain

A single Resqlite write produces events across three rings:
- Ring 1 (main isolate): `db.execute` async-begin and async-end.
- Ring 2 (writer isolate): `writer.handle.ExecuteRequest` async-begin and async-end.
- Ring 3 (writer's C thread): `sqlite3_prepare_v3`, `sqlite3_bind_text`, `sqlite3_step`, `sqlite3_reset`.

All three producers write to their own ring (no contention). Timestamps from one monotonic clock domain. Correlation ID 42 tags every event in the chain.

At drain, the harness reads all three rings, merges by timestamp, joins by correlation ID, produces a single causal trace. No coordination between producers during the workload.

### Example C: Drop on overflow

If a producer's ring is undersized for its workload, it drops:

```c
// 100K events fired into a 1024-event-capacity ring
for (int i = 0; i < 100000; i++) {
    trace_begin(SPAN_FOO);
    do_thing();
    trace_end(SPAN_FOO);
}

// Producer's `dropped` counter ends at ~99000.
// First successful event after a drop emits an IS_DROPPED_MARKER:
//   tag = INSTANT, span = built-in dropped-marker span, args[0] = dropped count
// Subsequent events resume normally.
```

The trace shows ~1024 events plus drop markers, not the 100K that would have existed. Aggregator reports `dropped > 0` and warns the user.

## 14a. File permissions and cleanup

The mmap region file can contain SQL text, paths, pointer values, and any user-provided strings interned into the pool. It MUST be created with restrictive permissions:

```c
// On creation:
int fd = open(path, O_CREAT | O_RDWR | O_EXCL, 0600);
//                                              ^^^^ owner read/write only
```

`O_EXCL` ensures the harness creates a fresh file (does not open an attacker-planted one). The path includes `pid` and a random component to avoid predictable filenames.

Cleanup contract:

- The harness MUST `unlink` the region file after `region.finalize()` succeeds.
- On harness crash, the file is left orphaned. v0.1 documents this; v0.2 may add a small reaper that removes orphan tracelite-region files older than N hours from the platform temp directory.
- Producers MUST NOT outlive the harness. If the harness goes away, a still-attached producer is writing to a deleted file (fine on POSIX — the inode lives until the last fd closes), but no one will ever read it.

## 14b. Cross-language ABI conformance tests

The C and Dart sides of the protocol must agree byte-for-byte on:

| Item | Source of truth | Tested by |
|---|---|---|
| Region header layout, total size = 128 bytes | `tracelite_runtime.h` `_Static_assert` | C builds fail if size drifts. |
| Registry slot size = 16 bytes | `tracelite_runtime.h` `_Static_assert` | Same. |
| Ring header size = 64 bytes | `tracelite_runtime.h` `_Static_assert` | Same. |
| Endianness of multi-byte fields | Region header `endianness` byte | Test reads back fields the C side wrote and compares. |
| Atomic widths and alignment | `<stdatomic.h>` types in C; `dart:ffi` widths on Dart | Smoke test produces events from C, parses from Dart, checks values match. |
| Span IDs and arg schemas | `tool/spans.yaml` → generator | CI's `dart run tool/generate.dart --check`. |

These checks live in `test/runtime_smoke_test.dart` and the C `_Static_assert`s. Any divergence fails build / test before any release goes out. The smoke test is the load-bearing protection here — it's the only test that exercises both sides of the runtime simultaneously.

## 15. Open questions

1. **Cross-process drainage.** Currently the harness has to be in the same process as the producers (or have read access to the mmap file path). Cross-process drainage (e.g., attaching to a running Flutter app) is more involved. Defer to v0.2.

2. **Memory pressure under live mode.** Continuous drainage avoids unbounded memory growth, but if drainage falls behind producers, drops happen. Need a back-pressure signal? Probably yes for production tooling, optional for benchmarks. Live mode is v0.2.

3. **Per-producer string pool vs shared.** Currently shared. Alternative: per-producer pools, merged at drain. Shared simplifies decoder; per-producer reduces atomic contention on `pool_head`. For our scale (~thousands of unique strings), shared is fine.

4. **Endianness.** Big-endian Dart on ARM exists but is rare. The endianness byte in the header lets a reader detect mismatch and byte-swap. Worth implementing? Probably yes; it's small.

5. **Versioned ring header layout.** Format minor version 0 has the layout above. If we add per-ring metadata (e.g., per-track flags), it goes after byte 48 — readers of older versions ignore the trailing bytes. No format-breaking change.

6. **Track slot recycling for live mode.** v0.1 forbids recycling. v0.2 needs a generation counter per slot so a recycled slot's events aren't merged with the prior occupant's events.

7. **Live-mode commit visibility for the string pool.** The current CAS allocator publishes `pool_head` with `acq_rel`, but producers can't write the bytes before reserving. v0.1 sidesteps the race because audit-mode drainage quiesces producers before reading. Live mode needs an additional commit signal — possibly a per-string commit bit, or two-phase publication via a staging buffer.
