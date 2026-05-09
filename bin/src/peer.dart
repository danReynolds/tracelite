import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/backends.dart' as drift_backend;
import 'package:drift/native.dart' as drift_native;
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:sqlite_async/sqlite_async.dart' as sqlite_async;

const String narrowBatchInsertScenario = 'narrow-batch-insert';
const String pointSelectScenario = 'point-select';

const List<String> defaultPeerNames = [
  'sqlite3',
  'drift',
  'sqlite_async',
  'resqlite',
];

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

SqlitePeer createPeer(String name) {
  return switch (name) {
    'sqlite3' => Sqlite3Peer(),
    'drift' => DriftPeer(),
    'sqlite_async' => SqliteAsyncPeer(),
    'resqlite' => ResqlitePeer(),
    _ => throw ArgumentError.value(name, 'name', 'unknown peer'),
  };
}

Future<void> runPeerScenario({
  required String peerName,
  required String scenarioName,
  required String databasePath,
  int rows = 100,
}) async {
  final peer = createPeer(peerName);
  try {
    await peer.open(databasePath);
    switch (scenarioName) {
      case narrowBatchInsertScenario:
        await _runNarrowBatchInsert(peer, rows: rows);
      case pointSelectScenario:
        await _runPointSelect(peer, rows: rows);
      default:
        throw ArgumentError.value(
          scenarioName,
          'scenarioName',
          'unknown scenario',
        );
    }
  } finally {
    await peer.close();
  }
}

Future<void> _runNarrowBatchInsert(SqlitePeer peer, {required int rows}) async {
  await peer.execute('DROP TABLE IF EXISTS tracelite_items');
  await peer.execute(
    'CREATE TABLE tracelite_items(id INTEGER PRIMARY KEY, name TEXT NOT NULL)',
  );
  final params = [
    for (var i = 0; i < rows; i++) [i, 'name_$i'],
  ];
  await peer.executeBatch(
    'INSERT INTO tracelite_items(id, name) VALUES (?, ?)',
    params,
  );
  final result = await peer.select(
    'SELECT COUNT(*) AS count FROM tracelite_items WHERE id >= ?',
    [0],
  );
  final count = result.single['count'];
  if (count != rows) {
    throw StateError('${peer.name} inserted $count row(s), expected $rows');
  }
}

Future<void> _runPointSelect(SqlitePeer peer, {required int rows}) async {
  await _runNarrowBatchInsert(peer, rows: rows);
  for (var i = 0; i < rows; i++) {
    final result = await peer.select(
      'SELECT id, name FROM tracelite_items WHERE id = ?',
      [i],
    );
    if (result.single['name'] != 'name_$i') {
      throw StateError('${peer.name} returned wrong row for id=$i');
    }
  }
}

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

final class DriftPeer implements SqlitePeer {
  drift_native.NativeDatabase? _db;
  final _user = _DriftUser();

  @override
  String get name => 'drift';

  @override
  Future<void> open(String path) async {
    _db = drift_native.NativeDatabase(File(path));
    await _db!.ensureOpen(_user);
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  @override
  Future<void> execute(String sql, [List<Object?> parameters = const []]) {
    return _db!.runCustom(sql, parameters);
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> parameters = const [],
  ]) {
    return _db!.runSelect(sql, parameters);
  }

  @override
  Future<void> executeBatch(
    String sql,
    List<List<Object?>> parameterSets,
  ) async {
    await _db!.runCustom('BEGIN');
    try {
      await _db!.runBatched(
        drift_backend.BatchedStatements(
          [sql],
          [
            for (final parameters in parameterSets)
              drift_backend.ArgumentsForBatchedStatement(0, parameters),
          ],
        ),
      );
      await _db!.runCustom('COMMIT');
    } catch (_) {
      await _db!.runCustom('ROLLBACK');
      rethrow;
    }
  }
}

final class _DriftUser implements drift_backend.QueryExecutorUser {
  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
    drift_backend.QueryExecutor executor,
    drift.OpeningDetails details,
  ) async {}
}

final class SqliteAsyncPeer implements SqlitePeer {
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
}

final class ResqlitePeer implements SqlitePeer {
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
}
