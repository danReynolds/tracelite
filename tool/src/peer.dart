import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:drift/drift.dart' as drift;
import 'package:drift/backends.dart' as drift_backend;
import 'package:drift/native.dart' as drift_native;
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:sqlite_async/sqlite_async.dart' as sqlite_async;
import 'package:tracelite/resqlite.dart' as tracelite_resqlite;

const String narrowBatchInsertScenario = 'narrow-batch-insert';
const String pointSelectScenario = 'point-select';
const String feedPagingScenario = 'feed-paging';
const String syncBurstScenario = 'sync-burst';
const String chatSimScenario = 'chat-sim';
const String largeWorkingSetScenario = 'large-working-set';
const String keyedPkSubscriptionsScenario = 'keyed-pk-subscriptions';
const String highCardinalityFanoutScenario = 'high-cardinality-fanout';
const String manyStreamsWriterThroughputScenario =
    'many-streams-writer-throughput';
const String sqliteDiagnosticsScenario = 'sqlite-diagnostics';

const List<String> defaultScenarioNames = [
  narrowBatchInsertScenario,
  pointSelectScenario,
  feedPagingScenario,
  syncBurstScenario,
  chatSimScenario,
  largeWorkingSetScenario,
  keyedPkSubscriptionsScenario,
  highCardinalityFanoutScenario,
  manyStreamsWriterThroughputScenario,
  sqliteDiagnosticsScenario,
];

const int _feedPagingSeed = 0xFEED;
const int _feedPagingPageSize = 10;
const int _feedPagingPageCount = 4;
const int _feedPagingLikeWrites = 8;
const int _syncBurstChunkSize = 25;
const int _syncBurstMergeRounds = 3;
const int _syncBurstMergeRowsPerRound = 10;
const int _chatSimSeed = 0x5EED;
const double _chatSimZipfExponent = 1.0;
const int _largeWorkingSetSeed = 0xB16B00B5;
const int _largeWorkingSetPayloadLength = 128;
const int _reactiveSeed = 0xBEEF;
const int _fanoutSeed = 0xCAFEF0;

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

SqlitePeer createPeer(String name) {
  return switch (name) {
    'sqlite3' => Sqlite3Peer(),
    'drift' => DriftPeer(),
    'sqlite_async' => SqliteAsyncPeer(),
    'resqlite' => ResqlitePeer(),
    _ => throw ArgumentError.value(name, 'name', 'unknown peer'),
  };
}

List<String> peerCapabilities(String peerName) {
  final capabilities = <String>['sql', 'batch'];
  if (peerName == 'resqlite' ||
      peerName == 'sqlite_async' ||
      peerName == 'drift') {
    capabilities.add('reactive');
  }
  if (peerName == 'resqlite') {
    capabilities.add('diagnostics');
  }
  return capabilities;
}

Map<String, Object?> peerScenarioParameters(
  String scenarioName, {
  required int rows,
}) {
  return switch (scenarioName) {
    narrowBatchInsertScenario => {
        'rows': rows,
        'required_capabilities': ['sql', 'batch'],
        'columns': 2,
        'measured_operations': ['execute_batch', 'count_select'],
      },
    pointSelectScenario => {
        'rows': rows,
        'required_capabilities': ['sql'],
        'lookups': rows,
        'seed': 0,
        'measured_operations': ['point_select'],
      },
    feedPagingScenario => {
        'rows': rows,
        'required_capabilities': ['sql', 'batch'],
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
        'required_capabilities': ['sql', 'batch'],
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
    chatSimScenario => {
        'operations': rows,
        'required_capabilities': ['sql', 'batch'],
        'warmup_operations': _chatWarmupOps(rows),
        'users': _chatUserCount(rows),
        'conversations': _chatConversationCount(rows),
        'seed_messages': _chatSeedMessageCount(rows),
        'seed': _chatSimSeed,
        'zipf_exponent': _chatSimZipfExponent,
        'operation_mix': {
          'insert_message_percent': 5,
          'update_conversation_percent': 5,
          'read_messages_percent': 45,
          'read_user_percent': 45,
        },
      },
    largeWorkingSetScenario => {
        'rows': rows,
        'required_capabilities': ['sql', 'batch'],
        'seed': _largeWorkingSetSeed,
        'payload_bytes': _largeWorkingSetPayloadLength,
        'point_queries': _largeWorkingSetPointQueries(rows),
        'range_scans': _largeWorkingSetRangeScans(rows),
        'range_scan_limit': _largeWorkingSetRangeLimit(rows),
        'measured_operations': [
          'random_point_select',
          'range_scan_select',
          'pragma_shrink_memory',
        ],
      },
    keyedPkSubscriptionsScenario => {
        'rows': _reactiveRowCount(rows),
        'stream_count': _reactiveStreamCount(rows),
        'write_count': _reactiveWriteCount(rows),
        'seed': _reactiveSeed,
        'required_capabilities': ['sql', 'reactive'],
        'measured_operations': [
          'stream_initial_drain',
          'random_pk_update',
          'stream_settle',
        ],
      },
    highCardinalityFanoutScenario => {
        'rows': _fanoutRowCount(rows),
        'stream_count': _fanoutStreamCount(rows),
        'write_count': _fanoutWriteCount(rows),
        'seed': _fanoutSeed,
        'required_capabilities': ['sql', 'reactive'],
        'measured_operations': [
          'partition_stream_initial_drain',
          'random_partition_update',
          'stream_settle',
        ],
      },
    manyStreamsWriterThroughputScenario => {
        'rows': _writerRowCount(rows),
        'stream_count': _writerStreamCount(rows),
        'write_count': _writerWriteCount(rows),
        'required_capabilities': ['sql', 'reactive'],
        'measured_operations': [
          'baseline_updates',
          'disjoint_updates_with_streams',
          'overlap_updates_with_streams',
        ],
      },
    sqliteDiagnosticsScenario => {
        'rows': rows,
        'required_capabilities': ['sql', 'diagnostics'],
        'measured_operations': [
          'seed',
          'warm_read',
          'diagnostic_snapshot',
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
      case chatSimScenario:
        return await _runChatSim(peer, rows: rows);
      case largeWorkingSetScenario:
        return await _runLargeWorkingSet(peer, rows: rows);
      case keyedPkSubscriptionsScenario:
        return await _runKeyedPkSubscriptions(peer, rows: rows);
      case highCardinalityFanoutScenario:
        return await _runHighCardinalityFanout(peer, rows: rows);
      case manyStreamsWriterThroughputScenario:
        return await _runManyStreamsWriterThroughput(peer, rows: rows);
      case sqliteDiagnosticsScenario:
        return await _runSqliteDiagnostics(peer, rows: rows);
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

Future<PeerScenarioResult> _runChatSim(
  SqlitePeer peer, {
  required int rows,
}) async {
  final userCount = _chatUserCount(rows);
  final conversationCount = _chatConversationCount(rows);
  final seedMessages = _chatSeedMessageCount(rows);

  final setup = Stopwatch()..start();
  await peer.execute('DROP TABLE IF EXISTS tracelite_chat_messages');
  await peer.execute('DROP TABLE IF EXISTS tracelite_chat_conversations');
  await peer.execute('DROP TABLE IF EXISTS tracelite_chat_users');
  await peer.execute(
    'CREATE TABLE tracelite_chat_users('
    'id INTEGER PRIMARY KEY, '
    'name TEXT NOT NULL, '
    'avatar_url TEXT NOT NULL)',
  );
  await peer.execute(
    'CREATE TABLE tracelite_chat_conversations('
    'id INTEGER PRIMARY KEY, '
    'last_msg_at INTEGER NOT NULL)',
  );
  await peer.execute(
    'CREATE TABLE tracelite_chat_messages('
    'id INTEGER PRIMARY KEY, '
    'conv_id INTEGER NOT NULL, '
    'sender_id INTEGER NOT NULL, '
    'body TEXT NOT NULL, '
    'sent_at INTEGER NOT NULL)',
  );
  await peer.execute(
    'CREATE INDEX tracelite_chat_messages_conv_sent '
    'ON tracelite_chat_messages(conv_id, sent_at DESC)',
  );
  await peer.executeBatch(
    'INSERT INTO tracelite_chat_users(id, name, avatar_url) VALUES (?, ?, ?)',
    [
      for (var i = 1; i <= userCount; i++)
        [i, 'user_$i', 'https://example.com/avatars/$i.png'],
    ],
  );
  await peer.executeBatch(
    'INSERT INTO tracelite_chat_conversations(id, last_msg_at) VALUES (?, ?)',
    [
      for (var i = 1; i <= conversationCount; i++) [i, 0]
    ],
  );
  final seedZipf = _ZipfianSampler(
    conversationCount,
    _chatSimZipfExponent,
    _chatSimSeed ^ 0xABC,
  );
  final seedPrng = math.Random(_chatSimSeed ^ 0xDEF);
  await peer.executeBatch(
    'INSERT INTO tracelite_chat_messages('
    'id, conv_id, sender_id, body, sent_at'
    ') VALUES (?, ?, ?, ?, ?)',
    [
      for (var i = 1; i <= seedMessages; i++)
        [
          i,
          seedZipf.sample() + 1,
          seedPrng.nextInt(userCount) + 1,
          'seed_message_$i',
          i,
        ],
    ],
  );
  setup.stop();

  final ops = _generateChatOps(
    totalOps: rows,
    userCount: userCount,
    conversationCount: conversationCount,
    seedMessageCount: seedMessages,
  );
  final warmupOps = _chatWarmupOps(rows);
  final warmup = Stopwatch()..start();
  for (final op in ops.take(warmupOps)) {
    await _executeChatOp(peer, op);
  }
  warmup.stop();

  final measured = Stopwatch()..start();
  for (final op in ops.skip(warmupOps)) {
    await _executeChatOp(peer, op);
  }
  measured.stop();

  return PeerScenarioResult(
    setupElapsedNs: _elapsedNs(setup),
    warmupElapsedNs: _elapsedNs(warmup),
    measuredElapsedNs: _elapsedNs(measured),
  );
}

Future<PeerScenarioResult> _runLargeWorkingSet(
  SqlitePeer peer, {
  required int rows,
}) async {
  final setup = Stopwatch()..start();
  await peer.execute('DROP TABLE IF EXISTS tracelite_large_items');
  await peer.execute(
    'CREATE TABLE tracelite_large_items('
    'id INTEGER PRIMARY KEY, '
    'payload TEXT NOT NULL)',
  );
  final payload = List.filled(_largeWorkingSetPayloadLength, 'x').join();
  await peer.executeBatch(
    'INSERT INTO tracelite_large_items(id, payload) VALUES (?, ?)',
    [
      for (var i = 1; i <= rows; i++) [i, '$payload$i'],
    ],
  );
  setup.stop();

  final warmup = Stopwatch()..start();
  await peer.select('SELECT payload FROM tracelite_large_items WHERE id = ?', [
    1,
  ]);
  await peer.execute('PRAGMA shrink_memory');
  warmup.stop();

  final measured = Stopwatch()..start();
  final prng = math.Random(_largeWorkingSetSeed);
  for (var i = 0; i < _largeWorkingSetPointQueries(rows); i++) {
    final id = prng.nextInt(rows) + 1;
    final result = await peer.select(
      'SELECT payload FROM tracelite_large_items WHERE id = ?',
      [id],
    );
    if (result.isEmpty) {
      throw StateError('${peer.name} returned no large row for id=$id');
    }
    _consumeRows(result);
  }
  final rangeLimit = _largeWorkingSetRangeLimit(rows);
  for (var i = 0; i < _largeWorkingSetRangeScans(rows); i++) {
    final start = prng.nextInt(math.max(1, rows - rangeLimit + 1)) + 1;
    final result = await peer.select(
      'SELECT payload FROM tracelite_large_items '
      'WHERE id >= ? AND id < ? LIMIT ?',
      [start, start + rangeLimit, rangeLimit],
    );
    if (result.isEmpty) {
      throw StateError('${peer.name} returned no large range for id=$start');
    }
    _consumeRows(result);
  }
  measured.stop();

  return PeerScenarioResult(
    setupElapsedNs: _elapsedNs(setup),
    warmupElapsedNs: _elapsedNs(warmup),
    measuredElapsedNs: _elapsedNs(measured),
  );
}

Future<PeerScenarioResult> _runKeyedPkSubscriptions(
  SqlitePeer peer, {
  required int rows,
}) async {
  final reactive = _requireReactivePeer(peer);
  final rowCount = _reactiveRowCount(rows);
  final streamCount = _reactiveStreamCount(rows);
  final writeCount = _reactiveWriteCount(rows);

  final setup = Stopwatch()..start();
  await peer.execute('DROP TABLE IF EXISTS tracelite_keyed_items');
  await peer.execute(
    'CREATE TABLE tracelite_keyed_items('
    'id INTEGER PRIMARY KEY, '
    'body TEXT NOT NULL, '
    'updated_at INTEGER NOT NULL)',
  );
  await peer.executeBatch(
    'INSERT INTO tracelite_keyed_items(id, body, updated_at) VALUES (?, ?, ?)',
    [
      for (var i = 1; i <= rowCount; i++) [i, 'body_$i', 0],
    ],
  );
  setup.stop();

  final watchedIds = [for (var i = 1; i <= streamCount; i++) i];
  final emitCounts = List<int>.filled(streamCount, 0);
  final subscriptions = <StreamSubscription<List<Map<String, Object?>>>>[];
  final warmup = Stopwatch()..start();
  for (var i = 0; i < streamCount; i++) {
    final index = i;
    subscriptions.add(
      reactive.watch(
        'SELECT id, body, updated_at '
        'FROM tracelite_keyed_items WHERE id = ?',
        parameters: [watchedIds[i]],
        readsFrom: const {'tracelite_keyed_items'},
      ).listen((_) => emitCounts[index]++),
    );
  }
  try {
    await _waitUntil(
      () => emitCounts.every((count) => count > 0),
      timeout: const Duration(seconds: 10),
      description: '${peer.name} keyed stream initial emissions',
    );
    warmup.stop();

    for (var i = 0; i < emitCounts.length; i++) {
      emitCounts[i] = 0;
    }

    final prng = math.Random(_reactiveSeed);
    var observedHits = 0;
    final measured = Stopwatch()..start();
    for (var i = 0; i < writeCount; i++) {
      final id = prng.nextInt(rowCount) + 1;
      if (watchedIds.contains(id)) observedHits++;
      await peer.execute(
        'UPDATE tracelite_keyed_items '
        'SET body = ?, updated_at = ? WHERE id = ?',
        ['body_${i}_$id', i + 1, id],
      );
    }
    await _waitForQuietReactiveWindow(() => emitCounts.fold<int>(0, _sum));
    measured.stop();

    return PeerScenarioResult(
      setupElapsedNs: _elapsedNs(setup),
      warmupElapsedNs: _elapsedNs(warmup),
      measuredElapsedNs: _elapsedNs(measured),
      measurements: {
        'stream_count': streamCount,
        'write_count': writeCount,
        'post_baseline_emissions': emitCounts.fold<int>(0, _sum),
        'observed_watched_pk_hits': observedHits,
      },
    );
  } finally {
    await Future.wait([for (final sub in subscriptions) sub.cancel()]);
  }
}

Future<PeerScenarioResult> _runHighCardinalityFanout(
  SqlitePeer peer, {
  required int rows,
}) async {
  final reactive = _requireReactivePeer(peer);
  final rowCount = _fanoutRowCount(rows);
  final streamCount = _fanoutStreamCount(rows);
  final writeCount = _fanoutWriteCount(rows);

  final setup = Stopwatch()..start();
  await peer.execute('DROP TABLE IF EXISTS tracelite_fanout_items');
  await peer.execute(
    'CREATE TABLE tracelite_fanout_items('
    'id INTEGER PRIMARY KEY, '
    'owner_id INTEGER NOT NULL, '
    'value TEXT NOT NULL)',
  );
  await peer.execute(
    'CREATE INDEX tracelite_fanout_owner '
    'ON tracelite_fanout_items(owner_id)',
  );
  await peer.executeBatch(
    'INSERT INTO tracelite_fanout_items(id, owner_id, value) VALUES (?, ?, ?)',
    [
      for (var i = 1; i <= rowCount; i++)
        [i, ((i - 1) % streamCount) + 1, 'value_$i'],
    ],
  );
  setup.stop();

  final emitCounts = List<int>.filled(streamCount, 0);
  final subscriptions = <StreamSubscription<List<Map<String, Object?>>>>[];
  final warmup = Stopwatch()..start();
  for (var ownerId = 1; ownerId <= streamCount; ownerId++) {
    final index = ownerId - 1;
    subscriptions.add(
      reactive.watch(
        'SELECT id, value FROM tracelite_fanout_items '
        'WHERE owner_id = ? ORDER BY id',
        parameters: [ownerId],
        readsFrom: const {'tracelite_fanout_items'},
      ).listen((_) => emitCounts[index]++),
    );
  }
  try {
    await _waitUntil(
      () => emitCounts.every((count) => count > 0),
      timeout: const Duration(seconds: 10),
      description: '${peer.name} fanout stream initial emissions',
    );
    warmup.stop();
    for (var i = 0; i < emitCounts.length; i++) {
      emitCounts[i] = 0;
    }

    final prng = math.Random(_fanoutSeed);
    final touchedOwners = <int>{};
    final measured = Stopwatch()..start();
    for (var i = 0; i < writeCount; i++) {
      final id = prng.nextInt(rowCount) + 1;
      touchedOwners.add(((id - 1) % streamCount) + 1);
      await peer.execute(
        'UPDATE tracelite_fanout_items SET value = ? WHERE id = ?',
        ['updated_${i}_$id', id],
      );
    }
    await _waitForQuietReactiveWindow(() => emitCounts.fold<int>(0, _sum));
    measured.stop();

    return PeerScenarioResult(
      setupElapsedNs: _elapsedNs(setup),
      warmupElapsedNs: _elapsedNs(warmup),
      measuredElapsedNs: _elapsedNs(measured),
      measurements: {
        'stream_count': streamCount,
        'write_count': writeCount,
        'post_baseline_emissions': emitCounts.fold<int>(0, _sum),
        'touched_owner_count': touchedOwners.length,
      },
    );
  } finally {
    await Future.wait([for (final sub in subscriptions) sub.cancel()]);
  }
}

Future<PeerScenarioResult> _runManyStreamsWriterThroughput(
  SqlitePeer peer, {
  required int rows,
}) async {
  final reactive = _requireReactivePeer(peer);
  final rowCount = _writerRowCount(rows);
  final streamCount = _writerStreamCount(rows);
  final writeCount = _writerWriteCount(rows);

  final setup = Stopwatch()..start();
  await peer.execute('DROP TABLE IF EXISTS tracelite_wide_items');
  await peer.execute(
    'CREATE TABLE tracelite_wide_items('
    'id INTEGER PRIMARY KEY, '
    'partition_id INTEGER NOT NULL, '
    'a TEXT NOT NULL, '
    'b TEXT NOT NULL, '
    'c TEXT NOT NULL)',
  );
  await peer.execute(
    'CREATE INDEX tracelite_wide_partition '
    'ON tracelite_wide_items(partition_id)',
  );
  await peer.executeBatch(
    'INSERT INTO tracelite_wide_items(id, partition_id, a, b, c) '
    'VALUES (?, ?, ?, ?, ?)',
    [
      for (var i = 1; i <= rowCount; i++)
        [i, (i - 1) % streamCount, 'a_$i', 'b_$i', 'c_$i'],
    ],
  );
  setup.stop();

  final baseline = Stopwatch()..start();
  await _runWideUpdates(
    peer,
    column: 'c',
    writeCount: writeCount,
    rowCount: rowCount,
    valuePrefix: 'baseline',
  );
  baseline.stop();

  final emitCounts = List<int>.filled(streamCount, 0);
  final subscriptions = <StreamSubscription<List<Map<String, Object?>>>>[];
  final warmup = Stopwatch()..start();
  for (var partition = 0; partition < streamCount; partition++) {
    final index = partition;
    subscriptions.add(
      reactive.watch(
        'SELECT id, a, b FROM tracelite_wide_items '
        'WHERE partition_id = ? ORDER BY id',
        parameters: [partition],
        readsFrom: const {'tracelite_wide_items'},
      ).listen((_) => emitCounts[index]++),
    );
  }
  try {
    await _waitUntil(
      () => emitCounts.every((count) => count > 0),
      timeout: const Duration(seconds: 10),
      description: '${peer.name} many-stream initial emissions',
    );
    warmup.stop();
    for (var i = 0; i < emitCounts.length; i++) {
      emitCounts[i] = 0;
    }

    final measured = Stopwatch()..start();
    final disjoint = Stopwatch()..start();
    await _runWideUpdates(
      peer,
      column: 'c',
      writeCount: writeCount,
      rowCount: rowCount,
      valuePrefix: 'disjoint',
    );
    await _waitForQuietReactiveWindow(() => emitCounts.fold<int>(0, _sum));
    disjoint.stop();
    final disjointEmissions = emitCounts.fold<int>(0, _sum);

    for (var i = 0; i < emitCounts.length; i++) {
      emitCounts[i] = 0;
    }

    final overlap = Stopwatch()..start();
    await _runWideUpdates(
      peer,
      column: 'a',
      writeCount: writeCount,
      rowCount: rowCount,
      valuePrefix: 'overlap',
    );
    await _waitForQuietReactiveWindow(() => emitCounts.fold<int>(0, _sum));
    overlap.stop();
    measured.stop();

    return PeerScenarioResult(
      setupElapsedNs: _elapsedNs(setup),
      warmupElapsedNs: _elapsedNs(warmup),
      measuredElapsedNs: _elapsedNs(measured),
      measurements: {
        'stream_count': streamCount,
        'write_count': writeCount,
        'baseline_elapsed_ns': _elapsedNs(baseline),
        'disjoint_elapsed_ns': _elapsedNs(disjoint),
        'overlap_elapsed_ns': _elapsedNs(overlap),
        'disjoint_emissions': disjointEmissions,
        'overlap_emissions': emitCounts.fold<int>(0, _sum),
      },
    );
  } finally {
    await Future.wait([for (final sub in subscriptions) sub.cancel()]);
  }
}

Future<PeerScenarioResult> _runSqliteDiagnostics(
  SqlitePeer peer, {
  required int rows,
}) async {
  final diagnosticPeer = _requireDiagnosticPeer(peer);
  final setup = Stopwatch()..start();
  await peer.execute('DROP TABLE IF EXISTS tracelite_diag_items');
  await peer.execute(
    'CREATE TABLE tracelite_diag_items('
    'id INTEGER PRIMARY KEY, '
    'payload TEXT NOT NULL)',
  );
  await peer.executeBatch(
    'INSERT INTO tracelite_diag_items(id, payload) VALUES (?, ?)',
    [
      for (var i = 1; i <= rows; i++) [i, 'payload_$i'],
    ],
  );
  setup.stop();

  final measured = Stopwatch()..start();
  for (var i = 1; i <= math.min(rows, 10); i++) {
    await peer.select(
      'SELECT payload FROM tracelite_diag_items WHERE id = ?',
      [i],
    );
  }
  final snapshot = await diagnosticPeer.snapshotDiagnostics();
  final session = tracelite_resqlite.TraceSession.attach(
    processName: 'tracelite_peer',
    threadName: 'resqlite_diagnostics',
    vocabularies: const [tracelite_resqlite.resqliteTraceVocabulary],
  );
  try {
    tracelite_resqlite.recordResqliteDiagnostics(
      session,
      sqlitePageCacheBytes: snapshot.sqlitePageCacheBytes,
      sqliteSchemaBytes: snapshot.sqliteSchemaBytes,
      sqliteStmtBytes: snapshot.sqliteStmtBytes,
      walBytes: snapshot.walBytes,
      streamCount: snapshot.streamCount,
      readerBusy: snapshot.readerBusy,
    );
  } finally {
    session.detach();
  }
  measured.stop();

  return PeerScenarioResult(
    setupElapsedNs: _elapsedNs(setup),
    warmupElapsedNs: 0,
    measuredElapsedNs: _elapsedNs(measured),
    measurements: snapshot.toJson(),
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

List<_ChatOp> _generateChatOps({
  required int totalOps,
  required int userCount,
  required int conversationCount,
  required int seedMessageCount,
}) {
  final prng = math.Random(_chatSimSeed);
  final zipf = _ZipfianSampler(
    conversationCount,
    _chatSimZipfExponent,
    _chatSimSeed,
  );
  final ops = <_ChatOp>[];
  var clock = seedMessageCount + 1;

  for (var i = 0; i < totalOps; i++) {
    final roll = prng.nextInt(100);
    if (roll < 5) {
      ops.add(
        _ChatOp.insertMessage(
          conversationId: zipf.sample() + 1,
          userId: prng.nextInt(userCount) + 1,
          sentAt: clock++,
        ),
      );
    } else if (roll < 10) {
      ops.add(
        _ChatOp.updateConversation(
          conversationId: zipf.sample() + 1,
          sentAt: clock++,
        ),
      );
    } else if (roll < 55) {
      ops.add(_ChatOp.readMessages(conversationId: zipf.sample() + 1));
    } else {
      ops.add(_ChatOp.readUser(userId: prng.nextInt(userCount) + 1));
    }
  }
  return ops;
}

Future<void> _executeChatOp(SqlitePeer peer, _ChatOp op) async {
  switch (op.kind) {
    case _ChatOpKind.insertMessage:
      await peer.execute(
        'INSERT INTO tracelite_chat_messages('
        'conv_id, sender_id, body, sent_at'
        ') VALUES (?, ?, ?, ?)',
        [
          op.conversationId,
          op.userId,
          'body_${op.sentAt}',
          op.sentAt,
        ],
      );
    case _ChatOpKind.updateConversation:
      await peer.execute(
        'UPDATE tracelite_chat_conversations '
        'SET last_msg_at = ? WHERE id = ?',
        [op.sentAt, op.conversationId],
      );
    case _ChatOpKind.readMessages:
      final result = await peer.select(
        'SELECT m.id, m.body, m.sent_at, u.name, u.avatar_url '
        'FROM tracelite_chat_messages m '
        'JOIN tracelite_chat_users u ON u.id = m.sender_id '
        'WHERE m.conv_id = ? '
        'ORDER BY m.sent_at DESC LIMIT 20',
        [op.conversationId],
      );
      _consumeRows(result);
    case _ChatOpKind.readUser:
      final result = await peer.select(
        'SELECT id, name, avatar_url FROM tracelite_chat_users WHERE id = ?',
        [op.userId],
      );
      if (result.isEmpty) {
        throw StateError('${peer.name} returned no user for id=${op.userId}');
      }
      _consumeRows(result);
  }
}

void _consumeRows(List<Map<String, Object?>> rows) {
  for (final row in rows) {
    for (final value in row.values) {
      if (identical(value, value)) continue;
    }
  }
}

int _chatUserCount(int rows) => math.max(10, rows * 2);

int _chatConversationCount(int rows) => math.max(4, rows);

int _chatSeedMessageCount(int rows) => math.max(20, rows * 20);

int _chatWarmupOps(int rows) => math.min(rows ~/ 10, math.max(0, rows - 1));

int _largeWorkingSetPointQueries(int rows) => math.max(1, rows ~/ 2);

int _largeWorkingSetRangeScans(int rows) => math.max(1, rows ~/ 20);

int _largeWorkingSetRangeLimit(int rows) => math.min(25, math.max(1, rows));

ReactiveSqlitePeer _requireReactivePeer(SqlitePeer peer) {
  if (peer is ReactiveSqlitePeer) return peer;
  throw UnsupportedPeerScenario('${peer.name} does not support reactive watch');
}

DiagnosticSqlitePeer _requireDiagnosticPeer(SqlitePeer peer) {
  if (peer is DiagnosticSqlitePeer) return peer;
  throw UnsupportedPeerScenario('${peer.name} does not expose diagnostics');
}

Future<void> _waitUntil(
  bool Function() predicate, {
  required Duration timeout,
  required String description,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('timed out waiting for $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _waitForQuietReactiveWindow(int Function() readCount) async {
  var last = readCount();
  var stableWindows = 0;
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final current = readCount();
    if (current == last) {
      stableWindows++;
      if (stableWindows >= 2) return;
      continue;
    }
    stableWindows = 0;
    last = current;
  }
}

Future<void> _runWideUpdates(
  SqlitePeer peer, {
  required String column,
  required int writeCount,
  required int rowCount,
  required String valuePrefix,
}) async {
  for (var i = 0; i < writeCount; i++) {
    final id = (i % rowCount) + 1;
    await peer.execute(
      'UPDATE tracelite_wide_items SET $column = ? WHERE id = ?',
      ['${valuePrefix}_$i', id],
    );
    await Future<void>.delayed(Duration.zero);
  }
}

int _sum(int a, int b) => a + b;

int _reactiveStreamCount(int rows) => math.min(50, math.max(1, rows));

int _reactiveWriteCount(int rows) => math.min(200, math.max(10, rows * 5));

int _reactiveRowCount(int rows) =>
    math.max(_reactiveStreamCount(rows) * 4, rows * 100);

int _fanoutStreamCount(int rows) => math.min(100, math.max(2, rows));

int _fanoutWriteCount(int rows) => math.min(200, math.max(10, rows * 5));

int _fanoutRowCount(int rows) =>
    math.max(_fanoutStreamCount(rows) * 10, rows * 100);

int _writerStreamCount(int rows) => math.min(50, math.max(2, rows));

int _writerWriteCount(int rows) => math.min(100, math.max(10, rows * 4));

int _writerRowCount(int rows) =>
    math.max(_writerStreamCount(rows) * 10, rows * 100);

enum _ChatOpKind {
  insertMessage,
  updateConversation,
  readMessages,
  readUser,
}

final class _ChatOp {
  _ChatOp.insertMessage({
    required this.conversationId,
    required this.userId,
    required this.sentAt,
  }) : kind = _ChatOpKind.insertMessage;

  _ChatOp.updateConversation({
    required this.conversationId,
    required this.sentAt,
  })  : kind = _ChatOpKind.updateConversation,
        userId = null;

  _ChatOp.readMessages({required this.conversationId})
      : kind = _ChatOpKind.readMessages,
        userId = null,
        sentAt = null;

  _ChatOp.readUser({required this.userId})
      : kind = _ChatOpKind.readUser,
        conversationId = null,
        sentAt = null;

  final _ChatOpKind kind;
  final int? conversationId;
  final int? userId;
  final int? sentAt;
}

final class _ZipfianSampler {
  _ZipfianSampler(int n, double s, int seed)
      : _rng = math.Random(seed ^ 0xBADBEEF),
        _cdf = _buildCdf(n, s);

  final math.Random _rng;
  final List<double> _cdf;

  int sample() {
    final r = _rng.nextDouble();
    var lo = 0;
    var hi = _cdf.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >>> 1;
      if (_cdf[mid] >= r) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  static List<double> _buildCdf(int n, double s) {
    final weights = List<double>.generate(
      n,
      (k) => 1.0 / math.pow(k + 1, s),
    );
    final sum = weights.fold<double>(0, (a, b) => a + b);
    final cdf = List<double>.filled(n, 0);
    var acc = 0.0;
    for (var i = 0; i < n; i++) {
      acc += weights[i] / sum;
      cdf[i] = acc;
    }
    cdf[n - 1] = 1.0;
    return cdf;
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

final class DriftPeer implements SqlitePeer, ReactiveSqlitePeer {
  _TraceliteDriftDatabase? _db;

  @override
  String get name => 'drift';

  @override
  Future<void> open(String path) async {
    _db = _TraceliteDriftDatabase(drift_native.NativeDatabase(File(path)));
    await _db!.executor.ensureOpen(_db!);
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  @override
  Future<void> execute(String sql,
      [List<Object?> parameters = const []]) async {
    await _db!.customStatement(sql, parameters);
    _db!.notifyWritesFor(sql);
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    final rows = await _db!
        .customSelect(sql, variables: _driftVariables(parameters))
        .get();
    return [
      for (final row in rows) Map<String, Object?>.from(row.data),
    ];
  }

  @override
  Future<void> executeBatch(
    String sql,
    List<List<Object?>> parameterSets,
  ) async {
    await _db!.customStatement('BEGIN');
    try {
      await _db!.executor.runBatched(
        drift_backend.BatchedStatements(
          [sql],
          [
            for (final parameters in parameterSets)
              drift_backend.ArgumentsForBatchedStatement(0, parameters),
          ],
        ),
      );
      await _db!.customStatement('COMMIT');
      _db!.notifyWritesFor(sql);
    } catch (_) {
      await _db!.customStatement('ROLLBACK');
      rethrow;
    }
  }

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, {
    List<Object?> parameters = const [],
    Set<String> readsFrom = const {},
  }) {
    final tables = _db!.tablesFor(readsFrom);
    return _db!
        .customSelect(
          sql,
          variables: _driftVariables(parameters),
          readsFrom: tables,
        )
        .watch()
        .map((rows) => [
              for (final row in rows) Map<String, Object?>.from(row.data),
            ]);
  }
}

final class _TraceliteDriftDatabase extends drift.GeneratedDatabase {
  _TraceliteDriftDatabase(super.executor);

  late final _tablesByName = {
    for (final name in const [
      'tracelite_keyed_items',
      'tracelite_fanout_items',
      'tracelite_wide_items',
    ])
      name: _TraceliteDriftTable(name, this),
  };

  @override
  int get schemaVersion => 1;

  @override
  drift.MigrationStrategy get migration => drift.MigrationStrategy(
        onCreate: (_) async {},
      );

  @override
  Iterable<drift.TableInfo> get allTables => _tablesByName.values;

  Set<drift.ResultSetImplementation> tablesFor(Set<String> tableNames) {
    if (tableNames.isEmpty) {
      throw const UnsupportedPeerScenario(
        'drift reactive watches require readsFrom table names',
      );
    }
    final tables = <drift.ResultSetImplementation>{};
    for (final name in tableNames) {
      final table = _tablesByName[name];
      if (table == null) {
        throw UnsupportedPeerScenario(
          'drift reactive watch has no table registry entry for $name',
        );
      }
      tables.add(table);
    }
    return tables;
  }

  void notifyWritesFor(String sql) {
    final table = _writeTableFrom(sql);
    if (table == null) return;
    final driftTable = _tablesByName[table];
    if (driftTable != null) {
      markTablesUpdated([driftTable]);
    }
  }
}

final class _TraceliteDriftTable extends drift.Table
    with drift.TableInfo<_TraceliteDriftTable, Map<String, Object?>> {
  _TraceliteDriftTable(
    this.actualTableName,
    this.attachedDatabase, [
    this._alias,
  ]);

  @override
  final String actualTableName;

  @override
  final drift.DatabaseConnectionUser attachedDatabase;

  final String? _alias;

  @override
  List<drift.GeneratedColumn> get $columns => const [];

  @override
  String get aliasedName => _alias ?? actualTableName;

  @override
  Map<String, Object?> map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    return Map<String, Object?>.from(data);
  }

  @override
  _TraceliteDriftTable createAlias(String alias) {
    return _TraceliteDriftTable(actualTableName, attachedDatabase, alias);
  }
}

List<drift.Variable> _driftVariables(List<Object?> values) {
  return [for (final value in values) _driftVariable(value)];
}

drift.Variable _driftVariable(Object? value) {
  return switch (value) {
    null => const drift.Variable<Object>(null),
    bool value => drift.Variable.withBool(value),
    int value => drift.Variable.withInt(value),
    BigInt value => drift.Variable.withBigInt(value),
    String value => drift.Variable.withString(value),
    DateTime value => drift.Variable.withDateTime(value),
    Uint8List value => drift.Variable.withBlob(value),
    double value => drift.Variable.withReal(value),
    _ => drift.Variable<Object>(value),
  };
}

String? _writeTableFrom(String sql) {
  final match = RegExp(
    r'^\s*(?:'
    r'insert\s+(?:or\s+\w+\s+)?into|'
    r'replace\s+into|'
    r'update|'
    r'delete\s+from'
    r')\s+["`\[]?([A-Za-z_][A-Za-z0-9_]*)',
    caseSensitive: false,
  ).firstMatch(sql);
  return match?.group(1);
}

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
