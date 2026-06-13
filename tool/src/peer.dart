import 'dart:async';
import 'dart:math' as math;
import 'package:tracelite/resqlite.dart' as tracelite_resqlite;

import 'peer_contract.dart';
import 'peer_definitions.dart';
import 'peer_drift.dart' deferred as drift_adapter;
import 'peer_resqlite.dart' deferred as resqlite_adapter;
import 'peer_sqlite3.dart' deferred as sqlite3_adapter;
import 'peer_sqlite_async.dart' deferred as sqlite_async_adapter;

export 'peer_contract.dart';

Future<SqlitePeer> createPeer(String name) async {
  return switch (name) {
    'sqlite3' => await _sqlite3Peer(),
    'drift' => await _driftPeer(),
    'sqlite_async' => await _sqliteAsyncPeer(),
    'resqlite' => await _resqlitePeer(),
    _ => throw ArgumentError.value(name, 'name', 'unknown peer'),
  };
}

Future<SqlitePeer> _sqlite3Peer() async {
  await sqlite3_adapter.loadLibrary();
  return sqlite3_adapter.Sqlite3Peer();
}

Future<SqlitePeer> _driftPeer() async {
  await drift_adapter.loadLibrary();
  return drift_adapter.DriftPeer();
}

Future<SqlitePeer> _sqliteAsyncPeer() async {
  await sqlite_async_adapter.loadLibrary();
  return sqlite_async_adapter.SqliteAsyncPeer();
}

Future<SqlitePeer> _resqlitePeer() async {
  await resqlite_adapter.loadLibrary();
  return resqlite_adapter.ResqlitePeer();
}

Future<PeerScenarioResult> runPeerScenario({
  required String peerName,
  required String scenarioName,
  required String databasePath,
  int rows = 100,
  String? traceRegionPath,
}) async {
  final peer = await createPeer(peerName);
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
      case streamInitialDrainTextScenario:
        return await _runStreamInitialDrain(
          peer,
          rows: rows,
          shape: _StreamInitialDrainShape.text,
        );
      case streamInitialDrainRowidScenario:
        return await _runStreamInitialDrain(
          peer,
          rows: rows,
          shape: _StreamInitialDrainShape.rowid,
        );
      case streamInitialDrainIndexedIntScenario:
        return await _runStreamInitialDrain(
          peer,
          rows: rows,
          shape: _StreamInitialDrainShape.indexedInt,
        );
      case manyStreamsWriterThroughputScenario:
        return await _runManyStreamsWriterThroughput(peer, rows: rows);
      case sustainedWriterPressureScenario:
        return await _runSustainedWriterPressure(peer, rows: rows);
      case sqliteDiagnosticsScenario:
        return await _runSqliteDiagnostics(
          peer,
          rows: rows,
          traceRegionPath: traceRegionPath,
        );
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

  final prng = math.Random(feedPagingSeed);
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
  await _selectLatestFeedPage(peer, math.min(feedPagingPageSize, rows));
  warmup.stop();

  final measured = Stopwatch()..start();
  await _walkFeedPages(peer, rows: rows);
  await _applyFeedLikeWrites(peer, rows: rows);
  final latest = await _selectLatestFeedPage(
    peer,
    math.min(feedPagingPageSize, rows),
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
  final chunkSize = math.min(syncBurstChunkSize, math.max(1, rows));
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

  final mergeRows = math.min(syncBurstMergeRowsPerRound, math.max(1, rows));
  for (var round = 0; round < syncBurstMergeRounds; round++) {
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
  final expected = rows + syncBurstMergeRounds * mergeRows;
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
  final userCount = chatUserCount(rows);
  final conversationCount = chatConversationCount(rows);
  final seedMessages = chatSeedMessageCount(rows);

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
    chatSimZipfExponent,
    chatSimSeed ^ 0xABC,
  );
  final seedPrng = math.Random(chatSimSeed ^ 0xDEF);
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
  final warmupOps = chatWarmupOps(rows);
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
  final payload = List.filled(largeWorkingSetPayloadLength, 'x').join();
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
  final prng = math.Random(largeWorkingSetSeed);
  for (var i = 0; i < largeWorkingSetPointQueries(rows); i++) {
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
  final rangeLimit = largeWorkingSetRangeLimit(rows);
  for (var i = 0; i < largeWorkingSetRangeScans(rows); i++) {
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
  final rowCount = reactiveRowCount(rows);
  final streamCount = reactiveStreamCount(rows);
  final writeCount = reactiveWriteCount(rows);

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

    final prng = math.Random(reactiveSeed);
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
  final rowCount = fanoutRowCount(rows);
  final streamCount = fanoutStreamCount(rows);
  final writeCount = fanoutWriteCount(rows);

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

    final prng = math.Random(fanoutSeed);
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

Future<PeerScenarioResult> _runStreamInitialDrain(
  SqlitePeer peer, {
  required int rows,
  required _StreamInitialDrainShape shape,
}) async {
  final reactive = _requireReactivePeer(peer);
  final streamCount = streamInitialDrainStreamCount(rows);
  final repeatCount = streamInitialDrainRepeatCount(rows);
  final rowsPerStream = streamInitialDrainRowsPerStream(rows);
  final rowCount = streamCount * rowsPerStream;

  final setup = Stopwatch()..start();
  await peer.execute('DROP TABLE IF EXISTS tracelite_stream_initial_items');
  await peer.execute(
    'CREATE TABLE tracelite_stream_initial_items('
    'id INTEGER PRIMARY KEY, '
    'owner_id INTEGER NOT NULL, '
    'lookup_key TEXT NOT NULL UNIQUE, '
    'body TEXT NOT NULL, '
    'updated_at INTEGER NOT NULL)',
  );
  await peer.execute(
    'CREATE INDEX tracelite_stream_initial_owner '
    'ON tracelite_stream_initial_items(owner_id)',
  );
  await peer.executeBatch(
    'INSERT INTO tracelite_stream_initial_items'
    '(id, owner_id, lookup_key, body, updated_at) VALUES (?, ?, ?, ?, ?)',
    [
      for (var id = 1; id <= rowCount; id++)
        [
          id,
          ((id - 1) ~/ rowsPerStream) + 1,
          'item_$id',
          'body_$id',
          0,
        ],
    ],
  );
  setup.stop();

  final warmup = Stopwatch()..start();
  await _runStreamInitialDrainCycle(
    reactive,
    shape: shape,
    streamCount: streamCount,
    rowsPerStream: rowsPerStream,
  );
  warmup.stop();

  final measured = Stopwatch()..start();
  for (var i = 0; i < repeatCount; i++) {
    await _runStreamInitialDrainCycle(
      reactive,
      shape: shape,
      streamCount: streamCount,
      rowsPerStream: rowsPerStream,
    );
  }
  measured.stop();

  return PeerScenarioResult(
    setupElapsedNs: _elapsedNs(setup),
    warmupElapsedNs: _elapsedNs(warmup),
    measuredElapsedNs: _elapsedNs(measured),
    measurements: {
      'shape': shape.name,
      'stream_count': streamCount,
      'repeat_count': repeatCount,
      'rows_per_stream':
          shape == _StreamInitialDrainShape.indexedInt ? rowsPerStream : 1,
    },
  );
}

Future<void> _runStreamInitialDrainCycle(
  ReactiveSqlitePeer reactive, {
  required _StreamInitialDrainShape shape,
  required int streamCount,
  required int rowsPerStream,
}) async {
  final iterators = <StreamIterator<List<Map<String, Object?>>>>[];
  try {
    for (var i = 0; i < streamCount; i++) {
      final query = _streamInitialDrainQuery(
        shape,
        index: i,
        rowsPerStream: rowsPerStream,
      );
      iterators.add(
        StreamIterator(
          reactive.watch(
            query.sql,
            parameters: query.parameters,
            readsFrom: const {'tracelite_stream_initial_items'},
          ),
        ),
      );
    }

    final emitted = await Future.wait([
      for (final iterator in iterators) iterator.moveNext(),
    ]).timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException(
        'timed out waiting for ${shape.name} stream initial emissions',
      ),
    );
    if (emitted.any((value) => !value)) {
      throw StateError('${shape.name} stream closed before initial emission');
    }

    final expectedRows =
        shape == _StreamInitialDrainShape.indexedInt ? rowsPerStream : 1;
    for (final iterator in iterators) {
      if (iterator.current.length != expectedRows) {
        throw StateError(
          '${shape.name} initial drain returned '
          '${iterator.current.length} row(s), expected $expectedRows',
        );
      }
      _consumeRows(iterator.current);
    }
  } finally {
    await Future.wait([for (final iterator in iterators) iterator.cancel()]);
  }
}

_StreamInitialDrainQuery _streamInitialDrainQuery(
  _StreamInitialDrainShape shape, {
  required int index,
  required int rowsPerStream,
}) {
  final id = (index * rowsPerStream) + 1;
  return switch (shape) {
    _StreamInitialDrainShape.text => _StreamInitialDrainQuery(
        'SELECT id, body, updated_at '
        'FROM tracelite_stream_initial_items WHERE lookup_key = ?',
        ['item_$id'],
      ),
    _StreamInitialDrainShape.rowid => _StreamInitialDrainQuery(
        'SELECT id, body, updated_at '
        'FROM tracelite_stream_initial_items WHERE id = ?',
        [id],
      ),
    _StreamInitialDrainShape.indexedInt => _StreamInitialDrainQuery(
        'SELECT id, body, updated_at '
        'FROM tracelite_stream_initial_items WHERE owner_id = ? ORDER BY id',
        [index + 1],
      ),
  };
}

Future<PeerScenarioResult> _runManyStreamsWriterThroughput(
  SqlitePeer peer, {
  required int rows,
}) async {
  final reactive = _requireReactivePeer(peer);
  final rowCount = writerRowCount(rows);
  final streamCount = writerStreamCount(rows);
  final writeCount = writerWriteCount(rows);

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

Future<PeerScenarioResult> _runSustainedWriterPressure(
  SqlitePeer peer, {
  required int rows,
}) async {
  final reactive = _requireReactivePeer(peer);
  final rowCount = sustainedWriterPressureRowCount(rows);
  final producerCount = sustainedWriterPressureProducerCount(rows);
  final writesPerProducer = sustainedWriterPressureWritesPerProducer(rows);
  final streamCount = sustainedWriterPressureStreamCount(rows);
  final totalWrites = sustainedWriterPressureTotalWrites(rows);

  final setup = Stopwatch()..start();
  await peer.execute('DROP TABLE IF EXISTS tracelite_writer_pressure');
  await peer.execute(
    'CREATE TABLE tracelite_writer_pressure('
    'id INTEGER PRIMARY KEY, '
    'producer_id INTEGER NOT NULL, '
    'value INTEGER NOT NULL, '
    'payload TEXT NOT NULL)',
  );
  await peer.executeBatch(
    'INSERT INTO tracelite_writer_pressure('
    'id, producer_id, value, payload'
    ') VALUES (?, ?, ?, ?)',
    [
      for (var i = 1; i <= rowCount; i++)
        [i, i % producerCount, 0, 'payload_$i'],
    ],
  );
  setup.stop();

  var warmupElapsedNs = 0;

  final noStreams = Stopwatch()..start();
  await _runConcurrentWriterUpdates(
    peer,
    phaseSeed: writerPressureSeed,
    producerCount: producerCount,
    writesPerProducer: writesPerProducer,
    rowCount: rowCount,
    valueBase: 100000,
  );
  noStreams.stop();
  final noStreamsWriteLoopElapsedNs = _elapsedNs(noStreams);

  var aggregateEmissions = 0;
  final aggregateSub = reactive.watch(
    'SELECT COUNT(*) AS c, SUM(value) AS total '
    'FROM tracelite_writer_pressure',
    readsFrom: const {'tracelite_writer_pressure'},
  ).listen((_) => aggregateEmissions++);
  try {
    final aggregateWarmup = Stopwatch()..start();
    await _waitUntil(
      () => aggregateEmissions > 0,
      timeout: const Duration(seconds: 10),
      description: '${peer.name} writer pressure aggregate initial emission',
    );
    aggregateWarmup.stop();
    warmupElapsedNs += _elapsedNs(aggregateWarmup);
    aggregateEmissions = 0;

    final aggregate = Stopwatch()..start();
    final aggregateWriteLoop = Stopwatch()..start();
    await _runConcurrentWriterUpdates(
      peer,
      phaseSeed: writerPressureSeed ^ 0xA66,
      producerCount: producerCount,
      writesPerProducer: writesPerProducer,
      rowCount: rowCount,
      valueBase: 200000,
    );
    aggregateWriteLoop.stop();
    final aggregateWriteLoopEmissions = aggregateEmissions;
    final aggregateSettle = Stopwatch()..start();
    await _waitForQuietReactiveWindow(() => aggregateEmissions);
    aggregateSettle.stop();
    aggregate.stop();
    final aggregateMeasuredEmissions = aggregateEmissions;
    final aggregateSettleEmissions =
        aggregateMeasuredEmissions - aggregateWriteLoopEmissions;
    final aggregateElapsedNs = _elapsedNs(aggregate);
    final aggregateWriteLoopElapsedNs = _elapsedNs(aggregateWriteLoop);
    final aggregateSettleElapsedNs = _elapsedNs(aggregateSettle);

    final keyedEmitCounts = List<int>.filled(streamCount, 0);
    final keyedSubs = <StreamSubscription<List<Map<String, Object?>>>>[];
    for (var id = 1; id <= streamCount; id++) {
      final index = id - 1;
      keyedSubs.add(
        reactive.watch(
          'SELECT id, value FROM tracelite_writer_pressure WHERE id = ?',
          parameters: [id],
          readsFrom: const {'tracelite_writer_pressure'},
        ).listen((_) => keyedEmitCounts[index]++),
      );
    }
    try {
      final keyedWarmup = Stopwatch()..start();
      await _waitUntil(
        () => keyedEmitCounts.every((count) => count > 0),
        timeout: const Duration(seconds: 10),
        description: '${peer.name} writer pressure keyed initial emissions',
      );
      keyedWarmup.stop();
      warmupElapsedNs += _elapsedNs(keyedWarmup);
      for (var i = 0; i < keyedEmitCounts.length; i++) {
        keyedEmitCounts[i] = 0;
      }

      final watchedHits = _writerPressureWatchedHits(
        phaseSeed: writerPressureSeed ^ 0xC0DE,
        producerCount: producerCount,
        writesPerProducer: writesPerProducer,
        rowCount: rowCount,
        watchedRows: streamCount,
      );

      final keyed = Stopwatch()..start();
      final keyedWriteLoop = Stopwatch()..start();
      await _runConcurrentWriterUpdates(
        peer,
        phaseSeed: writerPressureSeed ^ 0xC0DE,
        producerCount: producerCount,
        writesPerProducer: writesPerProducer,
        rowCount: rowCount,
        valueBase: 300000,
      );
      keyedWriteLoop.stop();
      final keyedWriteLoopEmissions = keyedEmitCounts.fold<int>(0, _sum);
      final keyedSettle = Stopwatch()..start();
      await _waitForQuietReactiveWindow(
        () => keyedEmitCounts.fold<int>(0, _sum),
      );
      keyedSettle.stop();
      keyed.stop();
      final keyedMeasuredEmissions = keyedEmitCounts.fold<int>(0, _sum);
      final keyedSettleEmissions =
          keyedMeasuredEmissions - keyedWriteLoopEmissions;
      final keyedElapsedNs = _elapsedNs(keyed);
      final keyedWriteLoopElapsedNs = _elapsedNs(keyedWriteLoop);
      final keyedSettleElapsedNs = _elapsedNs(keyedSettle);

      return PeerScenarioResult(
        setupElapsedNs: _elapsedNs(setup),
        warmupElapsedNs: warmupElapsedNs,
        measuredElapsedNs:
            noStreamsWriteLoopElapsedNs + aggregateElapsedNs + keyedElapsedNs,
        measurements: {
          'row_count': rowCount,
          'producer_count': producerCount,
          'writes_per_producer': writesPerProducer,
          'total_writes_per_phase': totalWrites,
          'stream_count': streamCount,
          'no_streams_elapsed_ns': noStreamsWriteLoopElapsedNs,
          'no_streams_write_loop_elapsed_ns': noStreamsWriteLoopElapsedNs,
          'aggregate_stream_elapsed_ns': aggregateElapsedNs,
          'aggregate_stream_write_loop_elapsed_ns': aggregateWriteLoopElapsedNs,
          'aggregate_stream_settle_elapsed_ns': aggregateSettleElapsedNs,
          'keyed_streams_elapsed_ns': keyedElapsedNs,
          'keyed_streams_write_loop_elapsed_ns': keyedWriteLoopElapsedNs,
          'keyed_streams_settle_elapsed_ns': keyedSettleElapsedNs,
          'aggregate_emissions': aggregateMeasuredEmissions,
          'aggregate_stream_write_loop_emissions': aggregateWriteLoopEmissions,
          'aggregate_stream_settle_emissions': aggregateSettleEmissions,
          'keyed_emissions': keyedMeasuredEmissions,
          'keyed_streams_write_loop_emissions': keyedWriteLoopEmissions,
          'keyed_streams_settle_emissions': keyedSettleEmissions,
          'observed_watched_pk_hits': watchedHits,
        },
      );
    } finally {
      await Future.wait([for (final sub in keyedSubs) sub.cancel()]);
    }
  } finally {
    await aggregateSub.cancel();
  }
}

Future<PeerScenarioResult> _runSqliteDiagnostics(
  SqlitePeer peer, {
  required int rows,
  String? traceRegionPath,
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
    regionPath: traceRegionPath,
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
  final pageSize = math.min(feedPagingPageSize, math.max(1, rows));
  int? lastCreatedAt;
  int? lastId;
  for (var page = 0; page < feedPagingPageCount; page++) {
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
  final prng = math.Random(feedPagingSeed);
  final writes = math.min(feedPagingLikeWrites, math.max(1, rows));
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
  final prng = math.Random(chatSimSeed);
  final zipf = _ZipfianSampler(
    conversationCount,
    chatSimZipfExponent,
    chatSimSeed,
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

Future<void> _runConcurrentWriterUpdates(
  SqlitePeer peer, {
  required int phaseSeed,
  required int producerCount,
  required int writesPerProducer,
  required int rowCount,
  required int valueBase,
}) async {
  await Future.wait([
    for (var producer = 0; producer < producerCount; producer++)
      () async {
        for (var i = 0; i < writesPerProducer; i++) {
          final id = _writerPressureTargetId(
            phaseSeed: phaseSeed,
            producer: producer,
            index: i,
            rowCount: rowCount,
          );
          await peer.execute(
            'UPDATE tracelite_writer_pressure '
            'SET value = ?, payload = ? WHERE id = ?',
            [
              valueBase + producer * writesPerProducer + i,
              'p${producer}_$i',
              id,
            ],
          );
        }
      }(),
  ]);
}

int _writerPressureWatchedHits({
  required int phaseSeed,
  required int producerCount,
  required int writesPerProducer,
  required int rowCount,
  required int watchedRows,
}) {
  var hits = 0;
  for (var producer = 0; producer < producerCount; producer++) {
    for (var i = 0; i < writesPerProducer; i++) {
      final id = _writerPressureTargetId(
        phaseSeed: phaseSeed,
        producer: producer,
        index: i,
        rowCount: rowCount,
      );
      if (id <= watchedRows) hits++;
    }
  }
  return hits;
}

int _writerPressureTargetId({
  required int phaseSeed,
  required int producer,
  required int index,
  required int rowCount,
}) {
  final value =
      phaseSeed + producer * 131 + index * 17 + (producer ^ index) * 7;
  return (value.remainder(rowCount)) + 1;
}

void _consumeRows(List<Map<String, Object?>> rows) {
  for (final row in rows) {
    for (final value in row.values) {
      if (identical(value, value)) continue;
    }
  }
}

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

enum _StreamInitialDrainShape {
  text,
  rowid,
  indexedInt,
}

final class _StreamInitialDrainQuery {
  const _StreamInitialDrainQuery(this.sql, this.parameters);

  final String sql;
  final List<Object?> parameters;
}

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
