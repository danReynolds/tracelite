# Format spec appendix — built-in span IDs

GENERATED FROM `tool/spans.yaml` — do not edit by hand.

| ID | Name | Category | Phases |
|---|---|---|---|
| `0x0001` | `_metadata` | tracelite |  |
| `0x0002` | `_dropped_events` | tracelite | instant(1) |
| `0x0003` | `_trace_start` | tracelite |  |
| `0x0004` | `_trace_end` | tracelite |  |
| `0x0005` | `_producer_registered` | tracelite | instant(2) |
| `0x0006` | `_string_pool_overflow` | tracelite | instant(1) |
| `0x0007` | `_drain_boundary` | tracelite | instant(1) |
| `0x1000` | `sqlite3_open` | sqlite_c | begin(1), end(2) |
| `0x1001` | `sqlite3_open_v2` | sqlite_c | begin(3), end(2) |
| `0x1003` | `sqlite3_close` | sqlite_c | begin(1), end(1) |
| `0x1004` | `sqlite3_close_v2` | sqlite_c | begin(1), end(1) |
| `0x1011` | `sqlite3_prepare_v2` | sqlite_c | begin(2), end(2) |
| `0x1012` | `sqlite3_prepare_v3` | sqlite_c | begin(3), end(2) |
| `0x1020` | `sqlite3_finalize` | sqlite_c | begin(1), end(1) |
| `0x1030` | `sqlite3_step` | sqlite_c | begin(1), end(1) |
| `0x1031` | `sqlite3_reset` | sqlite_c | begin(1), end(1) |
| `0x1040` | `sqlite3_bind_null` | sqlite_c | begin(2), end(1) |
| `0x1041` | `sqlite3_bind_int` | sqlite_c | begin(3), end(1) |
| `0x1042` | `sqlite3_bind_int64` | sqlite_c | begin(3), end(1) |
| `0x1043` | `sqlite3_bind_double` | sqlite_c | begin(3), end(1) |
| `0x1044` | `sqlite3_bind_text` | sqlite_c | begin(3), end(1) |
| `0x1048` | `sqlite3_bind_blob` | sqlite_c | begin(3), end(1) |
| `0x1053` | `sqlite3_clear_bindings` | sqlite_c | begin(1), end(1) |
| `0x1080` | `sqlite3_column_count` | sqlite_c | begin(1), end(1) |
| `0x1090` | `sqlite3_column_int` | sqlite_c | begin(2), end(1) |
| `0x1091` | `sqlite3_column_int64` | sqlite_c | begin(2), end(1) |
| `0x1092` | `sqlite3_column_double` | sqlite_c | begin(2), end(1) |
| `0x1093` | `sqlite3_column_text` | sqlite_c | begin(2), end(1) |
| `0x1095` | `sqlite3_column_blob` | sqlite_c | begin(2), end(1) |
| `0x1096` | `sqlite3_column_bytes` | sqlite_c | begin(2), end(1) |
| `0x10D0` | `sqlite3_exec` | sqlite_c | begin(2), end(1) |
| `0x10E0` | `sqlite3_changes` | sqlite_c | begin(1), end(1) |
| `0x10E2` | `sqlite3_total_changes` | sqlite_c | begin(1), end(1) |
| `0x10E4` | `sqlite3_last_insert_rowid` | sqlite_c | begin(1), end(1) |
| `0x1100` | `sqlite3_errcode` | sqlite_c | begin(1), end(1) |
| `0x1102` | `sqlite3_errmsg` | sqlite_c | begin(1), end(1) |
| `0x2000` | `dart.isolate.spawn` | dart_recorder | begin(1), end(2) |
| `0x2001` | `dart.isolate.exit` | dart_recorder | instant(1) |
| `0x2010` | `dart.gc.minor` | dart_recorder | begin(2), end(1) |
| `0x2011` | `dart.gc.major` | dart_recorder | begin(2), end(1) |
| `0x2030` | `dart.stack.sample` | dart_recorder | instant(1) |
| `0x3000` | `ffi.entry` | ffi_bridge | instant(1) |
| `0x3001` | `ffi.exit` | ffi_bridge | instant(1) |
| `0x3010` | `ffi.string.to_native` | ffi_bridge | begin(1) |
| `0x3011` | `ffi.string.from_native` | ffi_bridge | begin(1) |
