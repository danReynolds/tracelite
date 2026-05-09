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
const String chatSimScenario = 'chat-sim';
const String largeWorkingSetScenario = 'large-working-set';

const List<String> defaultScenarioNames = [
  narrowBatchInsertScenario,
  pointSelectScenario,
  feedPagingScenario,
  syncBurstScenario,
  chatSimScenario,
  largeWorkingSetScenario,
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
    chatSimScenario => {
        'operations': rows,
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
