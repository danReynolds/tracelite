import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' as drift;
import 'package:drift/backends.dart' as drift_backend;
import 'package:drift/native.dart' as drift_native;
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:sqlite_async/sqlite_async.dart' as sqlite_async;

const String narrowBatchInsertScenario = 'narrow-batch-insert';
const String pointSelectScenario = 'point-select';
const String feedPagingScenario = 'feed-paging';
const String syncBurstScenario = 'sync-burst';

const List<String> defaultScenarioNames = [
  narrowBatchInsertScenario,
  pointSelectScenario,
  feedPagingScenario,
  syncBurstScenario,
];

const int _feedPagingSeed = 0xFEED;
const int _feedPagingPageSize = 10;
const int _feedPagingPageCount = 4;
const int _feedPagingLikeWrites = 8;
const int _syncBurstChunkSize = 25;
const int _syncBurstMergeRounds = 3;
const int _syncBurstMergeRowsPerRound = 10;

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

final class PeerScenarioResult {
  const PeerScenarioResult({
    required this.setupElapsedNs,
    required this.warmupElapsedNs,
    required this.measuredElapsedNs,
  });

  final int setupElapsedNs;
  final int warmupElapsedNs;
  final int measuredElapsedNs;

  Map<String, Object?> toJson() => {
        'setup_elapsed_ns': setupElapsedNs,
        'warmup_elapsed_ns': warmupElapsedNs,
        'measured_elapsed_ns': measuredElapsedNs,
      };
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

Map<String, Object?> peerScenarioParameters(
  String scenarioName, {
  required int rows,
}) {
  return switch (scenarioName) {
    narrowBatchInsertScenario => {
        'rows': rows,
        'columns': 2,
        'measured_operations': ['execute_batch', 'count_select'],
      },
    pointSelectScenario => {
        'rows': rows,
        'lookups': rows,
        'seed': 0,
        'measured_operations': ['point_select'],
      },
    feedPagingScenario => {
        'rows': rows,
        'seed': _feedPagingSeed,
        'page_size': math.min(_feedPagingPageSize, math.max(1, rows)),
        'page_count': _feedPagingPageCount,
        'like_writes': math.min(_feedPagingLikeWrites, math.max(1, rows)),
        'measured_operations': [
          'keyset_page_select',
          'point_update',
          'latest_page_select',
        ],
      },
    syncBurstScenario => {
        'rows': rows,
        'bulk_chunk_size': math.min(_syncBurstChunkSize, math.max(1, rows)),
        'merge_rounds': _syncBurstMergeRounds,
        'merge_rows_per_round': math.min(
          _syncBurstMergeRowsPerRound,
          math.max(1, rows),
        ),
        'measured_operations': [
          'chunked_execute_batch',
          'insert_or_replace_merge',
          'count_select',
        ],
      },
    _ => throw ArgumentError.value(
        scenarioName,
        'scenarioName',
        'unknown scenario',
      ),
  };
}

Future<PeerScenarioResult> runPeerScenario({
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
        return await _runNarrowBatchInsert(peer, rows: rows);
      case pointSelectScenario:
        return await _runPointSelect(peer, rows: rows);
      case feedPagingScenario:
        return await _runFeedPaging(peer, rows: rows);
      case syncBurstScenario:
        return await _runSyncBurst(peer, rows: rows);
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

Future<PeerScenarioResult> _runNarrowBatchInsert(
  SqlitePeer peer, {
  required int rows,
}) async {
  final setup = Stopwatch()..start();
  await peer.execute('DROP TABLE IF EXISTS tracelite_items');
  await peer.execute(
    'CREATE TABLE tracelite_items(id INTEGER PRIMARY KEY, name TEXT NOT NULL)',
  );
  setup.stop();

  final params = [
    for (var i = 0; i < rows; i++) [i, 'name_$i'],
  ];
  final measured = Stopwatch()..start();
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
  measured.stop();
  return PeerScenarioResult(
    setupElapsedNs: _elapsedNs(setup),
    warmupElapsedNs: 0,
    measuredElapsedNs: _elapsedNs(measured),
  );
}

Future<PeerScenarioResult> _runPointSelect(
  SqlitePeer peer, {
  required int rows,
}) async {
  final setup = Stopwatch()..start();
  await _seedNarrowItems(peer, rows: rows);
  setup.stop();

  final measured = Stopwatch()..start();
  for (var i = 0; i < rows; i++) {
    final result = await peer.select(
      'SELECT id, name FROM tracelite_items WHERE id = ?',
      [i],
    );
    if (result.single['name'] != 'name_$i') {
      throw StateError('${peer.name} returned wrong row for id=$i');
    }
  }
  measured.stop();
  return PeerScenarioResult(
    setupElapsedNs: _elapsedNs(setup),
    warmupElapsedNs: 0,
    measuredElapsedNs: _elapsedNs(measured),
  );
}

Future<PeerScenarioResult> _runFeedPaging(
  SqlitePeer peer, {
  required int rows,
}) async {
  final setup = Stopwatch()..start();
  await peer.execute('DROP TABLE IF EXISTS tracelite_feed_items');
  await peer.execute(
    'CREATE TABLE tracelite_feed_items('
    'id INTEGER PRIMARY KEY, '
    'author_id INTEGER NOT NULL, '
    'created_at INTEGER NOT NULL, '
    'body TEXT NOT NULL, '
    'like_count INTEGER NOT NULL)',
  );
  await peer.execute(
    'CREATE INDEX tracelite_feed_created_at_id '
    'ON tracelite_feed_items(created_at DESC, id DESC)',
  );

  final prng = math.Random(_feedPagingSeed);
  await peer.executeBatch(
    'INSERT INTO tracelite_feed_items('
    'id, author_id, created_at, body, like_count'
    ') VALUES (?, ?, ?, ?, ?)',
    [
      for (var i = 0; i < rows; i++)
        [
          i + 1,
          prng.nextInt(500) + 1,
          i + 1,
          'body_$i',
          0,
        ],
    ],
  );
  setup.stop();

  final warmup = Stopwatch()..start();
  await _selectLatestFeedPage(peer, math.min(_feedPagingPageSize, rows));
  warmup.stop();

  final measured = Stopwatch()..start();
  await _walkFeedPages(peer, rows: rows);
  await _applyFeedLikeWrites(peer, rows: rows);
  final latest = await _selectLatestFeedPage(
    peer,
    math.min(_feedPagingPageSize, rows),
  );
  if (latest.isEmpty) {
    throw StateError('${peer.name} returned no feed rows');
  }
  measured.stop();

  return PeerScenarioResult(
    setupElapsedNs: _elapsedNs(setup),
    warmupElapsedNs: _elapsedNs(warmup),
    measuredElapsedNs: _elapsedNs(measured),
  );
}

Future<PeerScenarioResult> _runSyncBurst(
  SqlitePeer peer, {
  required int rows,
}) async {
  final setup = Stopwatch()..start();
  await peer.execute('DROP TABLE IF EXISTS tracelite_sync_items');
  await peer.execute(
    'CREATE TABLE tracelite_sync_items('
    'id INTEGER PRIMARY KEY, '
    'external_id INTEGER UNIQUE, '
    'payload TEXT NOT NULL, '
    'dirty INTEGER NOT NULL)',
  );
  setup.stop();

  final measured = Stopwatch()..start();
  final chunkSize = math.min(_syncBurstChunkSize, math.max(1, rows));
  for (var offset = 0; offset < rows; offset += chunkSize) {
    final n = math.min(chunkSize, rows - offset);
    await peer.executeBatch(
      'INSERT INTO tracelite_sync_items(external_id, payload, dirty) '
      'VALUES (?, ?, ?)',
      [
        for (var i = 0; i < n; i++) [offset + i, 'payload_${offset + i}', 0],
      ],
    );
  }

  final mergeRows = math.min(_syncBurstMergeRowsPerRound, math.max(1, rows));
  for (var round = 0; round < _syncBurstMergeRounds; round++) {
    await peer.executeBatch(
      'INSERT OR REPLACE INTO tracelite_sync_items('
      'external_id, payload, dirty'
      ') VALUES (?, ?, ?)',
      [
        for (var i = 0; i < mergeRows; i++)
          [
            rows + round * mergeRows + i,
            'merge_${round}_$i',
            1,
          ],
      ],
    );
    final dirty = await peer.select(
      'SELECT COUNT(*) AS count FROM tracelite_sync_items WHERE dirty = ?',
      [1],
    );
    final count = dirty.single['count'] as int;
    if (count < mergeRows) {
      throw StateError(
        '${peer.name} dirty count $count below expected $mergeRows',
      );
    }
    await peer.execute(
      'UPDATE tracelite_sync_items SET dirty = ? WHERE dirty = ?',
      [0, 1],
    );
  }

  final result = await peer.select(
    'SELECT COUNT(*) AS count FROM tracelite_sync_items WHERE external_id >= ?',
    [0],
  );
  final expected = rows + _syncBurstMergeRounds * mergeRows;
  final count = result.single['count'];
  if (count != expected) {
    throw StateError('${peer.name} synced $count row(s), expected $expected');
  }
  measured.stop();

  return PeerScenarioResult(
    setupElapsedNs: _elapsedNs(setup),
    warmupElapsedNs: 0,
    measuredElapsedNs: _elapsedNs(measured),
  );
}

Future<void> _seedNarrowItems(SqlitePeer peer, {required int rows}) async {
  await peer.execute('DROP TABLE IF EXISTS tracelite_items');
  await peer.execute(
    'CREATE TABLE tracelite_items(id INTEGER PRIMARY KEY, name TEXT NOT NULL)',
  );
  await peer.executeBatch(
    'INSERT INTO tracelite_items(id, name) VALUES (?, ?)',
    [
      for (var i = 0; i < rows; i++) [i, 'name_$i'],
    ],
  );
}

Future<void> _walkFeedPages(SqlitePeer peer, {required int rows}) async {
  final pageSize = math.min(_feedPagingPageSize, math.max(1, rows));
  int? lastCreatedAt;
  int? lastId;
  for (var page = 0; page < _feedPagingPageCount; page++) {
    final result = page == 0
        ? await _selectLatestFeedPage(peer, pageSize)
        : await peer.select(
            'SELECT id, author_id, created_at, body, like_count '
            'FROM tracelite_feed_items '
            'WHERE created_at < ? OR (created_at = ? AND id < ?) '
            'ORDER BY created_at DESC, id DESC LIMIT ?',
            [lastCreatedAt, lastCreatedAt, lastId, pageSize],
          );
    if (result.isEmpty) break;
    final last = result.last;
    lastCreatedAt = last['created_at'] as int;
    lastId = last['id'] as int;
  }
}

Future<List<Map<String, Object?>>> _selectLatestFeedPage(
  SqlitePeer peer,
  int pageSize,
) {
  return peer.select(
    'SELECT id, author_id, created_at, body, like_count '
    'FROM tracelite_feed_items '
    'ORDER BY created_at DESC, id DESC LIMIT ?',
    [pageSize],
  );
}

Future<void> _applyFeedLikeWrites(SqlitePeer peer, {required int rows}) async {
  final prng = math.Random(_feedPagingSeed);
  final writes = math.min(_feedPagingLikeWrites, math.max(1, rows));
  for (var i = 0; i < writes; i++) {
    final id = prng.nextInt(rows) + 1;
    await peer.execute(
      'UPDATE tracelite_feed_items '
      'SET like_count = like_count + 1 WHERE id = ?',
      [id],
    );
  }
}

int _elapsedNs(Stopwatch stopwatch) => stopwatch.elapsedMicroseconds * 1000;

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
