// GENERATED FILE — DO NOT EDIT.
// Source: tools/spans.yaml
// Regenerate with: dart run tools/generate.dart

// ignore_for_file: constant_identifier_names, public_member_api_docs

/// Format version this build of tracelite produces / consumes.
const List<int> kFormatVersion = [1, 0];

/// Built-in span IDs. Stable across format minor versions.
class BuiltinSpans {
  BuiltinSpans._();

  /// `_metadata` — category: tracelite
  static const int metadata = 0x0001;

  /// `_dropped_events` — category: tracelite
  static const int droppedEvents = 0x0002;

  /// `_trace_start` — category: tracelite
  static const int traceStart = 0x0003;

  /// `_trace_end` — category: tracelite
  static const int traceEnd = 0x0004;

  /// `_producer_registered` — category: tracelite
  static const int producerRegistered = 0x0005;

  /// `_string_pool_overflow` — category: tracelite
  static const int stringPoolOverflow = 0x0006;

  /// `_drain_boundary` — category: tracelite
  static const int drainBoundary = 0x0007;

  /// `sqlite3_open` — category: sqlite_c
  static const int sqlite3Open = 0x1000;

  /// `sqlite3_open_v2` — category: sqlite_c
  static const int sqlite3OpenV2 = 0x1001;

  /// `sqlite3_close` — category: sqlite_c
  static const int sqlite3Close = 0x1003;

  /// `sqlite3_close_v2` — category: sqlite_c
  static const int sqlite3CloseV2 = 0x1004;

  /// `sqlite3_prepare_v2` — category: sqlite_c
  static const int sqlite3PrepareV2 = 0x1011;

  /// `sqlite3_prepare_v3` — category: sqlite_c
  static const int sqlite3PrepareV3 = 0x1012;

  /// `sqlite3_finalize` — category: sqlite_c
  static const int sqlite3Finalize = 0x1020;

  /// `sqlite3_step` — category: sqlite_c
  static const int sqlite3Step = 0x1030;

  /// `sqlite3_reset` — category: sqlite_c
  static const int sqlite3Reset = 0x1031;

  /// `sqlite3_bind_null` — category: sqlite_c
  static const int sqlite3BindNull = 0x1040;

  /// `sqlite3_bind_int` — category: sqlite_c
  static const int sqlite3BindInt = 0x1041;

  /// `sqlite3_bind_int64` — category: sqlite_c
  static const int sqlite3BindInt64 = 0x1042;

  /// `sqlite3_bind_double` — category: sqlite_c
  static const int sqlite3BindDouble = 0x1043;

  /// `sqlite3_bind_text` — category: sqlite_c
  static const int sqlite3BindText = 0x1044;

  /// `sqlite3_bind_blob` — category: sqlite_c
  static const int sqlite3BindBlob = 0x1048;

  /// `sqlite3_clear_bindings` — category: sqlite_c
  static const int sqlite3ClearBindings = 0x1053;

  /// `sqlite3_column_count` — category: sqlite_c
  static const int sqlite3ColumnCount = 0x1080;

  /// `sqlite3_column_int` — category: sqlite_c
  static const int sqlite3ColumnInt = 0x1090;

  /// `sqlite3_column_int64` — category: sqlite_c
  static const int sqlite3ColumnInt64 = 0x1091;

  /// `sqlite3_column_double` — category: sqlite_c
  static const int sqlite3ColumnDouble = 0x1092;

  /// `sqlite3_column_text` — category: sqlite_c
  static const int sqlite3ColumnText = 0x1093;

  /// `sqlite3_column_blob` — category: sqlite_c
  static const int sqlite3ColumnBlob = 0x1095;

  /// `sqlite3_column_bytes` — category: sqlite_c
  static const int sqlite3ColumnBytes = 0x1096;

  /// `sqlite3_exec` — category: sqlite_c
  static const int sqlite3Exec = 0x10D0;

  /// `sqlite3_changes` — category: sqlite_c
  static const int sqlite3Changes = 0x10E0;

  /// `sqlite3_total_changes` — category: sqlite_c
  static const int sqlite3TotalChanges = 0x10E2;

  /// `sqlite3_last_insert_rowid` — category: sqlite_c
  static const int sqlite3LastInsertRowid = 0x10E4;

  /// `sqlite3_errcode` — category: sqlite_c
  static const int sqlite3Errcode = 0x1100;

  /// `sqlite3_errmsg` — category: sqlite_c
  static const int sqlite3Errmsg = 0x1102;

  /// `dart.isolate.spawn` — category: dart_recorder
  static const int dartIsolateSpawn = 0x2000;

  /// `dart.isolate.exit` — category: dart_recorder
  static const int dartIsolateExit = 0x2001;

  /// `dart.gc.minor` — category: dart_recorder
  static const int dartGcMinor = 0x2010;

  /// `dart.gc.major` — category: dart_recorder
  static const int dartGcMajor = 0x2011;

  /// `dart.stack.sample` — category: dart_recorder
  static const int dartStackSample = 0x2030;

  /// `ffi.entry` — category: ffi_bridge
  static const int ffiEntry = 0x3000;

  /// `ffi.exit` — category: ffi_bridge
  static const int ffiExit = 0x3001;

  /// `ffi.string.to_native` — category: ffi_bridge
  static const int ffiStringToNative = 0x3010;

  /// `ffi.string.from_native` — category: ffi_bridge
  static const int ffiStringFromNative = 0x3011;

}

/// Mapping from span ID to canonical name.
const Map<int, String> kSpanNames = {
  0x0001: '_metadata',
  0x0002: '_dropped_events',
  0x0003: '_trace_start',
  0x0004: '_trace_end',
  0x0005: '_producer_registered',
  0x0006: '_string_pool_overflow',
  0x0007: '_drain_boundary',
  0x1000: 'sqlite3_open',
  0x1001: 'sqlite3_open_v2',
  0x1003: 'sqlite3_close',
  0x1004: 'sqlite3_close_v2',
  0x1011: 'sqlite3_prepare_v2',
  0x1012: 'sqlite3_prepare_v3',
  0x1020: 'sqlite3_finalize',
  0x1030: 'sqlite3_step',
  0x1031: 'sqlite3_reset',
  0x1040: 'sqlite3_bind_null',
  0x1041: 'sqlite3_bind_int',
  0x1042: 'sqlite3_bind_int64',
  0x1043: 'sqlite3_bind_double',
  0x1044: 'sqlite3_bind_text',
  0x1048: 'sqlite3_bind_blob',
  0x1053: 'sqlite3_clear_bindings',
  0x1080: 'sqlite3_column_count',
  0x1090: 'sqlite3_column_int',
  0x1091: 'sqlite3_column_int64',
  0x1092: 'sqlite3_column_double',
  0x1093: 'sqlite3_column_text',
  0x1095: 'sqlite3_column_blob',
  0x1096: 'sqlite3_column_bytes',
  0x10D0: 'sqlite3_exec',
  0x10E0: 'sqlite3_changes',
  0x10E2: 'sqlite3_total_changes',
  0x10E4: 'sqlite3_last_insert_rowid',
  0x1100: 'sqlite3_errcode',
  0x1102: 'sqlite3_errmsg',
  0x2000: 'dart.isolate.spawn',
  0x2001: 'dart.isolate.exit',
  0x2010: 'dart.gc.minor',
  0x2011: 'dart.gc.major',
  0x2030: 'dart.stack.sample',
  0x3000: 'ffi.entry',
  0x3001: 'ffi.exit',
  0x3010: 'ffi.string.to_native',
  0x3011: 'ffi.string.from_native',
};
