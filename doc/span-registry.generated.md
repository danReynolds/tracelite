# Span registry — full schemas

GENERATED FROM `tools/spans.yaml` — do not edit by hand.

## tracelite

| ID | Name | Begin args | End args | Instant args |
|---|---|---|---|---|
| `0x0001` | `_metadata` | — | — | — |
| `0x0002` | `_dropped_events` | — | — | `dropped_count: u64` |
| `0x0003` | `_trace_start` | — | — | — |
| `0x0004` | `_trace_end` | — | — | — |
| `0x0005` | `_producer_registered` | — | — | `track_id: u32`, `kind: u32` |
| `0x0006` | `_string_pool_overflow` | — | — | `bytes_lost: u64` |
| `0x0007` | `_drain_boundary` | — | — | `drain_seq: u64` |

## sqlite_c

| ID | Name | Begin args | End args | Instant args |
|---|---|---|---|---|
| `0x1000` | `sqlite3_open` | `filename: string_id` | `db: ptr`, `rc: i32` | — |
| `0x1001` | `sqlite3_open_v2` | `filename: string_id`, `flags: i32`, `vfs: string_id` | `db: ptr`, `rc: i32` | — |
| `0x1003` | `sqlite3_close` | `db: ptr` | `rc: i32` | — |
| `0x1004` | `sqlite3_close_v2` | `db: ptr` | `rc: i32` | — |
| `0x1011` | `sqlite3_prepare_v2` | `db: ptr`, `sql: string_id` | `stmt_out: ptr`, `rc: i32` | — |
| `0x1012` | `sqlite3_prepare_v3` | `db: ptr`, `sql: string_id`, `flags: u32` | `stmt_out: ptr`, `rc: i32` | — |
| `0x1020` | `sqlite3_finalize` | `stmt: ptr` | `rc: i32` | — |
| `0x1030` | `sqlite3_step` | `stmt: ptr` | `rc: i32` | — |
| `0x1031` | `sqlite3_reset` | `stmt: ptr` | `rc: i32` | — |
| `0x1040` | `sqlite3_bind_null` | `stmt: ptr`, `idx: i32` | `rc: i32` | — |
| `0x1041` | `sqlite3_bind_int` | `stmt: ptr`, `idx: i32`, `val: i64` | `rc: i32` | — |
| `0x1042` | `sqlite3_bind_int64` | `stmt: ptr`, `idx: i32`, `val: i64` | `rc: i32` | — |
| `0x1043` | `sqlite3_bind_double` | `stmt: ptr`, `idx: i32`, `val: f64` | `rc: i32` | — |
| `0x1044` | `sqlite3_bind_text` | `stmt: ptr`, `idx: i32`, `len: bytes_len` | `rc: i32` | — |
| `0x1048` | `sqlite3_bind_blob` | `stmt: ptr`, `idx: i32`, `len: bytes_len` | `rc: i32` | — |
| `0x1053` | `sqlite3_clear_bindings` | `stmt: ptr` | `rc: i32` | — |
| `0x1080` | `sqlite3_column_count` | `stmt: ptr` | `count: i32` | — |
| `0x1090` | `sqlite3_column_int` | `stmt: ptr`, `idx: i32` | `val: i64` | — |
| `0x1091` | `sqlite3_column_int64` | `stmt: ptr`, `idx: i32` | `val: i64` | — |
| `0x1092` | `sqlite3_column_double` | `stmt: ptr`, `idx: i32` | `val: f64` | — |
| `0x1093` | `sqlite3_column_text` | `stmt: ptr`, `idx: i32` | `len: bytes_len` | — |
| `0x1095` | `sqlite3_column_blob` | `stmt: ptr`, `idx: i32` | `len: bytes_len` | — |
| `0x1096` | `sqlite3_column_bytes` | `stmt: ptr`, `idx: i32` | `len: bytes_len` | — |
| `0x10D0` | `sqlite3_exec` | `db: ptr`, `sql: string_id` | `rc: i32` | — |
| `0x10E0` | `sqlite3_changes` | `db: ptr` | `count: i32` | — |
| `0x10E2` | `sqlite3_total_changes` | `db: ptr` | `count: i32` | — |
| `0x10E4` | `sqlite3_last_insert_rowid` | `db: ptr` | `rowid: i64` | — |
| `0x1100` | `sqlite3_errcode` | `db: ptr` | `code: i32` | — |
| `0x1102` | `sqlite3_errmsg` | `db: ptr` | `msg: string_id` | — |

## dart_recorder

| ID | Name | Begin args | End args | Instant args |
|---|---|---|---|---|
| `0x2000` | `dart.isolate.spawn` | `parent_track: u64` | `child_track: u64`, `name: string_id` | — |
| `0x2001` | `dart.isolate.exit` | — | — | `track: u64` |
| `0x2010` | `dart.gc.minor` | `reason: string_id`, `before_bytes: u64` | `after_bytes: u64` | — |
| `0x2011` | `dart.gc.major` | `reason: string_id`, `before_bytes: u64` | `after_bytes: u64` | — |
| `0x2030` | `dart.stack.sample` | — | — | `frames: list_string_id` |

## ffi_bridge

| ID | Name | Begin args | End args | Instant args |
|---|---|---|---|---|
| `0x3000` | `ffi.entry` | — | — | `symbol: string_id` |
| `0x3001` | `ffi.exit` | — | — | `symbol: string_id` |
| `0x3010` | `ffi.string.to_native` | `byte_len: bytes_len` | — | — |
| `0x3011` | `ffi.string.from_native` | `byte_len: bytes_len` | — | — |
