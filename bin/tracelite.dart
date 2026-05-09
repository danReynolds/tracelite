import 'dart:io';

import 'package:tracelite/tracelite.dart';

import 'src/peer.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    _usage(exitCode: args.isEmpty ? 64 : 0);
  }

  final command = args.first;
  switch (command) {
    case 'report':
      _report(args.skip(1).toList());
    case 'compare':
      await _compare(args.skip(1).toList());
    case '_run-peer':
      await _runPeer(args.skip(1).toList());
    default:
      stderr.writeln('unknown command: $command');
      _usage();
  }
}

void _report(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('report expects exactly one region or trace path');
    _usage();
  }
  final path = args.single;
  final trace = Trace.loadRegion(path);
  stdout.write(trace.toMarkdownReport());
}

Future<void> _compare(List<String> args) async {
  final options = _parseOptions(args);
  final scenario = options['scenario'] ?? narrowBatchInsertScenario;
  final interfaces = (options['interfaces'] ?? defaultPeerNames.join(','))
      .split(',')
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toList();
  final rows = int.tryParse(options['rows'] ?? '100') ?? 100;

  final shim = File('build/libsqlite_traced.dylib');
  if (!shim.existsSync()) {
    stderr.writeln('missing ${shim.path}; build it with:');
    stderr.writeln('  cc -dynamiclib -O2 -Inative native/tracelite_runtime.c '
        'native/shim_sqlite3.c -Wl,-reexport-lsqlite3 '
        '-o build/libsqlite_traced.dylib');
    exit(66);
  }
  final resolverShim = File('libsqlite_traced.dylib');
  resolverShim.writeAsBytesSync(shim.readAsBytesSync());

  final tempRoot = Directory.systemTemp.createTempSync('tracelite-compare-');
  try {
    final results = <_PeerTraceResult>[];
    for (final peer in interfaces) {
      final regionPath = '${tempRoot.path}/$peer.tlt-region';
      final databasePath = '${tempRoot.path}/$peer.db';
      TraceRegion.createFile(regionPath);

      final child = await Process.run(
        'dart',
        [
          'run',
          'bin/tracelite.dart',
          '_run-peer',
          '--peer=$peer',
          '--scenario=$scenario',
          '--database=$databasePath',
          '--rows=$rows',
        ],
        environment: {
          'TRACELITE_REGION': regionPath,
          'DYLD_LIBRARY_PATH': Directory.current.absolute.path,
          'LD_LIBRARY_PATH': Directory.current.absolute.path,
        },
      );

      if (child.exitCode != 0) {
        results.add(
          _PeerTraceResult.failed(
            peer: peer,
            stderr: child.stderr.toString(),
            stdout: child.stdout.toString(),
          ),
        );
        continue;
      }

      final trace = Trace.loadRegion(regionPath);
      results.add(_PeerTraceResult(peer: peer, trace: trace));
    }

    _printCompareReport(scenario: scenario, rows: rows, results: results);
  } finally {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  }
}

Future<void> _runPeer(List<String> args) {
  final options = _parseOptions(args);
  final peer = options['peer'];
  final scenario = options['scenario'] ?? narrowBatchInsertScenario;
  final database = options['database'];
  final rows = int.tryParse(options['rows'] ?? '100') ?? 100;
  if (peer == null || database == null) {
    stderr.writeln('_run-peer requires --peer and --database');
    exit(64);
  }
  return runPeerScenario(
    peerName: peer,
    scenarioName: scenario,
    databasePath: database,
    rows: rows,
  );
}

Map<String, String> _parseOptions(List<String> args) {
  final result = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      stderr.writeln('unexpected argument: $arg');
      _usage();
    }
    final withoutPrefix = arg.substring(2);
    final equals = withoutPrefix.indexOf('=');
    if (equals >= 0) {
      result[withoutPrefix.substring(0, equals)] =
          withoutPrefix.substring(equals + 1);
    } else {
      if (i + 1 >= args.length) {
        stderr.writeln('missing value for $arg');
        _usage();
      }
      result[withoutPrefix] = args[++i];
    }
  }
  return result;
}

void _printCompareReport({
  required String scenario,
  required int rows,
  required List<_PeerTraceResult> results,
}) {
  stdout
    ..writeln('# tracelite compare')
    ..writeln()
    ..writeln('Scenario: `$scenario`')
    ..writeln('Rows: $rows')
    ..writeln()
    ..writeln(
      '> tracelite compares shared SQL execution paths, not overall '
      'library quality, API ergonomics, type-system coverage, or reactive '
      'feature sets.',
    )
    ..writeln()
    ..writeln('| peer | status | events | spans | sqlite3_step spans | total |')
    ..writeln('|---|---|---:|---:|---:|---:|');

  for (final result in results) {
    if (result.trace == null) {
      stdout.writeln('| `${result.peer}` | failed | 0 | 0 | 0 | - |');
      continue;
    }
    final trace = result.trace!;
    final status = trace.events.isEmpty ? 'no trace' : 'ok';
    final stepStats =
        trace.spans.ofType(BuiltinSpans.sqlite3Step).durationStats();
    stdout.writeln(
      '| `${result.peer}` | $status | ${trace.events.length} | '
      '${trace.spans.length} | ${stepStats.count} | '
      '${formatDurationNs(trace.spans.durationStats().totalNs)} |',
    );
  }

  final missingTrace = results
      .where((result) => result.trace != null && result.trace!.events.isEmpty)
      .map((result) => result.peer)
      .toList();
  if (missingTrace.isNotEmpty) {
    stdout
      ..writeln()
      ..writeln('## Trace gaps')
      ..writeln()
      ..writeln(
        'These peers completed the scenario but emitted no SQLite shim events: '
        '${missingTrace.map((peer) => '`$peer`').join(', ')}.',
      )
      ..writeln(
        'That means the current shim is not on their SQLite call path yet.',
      );
  }

  for (final result in results.where((result) => result.trace == null)) {
    stdout
      ..writeln()
      ..writeln('## ${result.peer} failure')
      ..writeln()
      ..writeln('```text')
      ..write(result.stderr.isEmpty ? result.stdout : result.stderr)
      ..writeln('```');
  }
}

class _PeerTraceResult {
  _PeerTraceResult({required this.peer, required this.trace})
      : stdout = '',
        stderr = '';

  _PeerTraceResult.failed({
    required this.peer,
    required this.stdout,
    required this.stderr,
  }) : trace = null;

  final String peer;
  final Trace? trace;
  final String stdout;
  final String stderr;
}

Never _usage({int exitCode = 64}) {
  stderr.writeln('usage:');
  stderr.writeln('  dart run bin/tracelite.dart report <region-path>');
  stderr.writeln('  dart run bin/tracelite.dart compare '
      '--scenario=narrow-batch-insert '
      '--interfaces=sqlite3,drift,sqlite_async,resqlite');
  exit(exitCode);
}
