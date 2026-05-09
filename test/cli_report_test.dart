import 'dart:io';

import 'package:test/test.dart';
import 'package:tracelite/tracelite.dart';

void main() {
  test('tracelite report prints markdown for a runtime region', () async {
    final producer = File('build/test_producer');
    if (!producer.existsSync()) {
      fail('build/test_producer not built; run:\n'
          '  cc -std=c11 -O2 -Inative native/tracelite_runtime.c '
          'native/test_producer.c -o build/test_producer');
    }

    final regionPath =
        '${Directory.systemTemp.path}/tracelite-cli-$pid.tlt-region';
    addTearDown(() {
      try {
        File(regionPath).deleteSync();
      } catch (_) {}
    });

    TraceRegion.createFile(regionPath);

    final producerResult = await Process.run(
      producer.absolute.path,
      const [],
      environment: {'TRACELITE_REGION': regionPath},
    );
    expect(producerResult.exitCode, 0,
        reason: 'producer exited non-zero: ${producerResult.stderr}');

    final reportResult = await Process.run(
      'dart',
      ['run', 'bin/tracelite.dart', 'report', regionPath],
    );
    expect(reportResult.exitCode, 0,
        reason: 'report command failed: ${reportResult.stderr}');

    final output = reportResult.stdout.toString();
    expect(output, contains('# tracelite report'));
    expect(output, contains('sqlite3_step'));
    expect(output, contains('| span | count | p50 | p90 | p99 | total |'));
  });
}
