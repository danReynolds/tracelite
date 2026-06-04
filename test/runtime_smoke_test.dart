// End-to-end smoke test for the producer runtime.
//
// The C producer writes into a tracelite mmap region. Dart then decodes
// the same region through the shared Trace API used by reports and the CLI.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tracelite/tracelite.dart';

import 'src/test_producer.dart';

void main() {
  test('runtime round-trip: C producer writes, Dart reader parses', () async {
    final producer = await ensureTestProducerBuilt();

    final regionPath =
        '${Directory.systemTemp.path}/tracelite-smoke-$pid.tlt-region';
    addTearDown(() {
      try {
        File(regionPath).deleteSync();
      } catch (_) {}
    });

    TraceRegion.createFile(regionPath);

    final result = await Process.run(
      producer.absolute.path,
      const [],
      environment: {'TRACELITE_REGION': regionPath},
    );
    expect(result.exitCode, 0,
        reason: 'producer exited non-zero: ${result.stderr}');

    final trace = Trace.loadRegion(regionPath);
    expect(trace.header.formatMajor, kFormatVersion[0]);

    final ended = trace.tracks.where((track) => track.state == 3).toList();
    expect(ended.length, 1,
        reason: 'one producer should have registered and detached');
    expect(ended.single.kind, 2, reason: 'kind should be c_thread (2)');
    expect(ended.single.processName, 'test_producer');

    final events = trace.events;
    expect(events.length, 18,
        reason: 'expected 3 cycles × (prepare,step,reset) × (begin,end) = 18');
    expect(trace.spans.length, 9,
        reason: '18 begin/end events should pair into 9 spans');
    expect(trace.diagnostics.unmatchedBeginEvents, 0);
    expect(trace.diagnostics.unmatchedEndEvents, 0);

    for (var cycle = 0; cycle < 3; cycle++) {
      final base = cycle * 6;
      expect(events[base + 0].tag, traceTagBegin,
          reason: 'cycle $cycle slot 0: BEGIN prepare');
      expect(events[base + 0].spanId, BuiltinSpans.sqlite3PrepareV3);

      expect(events[base + 1].tag, traceTagEnd);
      expect(events[base + 1].spanId, BuiltinSpans.sqlite3PrepareV3);

      expect(events[base + 2].tag, traceTagBegin);
      expect(events[base + 2].spanId, BuiltinSpans.sqlite3Step);

      expect(events[base + 3].tag, traceTagEnd);
      expect(events[base + 3].spanId, BuiltinSpans.sqlite3Step);

      expect(events[base + 4].tag, traceTagBegin);
      expect(events[base + 4].spanId, BuiltinSpans.sqlite3Reset);

      expect(events[base + 5].tag, traceTagEnd);
      expect(events[base + 5].spanId, BuiltinSpans.sqlite3Reset);
    }

    var last = 0;
    for (final event in events) {
      expect(event.timestampNs, greaterThanOrEqualTo(last),
          reason: 'timestamps must be monotonic');
      last = event.timestampNs;
    }

    final beginStep = events[2];
    expect(beginStep.args.length, 1,
        reason: 'BEGIN sqlite3_step has 1 arg (stmt)');
    expect(beginStep.args[0], 0xfeedface,
        reason: 'BEGIN sqlite3_step arg matches fake_stmt from producer');

    final endStep = events[3];
    expect(endStep.args.length, 1, reason: 'END sqlite3_step has 1 arg (rc)');
    expect(endStep.args[0], 101, reason: 'rc = SQLITE_DONE');

    expect(trace.strings.values, contains('test_producer'));
    expect(
        trace.strings.values, contains('UPDATE wide SET a = ? WHERE id = ?'));

    final report = trace.toMarkdownReport();
    expect(report, contains('sqlite3_step'));
    expect(report, contains('| span | count | p50 | p90 | p99 | total |'));

    print('  ${events.length} events round-tripped through mmap region');
    print('  ${trace.spans.length} spans paired by Trace.loadRegion');
  });
}
