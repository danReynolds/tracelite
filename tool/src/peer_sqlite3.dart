import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'peer_contract.dart';

final class Sqlite3Peer implements SqlitePeer {
  sqlite3.Database? _db;

  @override
  String get name => 'sqlite3';

  @override
  Future<void> open(String path) async {
    _db = sqlite3.sqlite3.open(path);
  }

  @override
  Future<void> close() async {
    _db?.close();
    _db = null;
  }

  @override
  Future<void> execute(String sql,
      [List<Object?> parameters = const []]) async {
    _db!.execute(sql, parameters);
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    return [
      for (final row in _db!.select(sql, parameters))
        Map<String, Object?>.from(row),
    ];
  }

  @override
  Future<void> executeBatch(
    String sql,
    List<List<Object?>> parameterSets,
  ) async {
    _db!.execute('BEGIN');
    final statement = _db!.prepare(sql);
    try {
      for (final parameters in parameterSets) {
        statement.execute(parameters);
      }
      _db!.execute('COMMIT');
    } catch (_) {
      _db!.execute('ROLLBACK');
      rethrow;
    } finally {
      statement.close();
    }
  }
}
