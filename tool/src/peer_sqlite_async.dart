import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:sqlite_async/sqlite_async.dart' as sqlite_async;

import 'peer_contract.dart';

final class SqliteAsyncPeer implements SqlitePeer, ReactiveSqlitePeer {
  sqlite_async.SqliteDatabase? _db;
  sqlite3.Database? _raw;

  @override
  String get name => 'sqlite_async';

  @override
  Future<void> open(String path) async {
    _raw = sqlite3.sqlite3.open(path);
    _db = sqlite_async.SqliteDatabase.singleConnection(
      sqlite_async.SqliteConnection.synchronousWrapper(
        _raw!,
        profileQueries: false,
      ),
    );
    await _db!.getAll('SELECT 1');
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
    _raw = null;
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
  ]) async {
    return [
      for (final row in await _db!.getAll(sql, parameters))
        Map<String, Object?>.from(row),
    ];
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
    return _db!
        .watchUnthrottled(
          sql,
          parameters: parameters,
          triggerOnTables: readsFrom.isEmpty ? null : readsFrom,
        )
        .map((rows) => [
              for (final row in rows) Map<String, Object?>.from(row),
            ]);
  }
}
