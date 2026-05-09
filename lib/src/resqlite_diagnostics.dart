import 'resqlite_vocabulary.dart';
import 'session.dart';

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
