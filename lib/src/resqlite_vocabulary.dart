import 'vocabulary.dart';

abstract final class ResqliteTraceSpans {
  static const int databaseSelect = 0x4000;
  static const int databaseSelectBytes = 0x4001;
  static const int databaseExecute = 0x4002;
  static const int databaseExecuteBatch = 0x4003;

  static const int writerHandle = 0x4010;
  static const int readerHandle = 0x4011;
  static const int readerPoolDispatch = 0x4012;

  static const int streamInvalidate = 0x4020;
  static const int streamIntersectDependencies = 0x4021;
  static const int streamSelectIfChanged = 0x4022;

  static const int profileWorkload = 0x4030;
  static const int profileSample = 0x4031;
}

abstract final class ResqliteTraceCounters {
  static const int rowsDecoded = 0x4100;
  static const int cellsDecoded = 0x4101;

  static const int invalidateUs = 0x4110;
  static const int invalidateCount = 0x4111;
  static const int intersectionUs = 0x4112;
  static const int intersectionEntries = 0x4113;

  static const int dispatcherParkedTotal = 0x4120;
  static const int dispatcherWakeRetryTotal = 0x4121;

  static const int profileRowsDecoded = 0x4140;
  static const int profileCellsDecoded = 0x4141;
  static const int profileInvalidateUs = 0x4142;
  static const int profileInvalidateCount = 0x4143;
  static const int profileIntersectionUs = 0x4144;
  static const int profileIntersectionEntries = 0x4145;
  static const int profileDispatcherParkedTotal = 0x4146;
  static const int profileDispatcherWakeRetryTotal = 0x4147;
  static const int profileDispatcherMaxParkedConcurrent = 0x4148;

  static const int fanoutWriterUs = 0x4150;
  static const int fanoutYieldUs = 0x4151;
  static const int fanoutTotalUs = 0x4152;
  static const int fanoutInvalidateUs = 0x4153;
  static const int fanoutIntersectionUs = 0x4154;
  static const int fanoutIntersectionEntries = 0x4155;
}

abstract final class ResqliteTraceGauges {
  static const int dispatcherCurrentParked = 0x4122;
  static const int dispatcherMaxParkedConcurrent = 0x4123;

  static const int sqlitePageCacheBytes = 0x4130;
  static const int sqliteSchemaBytes = 0x4131;
  static const int sqliteStmtBytes = 0x4132;
  static const int walBytes = 0x4133;
  static const int streamCount = 0x4134;
  static const int readerBusy = 0x4135;
  static const int rssBeforeBytes = 0x4136;
  static const int rssAfterBytes = 0x4137;
  static const int rssPeakBytes = 0x4138;
}

const TraceVocabulary resqliteTraceVocabulary = TraceVocabulary(
  name: 'resqlite',
  definitions: [
    TraceDefinition(
      id: ResqliteTraceSpans.databaseSelect,
      name: 'resqlite.database.select',
      category: 'resqlite',
      kind: TraceDefinitionKind.span,
    ),
    TraceDefinition(
      id: ResqliteTraceSpans.databaseSelectBytes,
      name: 'resqlite.database.select_bytes',
      category: 'resqlite',
      kind: TraceDefinitionKind.span,
    ),
    TraceDefinition(
      id: ResqliteTraceSpans.databaseExecute,
      name: 'resqlite.database.execute',
      category: 'resqlite',
      kind: TraceDefinitionKind.span,
    ),
    TraceDefinition(
      id: ResqliteTraceSpans.databaseExecuteBatch,
      name: 'resqlite.database.execute_batch',
      category: 'resqlite',
      kind: TraceDefinitionKind.span,
    ),
    TraceDefinition(
      id: ResqliteTraceSpans.writerHandle,
      name: 'resqlite.writer.handle',
      category: 'resqlite',
      kind: TraceDefinitionKind.span,
    ),
    TraceDefinition(
      id: ResqliteTraceSpans.readerHandle,
      name: 'resqlite.reader.handle',
      category: 'resqlite',
      kind: TraceDefinitionKind.span,
    ),
    TraceDefinition(
      id: ResqliteTraceSpans.readerPoolDispatch,
      name: 'resqlite.reader_pool.dispatch',
      category: 'resqlite',
      kind: TraceDefinitionKind.span,
    ),
    TraceDefinition(
      id: ResqliteTraceSpans.streamInvalidate,
      name: 'resqlite.stream.invalidate',
      category: 'resqlite',
      kind: TraceDefinitionKind.span,
    ),
    TraceDefinition(
      id: ResqliteTraceSpans.streamIntersectDependencies,
      name: 'resqlite.stream.intersect_dependencies',
      category: 'resqlite',
      kind: TraceDefinitionKind.span,
    ),
    TraceDefinition(
      id: ResqliteTraceSpans.streamSelectIfChanged,
      name: 'resqlite.stream.select_if_changed',
      category: 'resqlite',
      kind: TraceDefinitionKind.span,
    ),
    TraceDefinition(
      id: ResqliteTraceSpans.profileWorkload,
      name: 'resqlite.profile.workload',
      category: 'resqlite',
      kind: TraceDefinitionKind.span,
    ),
    TraceDefinition(
      id: ResqliteTraceSpans.profileSample,
      name: 'resqlite.profile.sample',
      category: 'resqlite',
      kind: TraceDefinitionKind.span,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.rowsDecoded,
      name: 'resqlite.rows_decoded',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.cellsDecoded,
      name: 'resqlite.cells_decoded',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.invalidateUs,
      name: 'resqlite.invalidate_us',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.invalidateCount,
      name: 'resqlite.invalidate_count',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.intersectionUs,
      name: 'resqlite.intersection_us',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.intersectionEntries,
      name: 'resqlite.intersection_entries',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.dispatcherParkedTotal,
      name: 'resqlite.dispatcher_parked_total',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.dispatcherWakeRetryTotal,
      name: 'resqlite.dispatcher_wake_retry_total',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceGauges.dispatcherCurrentParked,
      name: 'resqlite.dispatcher_current_parked',
      category: 'resqlite.gauge',
      kind: TraceDefinitionKind.gauge,
    ),
    TraceDefinition(
      id: ResqliteTraceGauges.dispatcherMaxParkedConcurrent,
      name: 'resqlite.dispatcher_max_parked_concurrent',
      category: 'resqlite.gauge',
      kind: TraceDefinitionKind.gauge,
    ),
    TraceDefinition(
      id: ResqliteTraceGauges.sqlitePageCacheBytes,
      name: 'resqlite.sqlite_page_cache_bytes',
      category: 'resqlite.gauge',
      kind: TraceDefinitionKind.gauge,
    ),
    TraceDefinition(
      id: ResqliteTraceGauges.sqliteSchemaBytes,
      name: 'resqlite.sqlite_schema_bytes',
      category: 'resqlite.gauge',
      kind: TraceDefinitionKind.gauge,
    ),
    TraceDefinition(
      id: ResqliteTraceGauges.sqliteStmtBytes,
      name: 'resqlite.sqlite_stmt_bytes',
      category: 'resqlite.gauge',
      kind: TraceDefinitionKind.gauge,
    ),
    TraceDefinition(
      id: ResqliteTraceGauges.walBytes,
      name: 'resqlite.wal_bytes',
      category: 'resqlite.gauge',
      kind: TraceDefinitionKind.gauge,
    ),
    TraceDefinition(
      id: ResqliteTraceGauges.streamCount,
      name: 'resqlite.stream_count',
      category: 'resqlite.gauge',
      kind: TraceDefinitionKind.gauge,
    ),
    TraceDefinition(
      id: ResqliteTraceGauges.readerBusy,
      name: 'resqlite.reader_busy',
      category: 'resqlite.gauge',
      kind: TraceDefinitionKind.gauge,
    ),
    TraceDefinition(
      id: ResqliteTraceGauges.rssBeforeBytes,
      name: 'resqlite.rss_before_bytes',
      category: 'resqlite.gauge',
      kind: TraceDefinitionKind.gauge,
    ),
    TraceDefinition(
      id: ResqliteTraceGauges.rssAfterBytes,
      name: 'resqlite.rss_after_bytes',
      category: 'resqlite.gauge',
      kind: TraceDefinitionKind.gauge,
    ),
    TraceDefinition(
      id: ResqliteTraceGauges.rssPeakBytes,
      name: 'resqlite.rss_peak_bytes',
      category: 'resqlite.gauge',
      kind: TraceDefinitionKind.gauge,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.profileRowsDecoded,
      name: 'resqlite.profile.rows_decoded',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.profileCellsDecoded,
      name: 'resqlite.profile.cells_decoded',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.profileInvalidateUs,
      name: 'resqlite.profile.invalidate_us',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.profileInvalidateCount,
      name: 'resqlite.profile.invalidate_count',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.profileIntersectionUs,
      name: 'resqlite.profile.intersection_us',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.profileIntersectionEntries,
      name: 'resqlite.profile.intersection_entries',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.profileDispatcherParkedTotal,
      name: 'resqlite.profile.dispatcher_parked_total',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.profileDispatcherWakeRetryTotal,
      name: 'resqlite.profile.dispatcher_wake_retry_total',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.profileDispatcherMaxParkedConcurrent,
      name: 'resqlite.profile.dispatcher_max_parked_concurrent',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.fanoutWriterUs,
      name: 'resqlite.fanout.writer_us',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.fanoutYieldUs,
      name: 'resqlite.fanout.yield_us',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.fanoutTotalUs,
      name: 'resqlite.fanout.total_us',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.fanoutInvalidateUs,
      name: 'resqlite.fanout.invalidate_us',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.fanoutIntersectionUs,
      name: 'resqlite.fanout.intersection_us',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
    TraceDefinition(
      id: ResqliteTraceCounters.fanoutIntersectionEntries,
      name: 'resqlite.fanout.intersection_entries',
      category: 'resqlite.counter',
      kind: TraceDefinitionKind.counter,
    ),
  ],
);
