import 'dart:io';

import 'package:test/test.dart';
import 'package:tracelite/tracelite.dart';

void main() {
  test('create-region writes a loadable sparse region file', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-create-region-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final regionPath = '${tempDir.path}/external.tlt-region';
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'create-region',
        '--out=$regionPath',
        '--ring-data-words=16384',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'create-region failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    expect(File(regionPath).existsSync(), isTrue);
    final trace = Trace.loadRegion(regionPath);
    expect(trace.events, isEmpty);
    expect(trace.header.maxProducers, kDefaultMaxProducers);
    expect(trace.tracks, isEmpty);
  });
}
