import 'resqlite_vocabulary.dart';
import 'session.dart';

void recordResqliteDecodeMetrics(
  TraceSession session, {
  required int rowsDecoded,
  required int cellsDecoded,
  int? correlationId,
}) {
  session.registerVocabulary(resqliteTraceVocabulary);
  session.counter(
    ResqliteTraceCounters.rowsDecoded,
    rowsDecoded,
    correlationId: correlationId,
  );
  session.counter(
    ResqliteTraceCounters.cellsDecoded,
    cellsDecoded,
    correlationId: correlationId,
  );
}

void recordResqliteStreamMetrics(
  TraceSession session, {
  required int invalidateUs,
  required int invalidateCount,
  required int intersectionUs,
  required int intersectionEntries,
  int? correlationId,
}) {
  session.registerVocabulary(resqliteTraceVocabulary);
  session.counter(
    ResqliteTraceCounters.invalidateUs,
    invalidateUs,
    correlationId: correlationId,
  );
  session.counter(
    ResqliteTraceCounters.invalidateCount,
    invalidateCount,
    correlationId: correlationId,
  );
  session.counter(
    ResqliteTraceCounters.intersectionUs,
    intersectionUs,
    correlationId: correlationId,
  );
  session.counter(
    ResqliteTraceCounters.intersectionEntries,
    intersectionEntries,
    correlationId: correlationId,
  );
}

void recordResqliteDispatcherMetrics(
  TraceSession session, {
  required int parkedTotal,
  required int wakeRetryTotal,
  required int currentParked,
  required int maxParkedConcurrent,
  int? correlationId,
}) {
  session.registerVocabulary(resqliteTraceVocabulary);
  session.counter(
    ResqliteTraceCounters.dispatcherParkedTotal,
    parkedTotal,
    correlationId: correlationId,
  );
  session.counter(
    ResqliteTraceCounters.dispatcherWakeRetryTotal,
    wakeRetryTotal,
    correlationId: correlationId,
  );
  session.gauge(
    ResqliteTraceGauges.dispatcherCurrentParked,
    currentParked,
    correlationId: correlationId,
  );
  session.gauge(
    ResqliteTraceGauges.dispatcherMaxParkedConcurrent,
    maxParkedConcurrent,
    correlationId: correlationId,
  );
}

void recordResqliteDiagnostics(
  TraceSession session, {
  required int sqlitePageCacheBytes,
  required int sqliteSchemaBytes,
  required int sqliteStmtBytes,
  required int walBytes,
  required int streamCount,
  required bool readerBusy,
  int? correlationId,
}) {
  session.registerVocabulary(resqliteTraceVocabulary);
  session.gauge(
    ResqliteTraceGauges.sqlitePageCacheBytes,
    sqlitePageCacheBytes,
    correlationId: correlationId,
  );
  session.gauge(
    ResqliteTraceGauges.sqliteSchemaBytes,
    sqliteSchemaBytes,
    correlationId: correlationId,
  );
  session.gauge(
    ResqliteTraceGauges.sqliteStmtBytes,
    sqliteStmtBytes,
    correlationId: correlationId,
  );
  session.gauge(
    ResqliteTraceGauges.walBytes,
    walBytes,
    correlationId: correlationId,
  );
  session.gauge(
    ResqliteTraceGauges.streamCount,
    streamCount,
    correlationId: correlationId,
  );
  session.gauge(
    ResqliteTraceGauges.readerBusy,
    readerBusy ? 1 : 0,
    correlationId: correlationId,
  );
}
