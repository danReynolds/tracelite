import 'dart:async';

abstract interface class SqlitePeer {
  String get name;

  Future<void> open(String path);

  Future<void> close();

  Future<void> execute(String sql, [List<Object?> parameters = const []]);

  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> parameters = const [],
  ]);

  Future<void> executeBatch(String sql, List<List<Object?>> parameterSets);
}

abstract interface class ReactiveSqlitePeer implements SqlitePeer {
  Stream<List<Map<String, Object?>>> watch(
    String sql, {
    List<Object?> parameters = const [],
    Set<String> readsFrom = const {},
  });
}

abstract interface class DiagnosticSqlitePeer implements SqlitePeer {
  Future<SqliteDiagnosticSnapshot> snapshotDiagnostics();
}

final class SqliteDiagnosticSnapshot {
  const SqliteDiagnosticSnapshot({
    required this.sqlitePageCacheBytes,
    required this.sqliteSchemaBytes,
    required this.sqliteStmtBytes,
    required this.walBytes,
    required this.streamCount,
    required this.readerBusy,
  });

  final int sqlitePageCacheBytes;
  final int sqliteSchemaBytes;
  final int sqliteStmtBytes;
  final int walBytes;
  final int streamCount;
  final bool readerBusy;

  int get sqliteTotalBytes =>
      sqlitePageCacheBytes + sqliteSchemaBytes + sqliteStmtBytes;

  Map<String, Object?> toJson() => {
        'sqlite_total_bytes': sqliteTotalBytes,
        'sqlite_page_cache_bytes': sqlitePageCacheBytes,
        'sqlite_schema_bytes': sqliteSchemaBytes,
        'sqlite_stmt_bytes': sqliteStmtBytes,
        'wal_bytes': walBytes,
        'stream_count': streamCount,
        'reader_busy': readerBusy,
      };
}

final class PeerScenarioResult {
  const PeerScenarioResult({
    required this.setupElapsedNs,
    required this.warmupElapsedNs,
    required this.measuredElapsedNs,
    this.measurements = const {},
  });

  final int setupElapsedNs;
  final int warmupElapsedNs;
  final int measuredElapsedNs;
  final Map<String, Object?> measurements;

  Map<String, Object?> toJson() => {
        'setup_elapsed_ns': setupElapsedNs,
        'warmup_elapsed_ns': warmupElapsedNs,
        'measured_elapsed_ns': measuredElapsedNs,
        if (measurements.isNotEmpty) 'measurements': measurements,
      };
}

final class UnsupportedPeerScenario implements Exception {
  const UnsupportedPeerScenario(this.message);

  final String message;

  @override
  String toString() => message;
}
