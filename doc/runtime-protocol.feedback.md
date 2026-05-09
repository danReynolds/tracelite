# Feedback: Runtime mmap Protocol

Reviewed: `runtime-protocol.md`

## TLDR

This is the highest-risk spec, and the doc correctly calls that out. The topology is plausible: one mmap region, per-producer SPSC rings, and a bounded drop policy are the right foundation. The current protocol is not yet implementable because the reservation/commit model contradicts itself, the string-pool allocator has a race, and the control-plane setup assumes Dart can mutate process environment variables.

Recommended direction: simplify v0.1 around audit-mode snapshot drainage and make live/cross-process drainage explicitly later. That lets the protocol be much smaller and easier to prove.

## Blockers

### 1. Reservation and commit order are contradictory

The producer pseudocode writes data, commits the header, then advances `head`. With that design, a consumer should never see an in-progress slot because `head` is not advanced until commit. But the crash-safety section says the producer has reserved a slot and advanced `head` before writing, so the reader can see stale data unless the header is zeroed.

Pick one model:

- Preferred for v0.1: commit by advancing `head` last. A crash before `head` advances loses the partial event but does not corrupt readable data. The reader only scans committed ranges.
- Alternative: reserve by advancing `head` first, but then every slot needs a commit bit/generation counter and the reader must understand permanent holes.

Do not mix the two. The commit-head-last model is much easier for an audit benchmark tool.

### 2. String pool overflow handling is racy

The current allocator does `fetch_add`, then if it overflowed does `fetch_sub`. With concurrent producers, subtracting can roll back another producer's successful reservation. Use a CAS loop that checks capacity before publishing the new head, or switch to per-producer string pools and merge them at drain.

Also decide how readers know a string write is committed in continuous mode. If string bytes are written before an event header's release-store, and consumers acquire-load that event header before resolving the string, document that ordering explicitly.

### 3. Producer registry publication can expose partial slots

The CAS changes `state` from 0 to 1 before process/thread metadata is filled. Readers are told to skip only `state == 0`, so they can observe a half-filled registered producer. Use states like:

- `0 empty`
- `1 claiming`
- `2 registered`
- `3 ended`

Only publish `registered` with release ordering after all metadata is written.

### 4. The environment setup example is invalid Dart

`Platform.environment['TRACELITE_REGION'] = region.path` will not work. Dart exposes the environment as an unmodifiable map. For in-process tracing, use an explicit Dart recorder attach API and a native shim attach call. For subprocess tracing, pass environment overrides when spawning the process.

### 5. Snapshot drainage needs a stronger stop handshake

Setting region `state = draining` and asking producers to spin before each event is not enough to guarantee a quiescent snapshot:

- a producer may already be inside a traced SQLite call;
- a native thread may not check the state until after emitting END;
- a producer that crashes or blocks while "draining" can stall the harness.

For v0.1, snapshot drainage should probably happen only at scenario boundaries after `Scenario.run()` returns and before producers resume new work. If you need mid-workload snapshots, define an acknowledgement counter per producer and a timeout policy.

## Important clarifications

- The topology says "no atomics at all - only memory barriers", but the pseudocode uses atomic loads/stores. Better phrasing: SPSC avoids CAS on the event hot path, but still uses atomic acquire/release communication.
- The layout text says "4 KB per registry slot for 256 producers"; the table and math imply 4 KB total for 256 slots.
- Defaults are inconsistent: region layout says max 256 producers, resource limits say default max producers is 8.
- `last_write_ts` is not a reliable liveness signal for an idle producer. A producer can be healthy and quiet for longer than 5 seconds.
- Drop-newest plus "emit marker on next successful write" can fail to emit a marker if the buffer remains full until finalization. The footer/drop counter must be the authoritative loss signal.
- Track slots are "not reusable within a trace"; with an 8-bit track ID this caps long-running live sessions. Fine for audit mode, but call it out as a live-mode limit.
- Cross-process attach via a known socket or signal handler is not just a later feature; it affects region path secrecy, cleanup, permissions, and Windows/macOS equivalents.
- If the mmap file can contain SQL and paths, it should be created with restrictive permissions and deleted robustly after finalization.
- The C and Dart sides must agree on atomic widths, alignment, endianness, and struct packing. Add ABI conformance tests that read/write a known ring from both languages.

## External checks

- Dart process environment is exposed as an unmodifiable map: https://api.flutter.dev/flutter/dart-io/Platform/environment.html
- POSIX `mmap` with `MAP_SHARED` shares writes through the underlying object: https://man7.org/linux/man-pages/man3/mmap.3p.html
- Linux `LD_PRELOAD` is useful but can be voided in secure-execution mode: https://www.man7.org/linux/man-pages/man8/ld-linux.8.html
- Windows DLL loading has known-DLL and search-order constraints that make "build-time substitution" a separate design, not a small runtime toggle: https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-search-order

## Suggested next edits

1. Rewrite the write protocol around one explicit commit model.
2. Replace string-pool `fetch_add`/`fetch_sub` with a CAS allocator or per-producer pools.
3. Add producer registry claiming vs registered states.
4. Replace the environment mutation example with explicit attach APIs.
5. Split v0.1 audit snapshot mode from future live/cross-process modes.
