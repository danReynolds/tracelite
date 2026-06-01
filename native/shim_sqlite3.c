/*
 * shim_sqlite3.c — tracelite's libsqlite3 ABI shim.
 *
 * Goal: expose the full libsqlite3 ABI to clients (drift, sqlite_async,
 * package:sqlite3, …) while wrapping the calls we trace with timing.
 *
 * Approach (macOS / Linux):
 *   - The shim dlopen's the real libsqlite3 at first use.
 *   - For each *wrapped* function: define our own symbol; the body
 *     resolves the real implementation via cached dlsym() and times the
 *     call.
 *   - For *unwrapped* functions: rely on the platform link strategy so
 *     untraced symbols are still resolvable from this shim's handle
 *     (re-export on macOS, libsqlite3 dependency lookup on Linux).
 *
 * Embedded mode:
 *   - Defining TRACELITE_SQLITE3_EMBEDDED builds the same wrappers into a
 *     library that also contains SQLite itself. The SQLite amalgamation must
 *     be compiled with wrapped public symbols renamed to tlt_sqlite3_*.
 *   - In that mode wrappers resolve tlt_sqlite3_* via RTLD_DEFAULT instead
 *     of resolving the next libsqlite3 image.
 *
 * Build (macOS):
 *   cc -dynamiclib -flat_namespace ... -o libsqlite_traced.dylib
 *      -reexport_library /usr/lib/libsqlite3.tbd  (or similar)
 *
 * Build (Linux):
 *   gcc -shared -fPIC ... -o libsqlite_traced.so
 *       -Wl,--no-as-needed -lsqlite3
 *
 * Loading from Dart:
 *   package:sqlite3 native hooks can be configured with
 *   `source: system, name: sqlite_traced`, and this repo copies the shim
 *   to the platform resolver name (`libsqlite_traced.dylib` on macOS or
 *   `libsqlite_traced.so` on Linux) before traced peer runs.
 */

#include "tracelite_runtime.h"
#include "builtin_spans.g.h"

#include <dlfcn.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ---------------------------------------------------------------------------
 * Real libsqlite3 symbol resolver.
 *
 * Our shim is linked with `-Wl,-reexport-lsqlite3`, so libsqlite3's
 * symbols are reachable from this dylib. To call the real symbol from
 * within our wrapper (without recursing into ourselves), we use
 * `dlsym(RTLD_NEXT, ...)` which searches subsequently-loaded libraries
 * — the reexported libsqlite3 is among them.
 *
 * Resolution is cached per-symbol via a static pointer, so the first
 * call pays for `dlsym` (~tens of ns) and subsequent calls just load
 * the cached pointer.
 * ------------------------------------------------------------------------- */

#ifdef TRACELITE_SQLITE3_EMBEDDED
#define REAL_SYMBOL_NAME(SYM) "tlt_" #SYM
#define REAL_SYMBOL_SCOPE RTLD_DEFAULT
#define TRACELITE_SQLITE_PRODUCER_NAME "libresqlite"
#else
#define REAL_SYMBOL_NAME(SYM) #SYM
#define REAL_SYMBOL_SCOPE RTLD_NEXT
#define TRACELITE_SQLITE_PRODUCER_NAME "libsqlite_traced"
#endif

#define RESOLVE_REAL(SYM, TYPE)                                             \
  static TYPE _real = NULL;                                                 \
  if (!_real) {                                                             \
    _real = (TYPE)dlsym(REAL_SYMBOL_SCOPE, REAL_SYMBOL_NAME(SYM));          \
    if (!_real) {                                                           \
      fprintf(stderr,                                                       \
              "tracelite shim: dlsym(\"%s\") failed: %s\n",                \
              REAL_SYMBOL_NAME(SYM), dlerror());                            \
    }                                                                       \
  }

/* ---------------------------------------------------------------------------
 * Self-attach to TRACELITE_REGION on first call.
 * ------------------------------------------------------------------------- */

static __thread int tracelite_thread_inited = 0;

static void ensure_attached(void) {
  if (tracelite_thread_inited) return;
  tracelite_thread_inited = 1;
  if (!tlt_active) {
    tlt_attach(NULL);
  }
  if (tlt_active) {
    tlt_register_producer(TLT_TRACK_KIND_C_THREAD,
                           TRACELITE_SQLITE_PRODUCER_NAME, "main");
  }
}

/* ---------------------------------------------------------------------------
 * Wrapped functions.
 *
 * Note: opaque pointer types (sqlite3*, sqlite3_stmt*) aren't dereferenced
 * here; we just forward them. We use void* as their type since we don't
 * need the real sqlite3.h to forward-declare structs.
 * ------------------------------------------------------------------------- */

/* Forward declare types as opaque pointers, matching the SQLite ABI. */
typedef void sqlite3;
typedef void sqlite3_stmt;

static uint64_t pack_f64(double value) {
  uint64_t bits = 0;
  memcpy(&bits, &value, sizeof(bits));
  return bits;
}

/* sqlite3_open(filename, ppDb) */
typedef int (*open_t)(const char*, sqlite3**);
int sqlite3_open(const char* filename, sqlite3** ppDb) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_open, open_t);
  if (!_real) return -1;

  uint32_t filename_id = filename
      ? tlt_intern_string(filename, (uint32_t)strlen(filename))
      : 0xFFFFFFFFu;
  uint64_t begin_args[1] = { filename_id };
  tlt_begin(SPAN_SQLITE3_OPEN, begin_args, 1);
  int rc = _real(filename, ppDb);
  uint64_t end_args[2] = {
      ppDb ? (uint64_t)(uintptr_t)*ppDb : 0,
      (uint64_t)(uint32_t)rc,
  };
  tlt_end(SPAN_SQLITE3_OPEN, end_args, 2);
  return rc;
}

/* sqlite3_open_v2(filename, ppDb, flags, vfs) */
typedef int (*open_v2_t)(const char*, sqlite3**, int, const char*);
int sqlite3_open_v2(const char* filename, sqlite3** ppDb, int flags,
                    const char* vfs) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_open_v2, open_v2_t);
  if (!_real) return -1;

  uint32_t filename_id = filename
      ? tlt_intern_string(filename, (uint32_t)strlen(filename))
      : 0xFFFFFFFFu;
  uint32_t vfs_id = vfs ? tlt_intern_string(vfs, (uint32_t)strlen(vfs)) : 0xFFFFFFFFu;
  uint64_t begin_args[3] = { filename_id, (uint64_t)(uint32_t)flags, vfs_id };
  tlt_begin(SPAN_SQLITE3_OPEN_V2, begin_args, 3);
  int rc = _real(filename, ppDb, flags, vfs);
  uint64_t end_args[2] = {
      ppDb ? (uint64_t)(uintptr_t)*ppDb : 0,
      (uint64_t)(uint32_t)rc,
  };
  tlt_end(SPAN_SQLITE3_OPEN_V2, end_args, 2);
  return rc;
}

/* sqlite3_close / sqlite3_close_v2 */
typedef int (*close_t)(sqlite3*);
int sqlite3_close(sqlite3* db) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_close, close_t);
  if (!_real) return -1;

  uint64_t begin_args[1] = { (uint64_t)(uintptr_t)db };
  tlt_begin(SPAN_SQLITE3_CLOSE, begin_args, 1);
  int rc = _real(db);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)rc };
  tlt_end(SPAN_SQLITE3_CLOSE, end_args, 1);
  return rc;
}

int sqlite3_close_v2(sqlite3* db) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_close_v2, close_t);
  if (!_real) return -1;

  uint64_t begin_args[1] = { (uint64_t)(uintptr_t)db };
  tlt_begin(SPAN_SQLITE3_CLOSE_V2, begin_args, 1);
  int rc = _real(db);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)rc };
  tlt_end(SPAN_SQLITE3_CLOSE_V2, end_args, 1);
  return rc;
}

/* sqlite3_prepare_v3(db, zSql, nByte, prepFlags, ppStmt, pzTail) */
typedef int (*prepare_v3_t)(sqlite3*, const char*, int, unsigned int,
                             sqlite3_stmt**, const char**);
int sqlite3_prepare_v3(sqlite3* db, const char* zSql, int nByte,
                        unsigned int prepFlags, sqlite3_stmt** ppStmt,
                        const char** pzTail) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_prepare_v3, prepare_v3_t);
  if (!_real) return -1;

  uint32_t sql_id = 0xFFFFFFFFu;
  if (zSql) {
    int len = nByte < 0 ? (int)strlen(zSql) : nByte;
    sql_id = tlt_intern_string(zSql, (uint32_t)len);
  }

  uint64_t begin_args[3] = { (uint64_t)(uintptr_t)db, sql_id, prepFlags };
  tlt_begin(SPAN_SQLITE3_PREPARE_V3, begin_args, 3);
  int rc = _real(db, zSql, nByte, prepFlags, ppStmt, pzTail);
  uint64_t end_args[2] = {
      ppStmt ? (uint64_t)(uintptr_t)*ppStmt : 0,
      (uint64_t)(uint32_t)rc,
  };
  tlt_end(SPAN_SQLITE3_PREPARE_V3, end_args, 2);
  return rc;
}

/* sqlite3_prepare_v2(db, zSql, nByte, ppStmt, pzTail) */
typedef int (*prepare_v2_t)(sqlite3*, const char*, int, sqlite3_stmt**,
                             const char**);
int sqlite3_prepare_v2(sqlite3* db, const char* zSql, int nByte,
                        sqlite3_stmt** ppStmt, const char** pzTail) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_prepare_v2, prepare_v2_t);
  if (!_real) return -1;

  uint32_t sql_id = 0xFFFFFFFFu;
  if (zSql) {
    int len = nByte < 0 ? (int)strlen(zSql) : nByte;
    sql_id = tlt_intern_string(zSql, (uint32_t)len);
  }
  uint64_t begin_args[2] = { (uint64_t)(uintptr_t)db, sql_id };
  tlt_begin(SPAN_SQLITE3_PREPARE_V2, begin_args, 2);
  int rc = _real(db, zSql, nByte, ppStmt, pzTail);
  uint64_t end_args[2] = {
      ppStmt ? (uint64_t)(uintptr_t)*ppStmt : 0,
      (uint64_t)(uint32_t)rc,
  };
  tlt_end(SPAN_SQLITE3_PREPARE_V2, end_args, 2);
  return rc;
}

/* sqlite3_step(stmt) */
typedef int (*step_t)(sqlite3_stmt*);
int sqlite3_step(sqlite3_stmt* stmt) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_step, step_t);
  if (!_real) return -1;

  uint64_t begin_args[1] = { (uint64_t)(uintptr_t)stmt };
  tlt_begin(SPAN_SQLITE3_STEP, begin_args, 1);
  int rc = _real(stmt);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)rc };
  tlt_end(SPAN_SQLITE3_STEP, end_args, 1);
  return rc;
}

/* sqlite3_reset(stmt) */
typedef int (*reset_t)(sqlite3_stmt*);
int sqlite3_reset(sqlite3_stmt* stmt) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_reset, reset_t);
  if (!_real) return -1;

  uint64_t begin_args[1] = { (uint64_t)(uintptr_t)stmt };
  tlt_begin(SPAN_SQLITE3_RESET, begin_args, 1);
  int rc = _real(stmt);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)rc };
  tlt_end(SPAN_SQLITE3_RESET, end_args, 1);
  return rc;
}

/* sqlite3_finalize(stmt) */
typedef int (*finalize_t)(sqlite3_stmt*);
int sqlite3_finalize(sqlite3_stmt* stmt) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_finalize, finalize_t);
  if (!_real) return -1;

  uint64_t begin_args[1] = { (uint64_t)(uintptr_t)stmt };
  tlt_begin(SPAN_SQLITE3_FINALIZE, begin_args, 1);
  int rc = _real(stmt);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)rc };
  tlt_end(SPAN_SQLITE3_FINALIZE, end_args, 1);
  return rc;
}

/* sqlite3_bind_int64(stmt, idx, value) */
typedef int (*bind_int64_t)(sqlite3_stmt*, int, long long);
int sqlite3_bind_int64(sqlite3_stmt* stmt, int idx, long long value) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_bind_int64, bind_int64_t);
  if (!_real) return -1;

  uint64_t begin_args[3] = { (uint64_t)(uintptr_t)stmt, (uint64_t)(uint32_t)idx,
                              (uint64_t)value };
  tlt_begin(SPAN_SQLITE3_BIND_INT64, begin_args, 3);
  int rc = _real(stmt, idx, value);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)rc };
  tlt_end(SPAN_SQLITE3_BIND_INT64, end_args, 1);
  return rc;
}

/* sqlite3_bind_int(stmt, idx, value) */
typedef int (*bind_int_t)(sqlite3_stmt*, int, int);
int sqlite3_bind_int(sqlite3_stmt* stmt, int idx, int value) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_bind_int, bind_int_t);
  if (!_real) return -1;

  uint64_t begin_args[3] = { (uint64_t)(uintptr_t)stmt, (uint64_t)(uint32_t)idx,
                              (uint64_t)(int64_t)value };
  tlt_begin(SPAN_SQLITE3_BIND_INT, begin_args, 3);
  int rc = _real(stmt, idx, value);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)rc };
  tlt_end(SPAN_SQLITE3_BIND_INT, end_args, 1);
  return rc;
}

/* sqlite3_bind_null(stmt, idx) */
typedef int (*bind_null_t)(sqlite3_stmt*, int);
int sqlite3_bind_null(sqlite3_stmt* stmt, int idx) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_bind_null, bind_null_t);
  if (!_real) return -1;

  uint64_t begin_args[2] = { (uint64_t)(uintptr_t)stmt, (uint64_t)(uint32_t)idx };
  tlt_begin(SPAN_SQLITE3_BIND_NULL, begin_args, 2);
  int rc = _real(stmt, idx);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)rc };
  tlt_end(SPAN_SQLITE3_BIND_NULL, end_args, 1);
  return rc;
}

/* sqlite3_bind_double(stmt, idx, value) */
typedef int (*bind_double_t)(sqlite3_stmt*, int, double);
int sqlite3_bind_double(sqlite3_stmt* stmt, int idx, double value) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_bind_double, bind_double_t);
  if (!_real) return -1;

  uint64_t begin_args[3] = { (uint64_t)(uintptr_t)stmt, (uint64_t)(uint32_t)idx,
                              pack_f64(value) };
  tlt_begin(SPAN_SQLITE3_BIND_DOUBLE, begin_args, 3);
  int rc = _real(stmt, idx, value);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)rc };
  tlt_end(SPAN_SQLITE3_BIND_DOUBLE, end_args, 1);
  return rc;
}

/* sqlite3_bind_text(stmt, idx, text, nByte, destructor) */
typedef int (*bind_text_t)(sqlite3_stmt*, int, const char*, int, void*);
int sqlite3_bind_text(sqlite3_stmt* stmt, int idx, const char* text,
                       int nByte, void* destructor) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_bind_text, bind_text_t);
  if (!_real) return -1;

  int len = nByte < 0 && text ? (int)strlen(text) : (nByte < 0 ? 0 : nByte);
  uint64_t begin_args[3] = { (uint64_t)(uintptr_t)stmt, (uint64_t)(uint32_t)idx,
                              (uint64_t)len };
  tlt_begin(SPAN_SQLITE3_BIND_TEXT, begin_args, 3);
  int rc = _real(stmt, idx, text, nByte, destructor);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)rc };
  tlt_end(SPAN_SQLITE3_BIND_TEXT, end_args, 1);
  return rc;
}

/* sqlite3_bind_blob / sqlite3_bind_blob64 */
typedef int (*bind_blob_t)(sqlite3_stmt*, int, const void*, int, void*);
int sqlite3_bind_blob(sqlite3_stmt* stmt, int idx, const void* blob,
                       int nByte, void* destructor) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_bind_blob, bind_blob_t);
  if (!_real) return -1;

  uint64_t begin_args[3] = { (uint64_t)(uintptr_t)stmt, (uint64_t)(uint32_t)idx,
                              (uint64_t)(uint32_t)(nByte < 0 ? 0 : nByte) };
  tlt_begin(SPAN_SQLITE3_BIND_BLOB, begin_args, 3);
  int rc = _real(stmt, idx, blob, nByte, destructor);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)rc };
  tlt_end(SPAN_SQLITE3_BIND_BLOB, end_args, 1);
  return rc;
}

typedef int (*bind_blob64_t)(sqlite3_stmt*, int, const void*, uint64_t, void*);
int sqlite3_bind_blob64(sqlite3_stmt* stmt, int idx, const void* blob,
                         uint64_t nByte, void* destructor) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_bind_blob64, bind_blob64_t);
  if (!_real) return -1;

  uint64_t begin_args[3] = { (uint64_t)(uintptr_t)stmt, (uint64_t)(uint32_t)idx,
                              nByte };
  tlt_begin(SPAN_SQLITE3_BIND_BLOB, begin_args, 3);
  int rc = _real(stmt, idx, blob, nByte, destructor);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)rc };
  tlt_end(SPAN_SQLITE3_BIND_BLOB, end_args, 1);
  return rc;
}

/* sqlite3_clear_bindings(stmt) */
typedef int (*clear_bindings_t)(sqlite3_stmt*);
int sqlite3_clear_bindings(sqlite3_stmt* stmt) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_clear_bindings, clear_bindings_t);
  if (!_real) return -1;

  uint64_t begin_args[1] = { (uint64_t)(uintptr_t)stmt };
  tlt_begin(SPAN_SQLITE3_CLEAR_BINDINGS, begin_args, 1);
  int rc = _real(stmt);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)rc };
  tlt_end(SPAN_SQLITE3_CLEAR_BINDINGS, end_args, 1);
  return rc;
}

/* Column accessors */
typedef int (*column_count_t)(sqlite3_stmt*);
int sqlite3_column_count(sqlite3_stmt* stmt) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_column_count, column_count_t);
  if (!_real) return 0;

  uint64_t begin_args[1] = { (uint64_t)(uintptr_t)stmt };
  tlt_begin(SPAN_SQLITE3_COLUMN_COUNT, begin_args, 1);
  int result = _real(stmt);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)result };
  tlt_end(SPAN_SQLITE3_COLUMN_COUNT, end_args, 1);
  return result;
}

typedef int (*column_int_t)(sqlite3_stmt*, int);
int sqlite3_column_int(sqlite3_stmt* stmt, int idx) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_column_int, column_int_t);
  if (!_real) return 0;

  uint64_t begin_args[2] = { (uint64_t)(uintptr_t)stmt, (uint64_t)(uint32_t)idx };
  tlt_begin(SPAN_SQLITE3_COLUMN_INT, begin_args, 2);
  int result = _real(stmt, idx);
  uint64_t end_args[1] = { (uint64_t)(int64_t)result };
  tlt_end(SPAN_SQLITE3_COLUMN_INT, end_args, 1);
  return result;
}

typedef long long (*column_int64_t)(sqlite3_stmt*, int);
long long sqlite3_column_int64(sqlite3_stmt* stmt, int idx) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_column_int64, column_int64_t);
  if (!_real) return 0;

  uint64_t begin_args[2] = { (uint64_t)(uintptr_t)stmt, (uint64_t)(uint32_t)idx };
  tlt_begin(SPAN_SQLITE3_COLUMN_INT64, begin_args, 2);
  long long result = _real(stmt, idx);
  uint64_t end_args[1] = { (uint64_t)result };
  tlt_end(SPAN_SQLITE3_COLUMN_INT64, end_args, 1);
  return result;
}

typedef double (*column_double_t)(sqlite3_stmt*, int);
double sqlite3_column_double(sqlite3_stmt* stmt, int idx) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_column_double, column_double_t);
  if (!_real) return 0.0;

  uint64_t begin_args[2] = { (uint64_t)(uintptr_t)stmt, (uint64_t)(uint32_t)idx };
  tlt_begin(SPAN_SQLITE3_COLUMN_DOUBLE, begin_args, 2);
  double result = _real(stmt, idx);
  uint64_t end_args[1] = { pack_f64(result) };
  tlt_end(SPAN_SQLITE3_COLUMN_DOUBLE, end_args, 1);
  return result;
}

typedef const unsigned char* (*column_text_t)(sqlite3_stmt*, int);
const unsigned char* sqlite3_column_text(sqlite3_stmt* stmt, int idx) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_column_text, column_text_t);
  if (!_real) return NULL;

  uint64_t begin_args[2] = { (uint64_t)(uintptr_t)stmt, (uint64_t)(uint32_t)idx };
  tlt_begin(SPAN_SQLITE3_COLUMN_TEXT, begin_args, 2);
  const unsigned char* result = _real(stmt, idx);
  uint64_t len = result ? (uint64_t)strlen((const char*)result) : 0;
  uint64_t end_args[1] = { len };
  tlt_end(SPAN_SQLITE3_COLUMN_TEXT, end_args, 1);
  return result;
}

typedef const void* (*column_blob_t)(sqlite3_stmt*, int);
const void* sqlite3_column_blob(sqlite3_stmt* stmt, int idx) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_column_blob, column_blob_t);
  if (!_real) return NULL;

  uint64_t begin_args[2] = { (uint64_t)(uintptr_t)stmt, (uint64_t)(uint32_t)idx };
  tlt_begin(SPAN_SQLITE3_COLUMN_BLOB, begin_args, 2);
  const void* result = _real(stmt, idx);
  uint64_t end_args[1] = { result ? 1u : 0u };
  tlt_end(SPAN_SQLITE3_COLUMN_BLOB, end_args, 1);
  return result;
}

typedef int (*column_bytes_t)(sqlite3_stmt*, int);
int sqlite3_column_bytes(sqlite3_stmt* stmt, int idx) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_column_bytes, column_bytes_t);
  if (!_real) return 0;

  uint64_t begin_args[2] = { (uint64_t)(uintptr_t)stmt, (uint64_t)(uint32_t)idx };
  tlt_begin(SPAN_SQLITE3_COLUMN_BYTES, begin_args, 2);
  int result = _real(stmt, idx);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)result };
  tlt_end(SPAN_SQLITE3_COLUMN_BYTES, end_args, 1);
  return result;
}

/* sqlite3_exec(db, sql, callback, ctx, errmsg) */
typedef int (*exec_t)(sqlite3*, const char*, void*, void*, char**);
int sqlite3_exec(sqlite3* db, const char* sql, void* callback, void* ctx,
                  char** errmsg) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_exec, exec_t);
  if (!_real) return -1;

  uint32_t sql_id = sql ? tlt_intern_string(sql, (uint32_t)strlen(sql)) : 0xFFFFFFFFu;
  uint64_t begin_args[2] = { (uint64_t)(uintptr_t)db, sql_id };
  tlt_begin(SPAN_SQLITE3_EXEC, begin_args, 2);
  int rc = _real(db, sql, callback, ctx, errmsg);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)rc };
  tlt_end(SPAN_SQLITE3_EXEC, end_args, 1);
  return rc;
}

typedef int (*changes_t)(sqlite3*);
int sqlite3_changes(sqlite3* db) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_changes, changes_t);
  if (!_real) return 0;

  uint64_t begin_args[1] = { (uint64_t)(uintptr_t)db };
  tlt_begin(SPAN_SQLITE3_CHANGES, begin_args, 1);
  int result = _real(db);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)result };
  tlt_end(SPAN_SQLITE3_CHANGES, end_args, 1);
  return result;
}

int sqlite3_total_changes(sqlite3* db) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_total_changes, changes_t);
  if (!_real) return 0;

  uint64_t begin_args[1] = { (uint64_t)(uintptr_t)db };
  tlt_begin(SPAN_SQLITE3_TOTAL_CHANGES, begin_args, 1);
  int result = _real(db);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)result };
  tlt_end(SPAN_SQLITE3_TOTAL_CHANGES, end_args, 1);
  return result;
}

typedef long long (*last_insert_rowid_t)(sqlite3*);
long long sqlite3_last_insert_rowid(sqlite3* db) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_last_insert_rowid, last_insert_rowid_t);
  if (!_real) return 0;

  uint64_t begin_args[1] = { (uint64_t)(uintptr_t)db };
  tlt_begin(SPAN_SQLITE3_LAST_INSERT_ROWID, begin_args, 1);
  long long result = _real(db);
  uint64_t end_args[1] = { (uint64_t)result };
  tlt_end(SPAN_SQLITE3_LAST_INSERT_ROWID, end_args, 1);
  return result;
}

typedef int (*errcode_t)(sqlite3*);
int sqlite3_errcode(sqlite3* db) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_errcode, errcode_t);
  if (!_real) return 0;

  uint64_t begin_args[1] = { (uint64_t)(uintptr_t)db };
  tlt_begin(SPAN_SQLITE3_ERRCODE, begin_args, 1);
  int result = _real(db);
  uint64_t end_args[1] = { (uint64_t)(uint32_t)result };
  tlt_end(SPAN_SQLITE3_ERRCODE, end_args, 1);
  return result;
}

typedef const char* (*errmsg_t)(sqlite3*);
const char* sqlite3_errmsg(sqlite3* db) {
  ensure_attached();
  RESOLVE_REAL(sqlite3_errmsg, errmsg_t);
  if (!_real) return NULL;

  uint64_t begin_args[1] = { (uint64_t)(uintptr_t)db };
  tlt_begin(SPAN_SQLITE3_ERRMSG, begin_args, 1);
  const char* result = _real(db);
  uint32_t msg_id = result ? tlt_intern_string(result, (uint32_t)strlen(result)) : 0xFFFFFFFFu;
  uint64_t end_args[1] = { msg_id };
  tlt_end(SPAN_SQLITE3_ERRMSG, end_args, 1);
  return result;
}
