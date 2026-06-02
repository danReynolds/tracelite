import 'dart:math' as math;

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

const List<String> defaultPeerNames = [
  'sqlite3',
  'drift',
  'sqlite_async',
  'resqlite',
];

final class PeerNameListError implements Exception {
  const PeerNameListError(this.message);

  final String message;

  @override
  String toString() => message;
}

List<String> parsePeerNames(String value, {bool allowEmpty = false}) {
  final names = value
      .split(',')
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toList(growable: false);
  if (names.isEmpty) {
    if (allowEmpty) return names;
    throw PeerNameListError(
      'must include at least one peer: ${defaultPeerNames.join(', ')}',
    );
  }

  final unknown = [
    for (final name in names)
      if (!defaultPeerNames.contains(name)) name,
  ];
  if (unknown.isNotEmpty) {
    throw PeerNameListError(
      'contains unknown peer ${_quotedList(unknown)}; expected one of '
      '${defaultPeerNames.join(', ')}',
    );
  }

  final seen = <String>{};
  final duplicate = names.where((name) => !seen.add(name)).toList();
  if (duplicate.isNotEmpty) {
    throw PeerNameListError(
      'contains duplicate peer ${_quotedList(duplicate)}; expected each peer '
      'at most once from ${defaultPeerNames.join(', ')}',
    );
  }

  return names;
}

String _quotedList(List<String> values) {
  if (values.length == 1) return '"${values.single}"';
  return values.map((value) => '"$value"').join(', ');
}

const int feedPagingSeed = 0xFEED;
const int feedPagingPageSize = 10;
const int feedPagingPageCount = 4;
const int feedPagingLikeWrites = 8;
const int syncBurstChunkSize = 25;
const int syncBurstMergeRounds = 3;
const int syncBurstMergeRowsPerRound = 10;
const int chatSimSeed = 0x5EED;
const double chatSimZipfExponent = 1.0;
const int largeWorkingSetSeed = 0xB16B00B5;
const int largeWorkingSetPayloadLength = 128;
const int reactiveSeed = 0xBEEF;
const int fanoutSeed = 0xCAFEF0;

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
        'seed': feedPagingSeed,
        'page_size': math.min(feedPagingPageSize, math.max(1, rows)),
        'page_count': feedPagingPageCount,
        'like_writes': math.min(feedPagingLikeWrites, math.max(1, rows)),
        'measured_operations': [
          'keyset_page_select',
          'point_update',
          'latest_page_select',
        ],
      },
    syncBurstScenario => {
        'rows': rows,
        'required_capabilities': ['sql', 'batch'],
        'bulk_chunk_size': math.min(syncBurstChunkSize, math.max(1, rows)),
        'merge_rounds': syncBurstMergeRounds,
        'merge_rows_per_round': math.min(
          syncBurstMergeRowsPerRound,
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
        'warmup_operations': chatWarmupOps(rows),
        'users': chatUserCount(rows),
        'conversations': chatConversationCount(rows),
        'seed_messages': chatSeedMessageCount(rows),
        'seed': chatSimSeed,
        'zipf_exponent': chatSimZipfExponent,
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
        'seed': largeWorkingSetSeed,
        'payload_bytes': largeWorkingSetPayloadLength,
        'point_queries': largeWorkingSetPointQueries(rows),
        'range_scans': largeWorkingSetRangeScans(rows),
        'range_scan_limit': largeWorkingSetRangeLimit(rows),
        'measured_operations': [
          'random_point_select',
          'range_scan_select',
          'pragma_shrink_memory',
        ],
      },
    keyedPkSubscriptionsScenario => {
        'rows': reactiveRowCount(rows),
        'stream_count': reactiveStreamCount(rows),
        'write_count': reactiveWriteCount(rows),
        'seed': reactiveSeed,
        'required_capabilities': ['sql', 'reactive'],
        'measured_operations': [
          'stream_initial_drain',
          'random_pk_update',
          'stream_settle',
        ],
      },
    highCardinalityFanoutScenario => {
        'rows': fanoutRowCount(rows),
        'stream_count': fanoutStreamCount(rows),
        'write_count': fanoutWriteCount(rows),
        'seed': fanoutSeed,
        'required_capabilities': ['sql', 'reactive'],
        'measured_operations': [
          'partition_stream_initial_drain',
          'random_partition_update',
          'stream_settle',
        ],
      },
    manyStreamsWriterThroughputScenario => {
        'rows': writerRowCount(rows),
        'stream_count': writerStreamCount(rows),
        'write_count': writerWriteCount(rows),
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

int chatUserCount(int rows) => math.max(10, rows * 2);

int chatConversationCount(int rows) => math.max(4, rows);

int chatSeedMessageCount(int rows) => math.max(20, rows * 20);

int chatWarmupOps(int rows) => math.min(rows ~/ 10, math.max(0, rows - 1));

int largeWorkingSetPointQueries(int rows) => math.max(1, rows ~/ 2);

int largeWorkingSetRangeScans(int rows) => math.max(1, rows ~/ 20);

int largeWorkingSetRangeLimit(int rows) => math.min(25, math.max(1, rows));

int reactiveStreamCount(int rows) => math.min(50, math.max(1, rows));

int reactiveWriteCount(int rows) => math.min(200, math.max(10, rows * 5));

int reactiveRowCount(int rows) =>
    math.max(reactiveStreamCount(rows) * 4, rows * 100);

int fanoutStreamCount(int rows) => math.min(100, math.max(2, rows));

int fanoutWriteCount(int rows) => math.min(200, math.max(10, rows * 5));

int fanoutRowCount(int rows) =>
    math.max(fanoutStreamCount(rows) * 10, rows * 100);

int writerStreamCount(int rows) => math.min(50, math.max(2, rows));

int writerWriteCount(int rows) => math.min(100, math.max(10, rows * 4));

int writerRowCount(int rows) =>
    math.max(writerStreamCount(rows) * 10, rows * 100);
