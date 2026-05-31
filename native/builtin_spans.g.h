/* GENERATED FILE — DO NOT EDIT. */
/* Source: tool/spans.yaml */
/* Regenerate with: dart run tool/generate.dart */

#ifndef TRACELITE_BUILTIN_SPANS_G_H
#define TRACELITE_BUILTIN_SPANS_G_H

#define TRACELITE_FORMAT_MAJOR 1
#define TRACELITE_FORMAT_MINOR 0

/* _metadata (tracelite) */
#define SPAN__METADATA 0x0001
/* _dropped_events (tracelite) */
#define SPAN__DROPPED_EVENTS 0x0002
/* _trace_start (tracelite) */
#define SPAN__TRACE_START 0x0003
/* _trace_end (tracelite) */
#define SPAN__TRACE_END 0x0004
/* _producer_registered (tracelite) */
#define SPAN__PRODUCER_REGISTERED 0x0005
/* _string_pool_overflow (tracelite) */
#define SPAN__STRING_POOL_OVERFLOW 0x0006
/* _drain_boundary (tracelite) */
#define SPAN__DRAIN_BOUNDARY 0x0007
/* sqlite3_open (sqlite_c) */
#define SPAN_SQLITE3_OPEN 0x1000
/* sqlite3_open_v2 (sqlite_c) */
#define SPAN_SQLITE3_OPEN_V2 0x1001
/* sqlite3_close (sqlite_c) */
#define SPAN_SQLITE3_CLOSE 0x1003
/* sqlite3_close_v2 (sqlite_c) */
#define SPAN_SQLITE3_CLOSE_V2 0x1004
/* sqlite3_prepare_v2 (sqlite_c) */
#define SPAN_SQLITE3_PREPARE_V2 0x1011
/* sqlite3_prepare_v3 (sqlite_c) */
#define SPAN_SQLITE3_PREPARE_V3 0x1012
/* sqlite3_finalize (sqlite_c) */
#define SPAN_SQLITE3_FINALIZE 0x1020
/* sqlite3_step (sqlite_c) */
#define SPAN_SQLITE3_STEP 0x1030
/* sqlite3_reset (sqlite_c) */
#define SPAN_SQLITE3_RESET 0x1031
/* sqlite3_bind_null (sqlite_c) */
#define SPAN_SQLITE3_BIND_NULL 0x1040
/* sqlite3_bind_int (sqlite_c) */
#define SPAN_SQLITE3_BIND_INT 0x1041
/* sqlite3_bind_int64 (sqlite_c) */
#define SPAN_SQLITE3_BIND_INT64 0x1042
/* sqlite3_bind_double (sqlite_c) */
#define SPAN_SQLITE3_BIND_DOUBLE 0x1043
/* sqlite3_bind_text (sqlite_c) */
#define SPAN_SQLITE3_BIND_TEXT 0x1044
/* sqlite3_bind_blob (sqlite_c) */
#define SPAN_SQLITE3_BIND_BLOB 0x1048
/* sqlite3_clear_bindings (sqlite_c) */
#define SPAN_SQLITE3_CLEAR_BINDINGS 0x1053
/* sqlite3_column_count (sqlite_c) */
#define SPAN_SQLITE3_COLUMN_COUNT 0x1080
/* sqlite3_column_int (sqlite_c) */
#define SPAN_SQLITE3_COLUMN_INT 0x1090
/* sqlite3_column_int64 (sqlite_c) */
#define SPAN_SQLITE3_COLUMN_INT64 0x1091
/* sqlite3_column_double (sqlite_c) */
#define SPAN_SQLITE3_COLUMN_DOUBLE 0x1092
/* sqlite3_column_text (sqlite_c) */
#define SPAN_SQLITE3_COLUMN_TEXT 0x1093
/* sqlite3_column_blob (sqlite_c) */
#define SPAN_SQLITE3_COLUMN_BLOB 0x1095
/* sqlite3_column_bytes (sqlite_c) */
#define SPAN_SQLITE3_COLUMN_BYTES 0x1096
/* sqlite3_exec (sqlite_c) */
#define SPAN_SQLITE3_EXEC 0x10D0
/* sqlite3_changes (sqlite_c) */
#define SPAN_SQLITE3_CHANGES 0x10E0
/* sqlite3_total_changes (sqlite_c) */
#define SPAN_SQLITE3_TOTAL_CHANGES 0x10E2
/* sqlite3_last_insert_rowid (sqlite_c) */
#define SPAN_SQLITE3_LAST_INSERT_ROWID 0x10E4
/* sqlite3_errcode (sqlite_c) */
#define SPAN_SQLITE3_ERRCODE 0x1100
/* sqlite3_errmsg (sqlite_c) */
#define SPAN_SQLITE3_ERRMSG 0x1102
/* dart.isolate.spawn (dart_recorder) */
#define SPAN_DART_ISOLATE_SPAWN 0x2000
/* dart.isolate.exit (dart_recorder) */
#define SPAN_DART_ISOLATE_EXIT 0x2001
/* dart.gc.minor (dart_recorder) */
#define SPAN_DART_GC_MINOR 0x2010
/* dart.gc.major (dart_recorder) */
#define SPAN_DART_GC_MAJOR 0x2011
/* dart.stack.sample (dart_recorder) */
#define SPAN_DART_STACK_SAMPLE 0x2030
/* ffi.entry (ffi_bridge) */
#define SPAN_FFI_ENTRY 0x3000
/* ffi.exit (ffi_bridge) */
#define SPAN_FFI_EXIT 0x3001
/* ffi.string.to_native (ffi_bridge) */
#define SPAN_FFI_STRING_TO_NATIVE 0x3010
/* ffi.string.from_native (ffi_bridge) */
#define SPAN_FFI_STRING_FROM_NATIVE 0x3011

#endif /* TRACELITE_BUILTIN_SPANS_G_H */
