/*
 * tracelite — runtime header.
 *
 * Defines the shared-mmap region layout and the producer-side API.
 * Both C and Dart producers write through this contract; the Dart
 * reader parses the same layout via FFI.
 *
 * See: doc/runtime-protocol.md and doc/format-spec.md
 */

#ifndef TRACELITE_RUNTIME_H
#define TRACELITE_RUNTIME_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Region magic and version ---- */

#define TRACELITE_REGION_MAGIC 0x52544c54  /* "TLTR" little-endian */
#define TRACELITE_FORMAT_MAJOR_RUNTIME 1
#define TRACELITE_FORMAT_MINOR_RUNTIME 0

/* ---- Tag values (must match format-spec §6) ---- */

#define TLT_TAG_BEGIN        0x01
#define TLT_TAG_END          0x02
#define TLT_TAG_INSTANT      0x03
#define TLT_TAG_ASYNC_BEGIN  0x04
#define TLT_TAG_ASYNC_END    0x05
#define TLT_TAG_COUNTER      0x06
#define TLT_TAG_METADATA     0x07
#define TLT_TAG_FLOW         0x08

/* ---- Event header flag bits ---- */

#define TLT_FLAG_HAS_CORRELATION  0x01
#define TLT_FLAG_DROPPED_MARKER   0x02

/* ---- Track kinds ---- */

#define TLT_TRACK_KIND_UNKNOWN   0
#define TLT_TRACK_KIND_ISOLATE   1
#define TLT_TRACK_KIND_C_THREAD  2
#define TLT_TRACK_KIND_PROCESS   3

/* ---- Region header (128 bytes, written once at create time) ---- */

typedef struct {
  uint32_t magic;                   /* TRACELITE_REGION_MAGIC */
  uint16_t format_major;
  uint16_t format_minor;
  uint64_t start_realtime_ns;       /* Unix ns at create time */
  uint64_t start_monotonic_ns;      /* monotonic ns at create time */
  uint32_t region_total_size;
  uint32_t producer_registry_offset;
  uint32_t string_pool_offset;
  uint32_t string_pool_size;
  uint32_t producer_ring_offset;
  uint32_t per_producer_ring_size;
  uint32_t max_producers;
  uint8_t  state;                   /* 0=active, 1=draining, 2=closed */
  uint8_t  endianness;              /* 1=LE, 2=BE */
  uint8_t  reserved1[2];            /* pad string_pool_head to offset 56 */
  /* Atomically-updated fields */
  volatile uint64_t string_pool_head;  /* current write offset within pool */
  volatile uint64_t total_events;       /* informational */
  volatile uint64_t total_dropped;
  uint8_t  reserved2[48];
} tlt_region_header_t;

/* Static-sized; matches the layout described in runtime-protocol.md §2 */
#ifdef __cplusplus
static_assert(sizeof(tlt_region_header_t) == 128, "region header size");
#else
_Static_assert(sizeof(tlt_region_header_t) == 128, "region header size");
#endif

/* ---- Producer registry slot (16 bytes; 256 slots = 4096 bytes) ---- */

typedef struct {
  volatile uint8_t state;     /* 0=empty, 1=claiming, 2=registered, 3=ended */
  uint8_t  kind;
  uint16_t reserved;
  uint32_t process_string_id;
  uint32_t thread_string_id;
  uint32_t metadata_string_id;
} tlt_registry_slot_t;

#ifdef __cplusplus
static_assert(sizeof(tlt_registry_slot_t) == 16, "registry slot size");
#else
_Static_assert(sizeof(tlt_registry_slot_t) == 16, "registry slot size");
#endif

/* ---- Per-producer ring header (64 bytes) ---- */

typedef struct {
  volatile uint64_t head;       /* counter; words written so far (producer-only writer) */
  volatile uint64_t tail;       /* counter; words drained (consumer-only writer) */
  volatile uint64_t dropped;    /* events dropped due to overflow */
  uint32_t size_words;          /* power of two */
  uint32_t mask;                /* size_words - 1 */
  volatile uint64_t last_write_ts;
  uint8_t  producer_state;      /* mirror of registry; for liveness */
  uint8_t  reserved1[7];
  uint8_t  reserved2[16];
} tlt_ring_header_t;

#ifdef __cplusplus
static_assert(sizeof(tlt_ring_header_t) == 64, "ring header size");
#else
_Static_assert(sizeof(tlt_ring_header_t) == 64, "ring header size");
#endif

/* ---- Producer-side API ---- */

/* Attach to the trace region named by env var TRACELITE_REGION (or NULL).
 * Returns 0 on success, -1 if the region is not present (in which case
 * tracing is silently disabled).
 */
int tlt_attach(const char* explicit_path);

/* Reserve a track ID and register this thread as a producer.
 * Returns track ID (0..255) or -1 on failure.
 */
int tlt_register_producer(uint8_t kind, const char* process_name, const char* thread_name);

/* Read the runtime monotonic clock (ns since trace start).
 * Producers MUST use this clock for all event timestamps.
 */
uint64_t tlt_now_ns(void);

/* Intern a string in the shared pool. Returns string_id (an offset into
 * the pool) on success, or 0xFFFFFFFF on overflow (the sentinel).
 */
uint32_t tlt_intern_string(const char* s, uint32_t len);

/* Write a BEGIN event with begin_args.
 * The args array length must match the span's begin_args schema.
 */
void tlt_begin(uint16_t span_id, const uint64_t* args, uint8_t arg_count);

/* Write an END event with end_args. */
void tlt_end(uint16_t span_id, const uint64_t* args, uint8_t arg_count);

/* Write an INSTANT event. */
void tlt_instant(uint16_t span_id, const uint64_t* args, uint8_t arg_count);

/* Correlated sync events. These use the same BEGIN/END/INSTANT tags as the
 * uncorrelated calls but carry a correlation ID word after the timestamp.
 */
void tlt_begin_correlated(uint16_t span_id, uint64_t correlation_id,
                          const uint64_t* args, uint8_t arg_count);
void tlt_end_correlated(uint16_t span_id, uint64_t correlation_id,
                        const uint64_t* args, uint8_t arg_count);
void tlt_instant_correlated(uint16_t span_id, uint64_t correlation_id,
                            const uint64_t* args, uint8_t arg_count);

/* Cross-track async span events paired by (span_id, correlation_id). */
void tlt_async_begin(uint16_t span_id, uint64_t correlation_id,
                     const uint64_t* args, uint8_t arg_count);
void tlt_async_end(uint16_t span_id, uint64_t correlation_id,
                   const uint64_t* args, uint8_t arg_count);

/* Explicit-track variants for logical producers whose event emission can move
 * across OS threads (notably Dart async continuations). These write to the
 * ring owned by track_id instead of the calling thread's TLS producer.
 */
void tlt_begin_on_track(uint8_t track_id, uint16_t span_id,
                        const uint64_t* args, uint8_t arg_count);
void tlt_end_on_track(uint8_t track_id, uint16_t span_id,
                      const uint64_t* args, uint8_t arg_count);
void tlt_instant_on_track(uint8_t track_id, uint16_t span_id,
                          const uint64_t* args, uint8_t arg_count);
void tlt_begin_correlated_on_track(uint8_t track_id, uint16_t span_id,
                                   uint64_t correlation_id,
                                   const uint64_t* args, uint8_t arg_count);
void tlt_end_correlated_on_track(uint8_t track_id, uint16_t span_id,
                                 uint64_t correlation_id,
                                 const uint64_t* args, uint8_t arg_count);
void tlt_instant_correlated_on_track(uint8_t track_id, uint16_t span_id,
                                     uint64_t correlation_id,
                                     const uint64_t* args, uint8_t arg_count);
void tlt_async_begin_on_track(uint8_t track_id, uint16_t span_id,
                              uint64_t correlation_id,
                              const uint64_t* args, uint8_t arg_count);
void tlt_async_end_on_track(uint8_t track_id, uint16_t span_id,
                            uint64_t correlation_id,
                            const uint64_t* args, uint8_t arg_count);

/* Numeric samples. The first arg is the sampled value. Additional args are
 * producer-defined dimensions.
 */
void tlt_counter(uint16_t span_id, int64_t value);
void tlt_counter_correlated(uint16_t span_id, uint64_t correlation_id,
                            int64_t value);
void tlt_counter_on_track(uint8_t track_id, uint16_t span_id, int64_t value);
void tlt_counter_correlated_on_track(uint8_t track_id, uint16_t span_id,
                                     uint64_t correlation_id, int64_t value);

/* Metadata events reuse span_id as metadata_kind. */
void tlt_metadata(uint16_t metadata_kind, const uint64_t* args,
                  uint8_t arg_count);
void tlt_metadata_on_track(uint8_t track_id, uint16_t metadata_kind,
                           const uint64_t* args, uint8_t arg_count);

/* Detach this producer (sets registry state to ended). */
void tlt_detach(void);
void tlt_detach_track(uint8_t track_id);

/* Whether tracing is currently active.
 * Producers wrap their record-call sites with `if (tlt_active())` so the
 * cost when not tracing is one byte-load + branch (~1 ns).
 */
extern volatile int tlt_active;

#ifdef __cplusplus
}
#endif

#endif /* TRACELITE_RUNTIME_H */
