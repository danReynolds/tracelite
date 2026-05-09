/*
 * test_producer.c — minimal end-to-end smoke test for the runtime.
 *
 * 1. Attach to TRACELITE_REGION (mmap'd by the Dart harness).
 * 2. Register as a c_thread producer.
 * 3. Intern a string.
 * 4. Emit a small handful of begin/end events (sqlite3_step pretend).
 * 5. Detach.
 *
 * Build: cc -std=c11 -O2 -Inative native/tracelite_runtime.c
 *           native/test_producer.c -o build/test_producer
 *
 * Run:   TRACELITE_REGION=/tmp/tracelite-test build/test_producer
 *
 * The harness in test/runtime_smoke_test.dart sets up the region,
 * spawns this binary, drains, and checks invariants.
 */

#include "tracelite_runtime.h"
#include "builtin_spans.g.h"

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
  if (tlt_attach(NULL) != 0) {
    fprintf(stderr, "test_producer: failed to attach to TRACELITE_REGION\n");
    return 1;
  }

  int track = tlt_register_producer(TLT_TRACK_KIND_C_THREAD, "test_producer", "main");
  if (track < 0) {
    fprintf(stderr, "test_producer: failed to register producer\n");
    return 1;
  }

  /* Intern a SQL string for use in span args. */
  const char* sql = "UPDATE wide SET a = ? WHERE id = ?";
  uint32_t sql_id = tlt_intern_string(sql, (uint32_t)strlen(sql));

  /* Pretend to call sqlite3_prepare_v3 → step → reset, three times.
   * begin_args of sqlite3_prepare_v3 are (db, sql, flags). end_args
   * are (stmt_out, rc). begin_args of sqlite3_step are (stmt). */

  uint64_t fake_db = 0xdeadbeef;
  uint64_t fake_stmt = 0xfeedface;
  uint64_t prepare_begin[3] = { fake_db, sql_id, 0 };
  uint64_t prepare_end[2] = { fake_stmt, 0 /* rc=SQLITE_OK */ };

  for (int i = 0; i < 3; i++) {
    /* prepare_v3 */
    tlt_begin(SPAN_SQLITE3_PREPARE_V3, prepare_begin, 3);
    tlt_end(SPAN_SQLITE3_PREPARE_V3, prepare_end, 2);

    /* step */
    uint64_t step_begin[1] = { fake_stmt };
    uint64_t step_end[1] = { 101 /* SQLITE_DONE */ };
    tlt_begin(SPAN_SQLITE3_STEP, step_begin, 1);
    tlt_end(SPAN_SQLITE3_STEP, step_end, 1);

    /* reset */
    uint64_t reset_begin[1] = { fake_stmt };
    uint64_t reset_end[1] = { 0 };
    tlt_begin(SPAN_SQLITE3_RESET, reset_begin, 1);
    tlt_end(SPAN_SQLITE3_RESET, reset_end, 1);
  }

  tlt_detach();
  return 0;
}
