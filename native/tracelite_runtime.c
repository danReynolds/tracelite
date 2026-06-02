#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

/*
 * tracelite — runtime implementation.
 *
 * Single source file containing the producer-side runtime: region
 * attach, producer registry, string pool, ring-buffer event append,
 * and clock primitive.
 *
 * Implementation notes:
 *
 *   - Each producer owns a private ring buffer (SPSC: producer is
 *     sole writer of head + data; consumer is sole writer of tail).
 *     No CAS on the event hot path; only memory barriers.
 *
 *   - Commit-head-last model: data words written first, header word
 *     written with release ordering, head advanced last. A consumer
 *     observing head > position is guaranteed to see a fully-written
 *     event at every position up to head.
 *
 *   - String pool uses a CAS loop that pre-checks capacity, never
 *     subtracts head on overflow.
 *
 *   - Producer registry uses 4-state machine (empty/claiming/
 *     registered/ended) to prevent partial-state visibility.
 *
 * See: doc/runtime-protocol.md
 */

#include "tracelite_runtime.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#endif

#if defined(_MSC_VER)
#define TLT_THREAD_LOCAL __declspec(thread)
#else
#define TLT_THREAD_LOCAL __thread
#endif

/* ---- Globals ---- */

volatile int tlt_active = 0;

#ifdef _WIN32
static HANDLE g_region_file = INVALID_HANDLE_VALUE;
static HANDLE g_region_mapping = NULL;
#else
static int g_region_fd = -1;
#endif
static void* g_region_base = NULL;
static size_t g_region_size = 0;
static tlt_region_header_t* g_region = NULL;
static tlt_registry_slot_t* g_registry = NULL;
static uint8_t* g_string_pool = NULL;
static uint8_t* g_ring_section = NULL;
static TLT_THREAD_LOCAL int tlt_my_track_id = -1;
static TLT_THREAD_LOCAL tlt_ring_header_t* tlt_my_ring = NULL;

static uint64_t g_start_monotonic_ns = 0;

/* Forward decls */
static uint64_t monotonic_ns(void);
static tlt_ring_header_t* ring_for_track(int track_id);
static int valid_track_id(int track_id);
static int has_active_tracks(void);
static void reset_mapping_state(void);

/* ---- Clock ---- */

static uint64_t monotonic_ns(void) {
#ifdef _WIN32
  LARGE_INTEGER counter;
  LARGE_INTEGER frequency;
  if (!QueryPerformanceCounter(&counter) ||
      !QueryPerformanceFrequency(&frequency) ||
      frequency.QuadPart <= 0) {
    return 0;
  }
  return (uint64_t)(((long double)counter.QuadPart * 1000000000.0L) /
                    (long double)frequency.QuadPart);
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#endif
}

uint64_t tlt_now_ns(void) {
  return monotonic_ns() - g_start_monotonic_ns;
}

/* ---- Attach ---- */

int tlt_attach(const char* explicit_path) {
  if (tlt_active) return 0;

  const char* path = explicit_path;
  if (!path) path = getenv("TRACELITE_REGION");
  if (!path) {
    /* No region; tracing is disabled. Not an error. */
    return -1;
  }

#ifdef _WIN32
  HANDLE file = CreateFileA(path, GENERIC_READ | GENERIC_WRITE,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (file == INVALID_HANDLE_VALUE) {
    fprintf(stderr, "tracelite: CreateFile(%s) failed\n", path);
    return -1;
  }

  LARGE_INTEGER file_size;
  if (!GetFileSizeEx(file, &file_size) || file_size.QuadPart <= 0) {
    CloseHandle(file);
    return -1;
  }

  HANDLE mapping = CreateFileMappingA(file, NULL, PAGE_READWRITE, 0, 0, NULL);
  if (!mapping) {
    CloseHandle(file);
    return -1;
  }

  size_t size = (size_t)file_size.QuadPart;
  void* base = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, 0);
  if (!base) {
    CloseHandle(mapping);
    CloseHandle(file);
    return -1;
  }
#else
  int fd = open(path, O_RDWR);
  if (fd < 0) {
    fprintf(stderr, "tracelite: open(%s) failed\n", path);
    return -1;
  }

  struct stat st;
  if (fstat(fd, &st) != 0) {
    close(fd);
    return -1;
  }
  size_t size = (size_t)st.st_size;

  void* base = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (base == MAP_FAILED) {
    close(fd);
    return -1;
  }
#endif

  tlt_region_header_t* header = (tlt_region_header_t*)base;
  if (header->magic != TRACELITE_REGION_MAGIC ||
      header->format_major != TRACELITE_FORMAT_MAJOR_RUNTIME) {
#ifdef _WIN32
    UnmapViewOfFile(base);
    CloseHandle(mapping);
    CloseHandle(file);
#else
    munmap(base, size);
    close(fd);
#endif
    return -1;
  }

#ifdef _WIN32
  g_region_file = file;
  g_region_mapping = mapping;
#else
  g_region_fd = fd;
#endif
  g_region_base = base;
  g_region_size = size;
  g_region = header;
  g_registry = (tlt_registry_slot_t*)((uint8_t*)base + header->producer_registry_offset);
  g_string_pool = (uint8_t*)base + header->string_pool_offset;
  g_ring_section = (uint8_t*)base + header->producer_ring_offset;
  g_start_monotonic_ns = header->start_monotonic_ns;
  tlt_active = 1;
  atexit(reset_mapping_state);
  return 0;
}

void tlt_detach(void) {
  if (tlt_my_track_id >= 0) {
    tlt_detach_track((uint8_t)tlt_my_track_id);
    tlt_my_track_id = -1;
    tlt_my_ring = NULL;
  }
}

static void reset_mapping_state(void) {
#ifdef _WIN32
  if (g_region_base) UnmapViewOfFile(g_region_base);
  if (g_region_mapping) CloseHandle(g_region_mapping);
  if (g_region_file != INVALID_HANDLE_VALUE) CloseHandle(g_region_file);
  g_region_file = INVALID_HANDLE_VALUE;
  g_region_mapping = NULL;
#else
  if (g_region_base && g_region_size > 0) munmap(g_region_base, g_region_size);
  if (g_region_fd >= 0) close(g_region_fd);
  g_region_fd = -1;
#endif
  g_region_base = NULL;
  g_region_size = 0;
  g_region = NULL;
  g_registry = NULL;
  g_string_pool = NULL;
  g_ring_section = NULL;
  g_start_monotonic_ns = 0;
  tlt_my_track_id = -1;
  tlt_my_ring = NULL;
  tlt_active = 0;
}

void tlt_detach_track(uint8_t track_id) {
  if (!tlt_active || !valid_track_id(track_id)) return;
  g_registry[track_id].state = 3;  /* ended */
  ring_for_track(track_id)->producer_state = 3;
  if (!has_active_tracks()) {
    reset_mapping_state();
  }
}

/* ---- Producer registry ---- */

int tlt_register_producer(uint8_t kind, const char* process_name, const char* thread_name) {
  if (!tlt_active) return -1;

  /* Find an empty slot via CAS. */
  uint32_t max = g_region->max_producers;
  int slot = -1;
  for (uint32_t i = 0; i < max; i++) {
    uint8_t expected = 0;  /* empty */
    if (atomic_compare_exchange_strong((_Atomic(uint8_t)*)&g_registry[i].state,
                                        &expected, 1 /* claiming */)) {
      slot = (int)i;
      break;
    }
  }
  if (slot < 0) return -1;

  /* Fill in metadata. */
  uint32_t proc_id = process_name ? tlt_intern_string(process_name, (uint32_t)strlen(process_name)) : 0xFFFFFFFFu;
  uint32_t thread_id = thread_name ? tlt_intern_string(thread_name, (uint32_t)strlen(thread_name)) : 0xFFFFFFFFu;

  g_registry[slot].kind = kind;
  g_registry[slot].process_string_id = proc_id;
  g_registry[slot].thread_string_id = thread_id;
  g_registry[slot].metadata_string_id = 0xFFFFFFFFu;

  /* Publish: empty -> claiming -> registered (release so a reader
   * doing acquire-load on state sees the metadata writes above). */
  atomic_store_explicit((_Atomic(uint8_t)*)&g_registry[slot].state, 2,
                        memory_order_release);

  tlt_my_track_id = slot;
  tlt_my_ring = ring_for_track(slot);
  return slot;
}

static tlt_ring_header_t* ring_for_track(int track_id) {
  size_t per = g_region->per_producer_ring_size;
  return (tlt_ring_header_t*)(g_ring_section + (size_t)track_id * per);
}

static int valid_track_id(int track_id) {
  return g_region && track_id >= 0 && (uint32_t)track_id < g_region->max_producers;
}

static int has_active_tracks(void) {
  if (!g_region || !g_registry) return 0;
  uint32_t max = g_region->max_producers;
  for (uint32_t i = 0; i < max; i++) {
    uint8_t state = atomic_load_explicit(
        (_Atomic(uint8_t)*)&g_registry[i].state,
        memory_order_acquire);
    if (state == 1 || state == 2) return 1;
  }
  return 0;
}

/* ---- String pool (CAS allocator) ---- */

uint32_t tlt_intern_string(const char* s, uint32_t len) {
  if (!tlt_active) return 0xFFFFFFFFu;
  uint32_t needed = 4 + len;
  uint32_t pool_size = g_region->string_pool_size;

  /* CAS loop: read head, check capacity, attempt to publish. */
  uint64_t cur, next;
  do {
    cur = atomic_load_explicit((_Atomic(uint64_t)*)&g_region->string_pool_head,
                                memory_order_acquire);
    if (cur + needed > pool_size) {
      return 0xFFFFFFFFu;  /* overflow sentinel */
    }
    next = cur + needed;
  } while (!atomic_compare_exchange_weak_explicit(
      (_Atomic(uint64_t)*)&g_region->string_pool_head,
      &cur, next,
      memory_order_acq_rel, memory_order_acquire));

  /* We own bytes [cur, next). Write length + content. */
  uint32_t* len_slot = (uint32_t*)(g_string_pool + cur);
  *len_slot = len;
  memcpy(g_string_pool + cur + 4, s, len);
  return (uint32_t)cur;
}

/* ---- Event append ---- */

static inline uint64_t pack_header(uint8_t tag, uint8_t track_id, uint16_t span_id,
                                    uint8_t arg_count, uint8_t flags) {
  return ((uint64_t)tag       << 56) |
         ((uint64_t)track_id  << 48) |
         ((uint64_t)span_id   << 32) |
         ((uint64_t)arg_count << 24) |
         ((uint64_t)flags     << 16);
}

static void write_event_with_correlation_on_track_id(uint8_t track_id,
                         uint8_t tag, uint16_t span_id,
                         uint64_t correlation_id, int has_correlation,
                         const uint64_t* args, uint8_t arg_count) {
  if (!tlt_active || !valid_track_id(track_id)) return;
  if (g_registry[track_id].state < 2) return;

  tlt_ring_header_t* r = ring_for_track(track_id);
  uint64_t* data = (uint64_t*)((uint8_t*)r + sizeof(tlt_ring_header_t));

  uint32_t needed = 2 + (has_correlation ? 1u : 0u) + (uint32_t)arg_count;

  /* Snapshot tail under acquire to pair with consumer's release-store. */
  uint64_t tail = atomic_load_explicit((_Atomic(uint64_t)*)&r->tail,
                                        memory_order_acquire);
  uint64_t head = atomic_load_explicit((_Atomic(uint64_t)*)&r->head,
                                        memory_order_relaxed);

  if ((head + needed) > tail + (uint64_t)r->size_words) {
    /* Drop newest. */
    atomic_fetch_add_explicit((_Atomic(uint64_t)*)&r->dropped, 1,
                              memory_order_relaxed);
    atomic_fetch_add_explicit((_Atomic(uint64_t)*)&g_region->total_dropped, 1,
                              memory_order_relaxed);
    return;
  }

  uint64_t now = tlt_now_ns();

  /* Write data words first. Producer is sole writer of head, so
   * relaxed ordering suffices here. The release on the head store
   * below establishes the happens-before for the consumer. */
  uint32_t mask = r->mask;
  uint32_t i = (uint32_t)(head & mask);

  /* Header at slot 0 (write last, with release). */
  /* Timestamp at slot 1. */
  data[(i + 1) & mask] = now;
  uint32_t args_offset = 2;
  if (has_correlation) {
    data[(i + 2) & mask] = correlation_id;
    args_offset = 3;
  }
  /* Args at slots 2..2+n, or 3..3+n when correlation is present. */
  for (uint8_t k = 0; k < arg_count; k++) {
    data[(i + args_offset + k) & mask] = args[k];
  }

  /* Commit: write header with release ordering, then advance head. */
  uint8_t flags = has_correlation ? TLT_FLAG_HAS_CORRELATION : 0;
  uint64_t header = pack_header(tag, track_id, span_id,
                                 arg_count, flags);
  atomic_store_explicit((_Atomic(uint64_t)*)&data[i], header,
                        memory_order_release);
  atomic_store_explicit((_Atomic(uint64_t)*)&r->head, head + needed,
                        memory_order_release);

  r->last_write_ts = now;
  atomic_fetch_add_explicit((_Atomic(uint64_t)*)&g_region->total_events, 1,
                            memory_order_relaxed);
}

static void write_event_with_correlation(uint8_t tag, uint16_t span_id,
                         uint64_t correlation_id, int has_correlation,
                         const uint64_t* args, uint8_t arg_count) {
  if (tlt_my_track_id < 0) return;
  write_event_with_correlation_on_track_id((uint8_t)tlt_my_track_id, tag,
                                           span_id, correlation_id,
                                           has_correlation, args, arg_count);
}

static void write_event(uint8_t tag, uint16_t span_id,
                         const uint64_t* args, uint8_t arg_count) {
  write_event_with_correlation(tag, span_id, 0, 0, args, arg_count);
}

void tlt_begin(uint16_t span_id, const uint64_t* args, uint8_t arg_count) {
  write_event(TLT_TAG_BEGIN, span_id, args, arg_count);
}

void tlt_end(uint16_t span_id, const uint64_t* args, uint8_t arg_count) {
  write_event(TLT_TAG_END, span_id, args, arg_count);
}

void tlt_instant(uint16_t span_id, const uint64_t* args, uint8_t arg_count) {
  write_event(TLT_TAG_INSTANT, span_id, args, arg_count);
}

void tlt_begin_correlated(uint16_t span_id, uint64_t correlation_id,
                          const uint64_t* args, uint8_t arg_count) {
  write_event_with_correlation(TLT_TAG_BEGIN, span_id, correlation_id, 1,
                               args, arg_count);
}

void tlt_end_correlated(uint16_t span_id, uint64_t correlation_id,
                        const uint64_t* args, uint8_t arg_count) {
  write_event_with_correlation(TLT_TAG_END, span_id, correlation_id, 1,
                               args, arg_count);
}

void tlt_instant_correlated(uint16_t span_id, uint64_t correlation_id,
                            const uint64_t* args, uint8_t arg_count) {
  write_event_with_correlation(TLT_TAG_INSTANT, span_id, correlation_id, 1,
                               args, arg_count);
}

void tlt_async_begin(uint16_t span_id, uint64_t correlation_id,
                     const uint64_t* args, uint8_t arg_count) {
  write_event_with_correlation(TLT_TAG_ASYNC_BEGIN, span_id, correlation_id, 1,
                               args, arg_count);
}

void tlt_async_end(uint16_t span_id, uint64_t correlation_id,
                   const uint64_t* args, uint8_t arg_count) {
  write_event_with_correlation(TLT_TAG_ASYNC_END, span_id, correlation_id, 1,
                               args, arg_count);
}

void tlt_begin_on_track(uint8_t track_id, uint16_t span_id,
                        const uint64_t* args, uint8_t arg_count) {
  write_event_with_correlation_on_track_id(track_id, TLT_TAG_BEGIN, span_id, 0,
                                           0, args, arg_count);
}

void tlt_end_on_track(uint8_t track_id, uint16_t span_id,
                      const uint64_t* args, uint8_t arg_count) {
  write_event_with_correlation_on_track_id(track_id, TLT_TAG_END, span_id, 0,
                                           0, args, arg_count);
}

void tlt_instant_on_track(uint8_t track_id, uint16_t span_id,
                          const uint64_t* args, uint8_t arg_count) {
  write_event_with_correlation_on_track_id(track_id, TLT_TAG_INSTANT, span_id,
                                           0, 0, args, arg_count);
}

void tlt_begin_correlated_on_track(uint8_t track_id, uint16_t span_id,
                                   uint64_t correlation_id,
                                   const uint64_t* args, uint8_t arg_count) {
  write_event_with_correlation_on_track_id(track_id, TLT_TAG_BEGIN, span_id,
                                           correlation_id, 1, args, arg_count);
}

void tlt_end_correlated_on_track(uint8_t track_id, uint16_t span_id,
                                 uint64_t correlation_id,
                                 const uint64_t* args, uint8_t arg_count) {
  write_event_with_correlation_on_track_id(track_id, TLT_TAG_END, span_id,
                                           correlation_id, 1, args, arg_count);
}

void tlt_instant_correlated_on_track(uint8_t track_id, uint16_t span_id,
                                     uint64_t correlation_id,
                                     const uint64_t* args, uint8_t arg_count) {
  write_event_with_correlation_on_track_id(track_id, TLT_TAG_INSTANT, span_id,
                                           correlation_id, 1, args, arg_count);
}

void tlt_async_begin_on_track(uint8_t track_id, uint16_t span_id,
                              uint64_t correlation_id,
                              const uint64_t* args, uint8_t arg_count) {
  write_event_with_correlation_on_track_id(track_id, TLT_TAG_ASYNC_BEGIN,
                                           span_id, correlation_id, 1, args,
                                           arg_count);
}

void tlt_async_end_on_track(uint8_t track_id, uint16_t span_id,
                            uint64_t correlation_id,
                            const uint64_t* args, uint8_t arg_count) {
  write_event_with_correlation_on_track_id(track_id, TLT_TAG_ASYNC_END,
                                           span_id, correlation_id, 1, args,
                                           arg_count);
}

void tlt_counter(uint16_t span_id, int64_t value) {
  uint64_t args[1] = { (uint64_t)value };
  write_event(TLT_TAG_COUNTER, span_id, args, 1);
}

void tlt_counter_correlated(uint16_t span_id, uint64_t correlation_id,
                            int64_t value) {
  uint64_t args[1] = { (uint64_t)value };
  write_event_with_correlation(TLT_TAG_COUNTER, span_id, correlation_id, 1,
                               args, 1);
}

void tlt_counter_on_track(uint8_t track_id, uint16_t span_id, int64_t value) {
  uint64_t args[1] = { (uint64_t)value };
  write_event_with_correlation_on_track_id(track_id, TLT_TAG_COUNTER, span_id,
                                           0, 0, args, 1);
}

void tlt_counter_correlated_on_track(uint8_t track_id, uint16_t span_id,
                                     uint64_t correlation_id, int64_t value) {
  uint64_t args[1] = { (uint64_t)value };
  write_event_with_correlation_on_track_id(track_id, TLT_TAG_COUNTER, span_id,
                                           correlation_id, 1, args, 1);
}

void tlt_metadata(uint16_t metadata_kind, const uint64_t* args,
                  uint8_t arg_count) {
  write_event(TLT_TAG_METADATA, metadata_kind, args, arg_count);
}

void tlt_metadata_on_track(uint8_t track_id, uint16_t metadata_kind,
                           const uint64_t* args, uint8_t arg_count) {
  write_event_with_correlation_on_track_id(track_id, TLT_TAG_METADATA,
                                           metadata_kind, 0, 0, args,
                                           arg_count);
}
