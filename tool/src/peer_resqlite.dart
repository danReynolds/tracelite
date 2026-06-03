import 'package:resqlite/resqlite.dart' as resqlite;

import 'peer_contract.dart';

final class ResqlitePeer
    implements SqlitePeer, ReactiveSqlitePeer, DiagnosticSqlitePeer {
  resqlite.Database? _db;

  @override
  String get name => 'resqlite';

  @override
  Future<void> open(String path) async {
    _db = await resqlite.Database.open(path);
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  @override
  Future<void> execute(String sql,
      [List<Object?> parameters = const []]) async {
    await _db!.execute(sql, parameters);
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> parameters = const [],
  ]) {
    return _db!.select(sql, parameters);
  }

  @override
  Future<void> executeBatch(String sql, List<List<Object?>> parameterSets) {
    return _db!.executeBatch(sql, parameterSets);
  }

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, {
    List<Object?> parameters = const [],
    Set<String> readsFrom = const {},
  }) {
    return _db!.stream(sql, parameters);
  }

  @override
  Future<SqliteDiagnosticSnapshot> snapshotDiagnostics() async {
    final diagnostics = await _db!.diagnostics();
    return SqliteDiagnosticSnapshot(
      sqlitePageCacheBytes: diagnostics.sqlitePageCacheBytes,
      sqliteSchemaBytes: diagnostics.sqliteSchemaBytes,
      sqliteStmtBytes: diagnostics.sqliteStmtBytes,
      walBytes: diagnostics.walBytes,
      streamCount: diagnostics.streamLength,
      readerBusy: diagnostics.readersBusyAtSnapshot,
    );
  }
}
