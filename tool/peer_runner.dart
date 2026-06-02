import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'src/peer.dart';
import 'src/peer_definitions.dart';
import 'src/peer_runtime_libraries.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
  }

  switch (args.first) {
    case 'run':
      await _runPeer(args.skip(1).toList());
    case 'worker':
      await _runPeerWorker(args.skip(1).toList());
    default:
      stderr.writeln('unknown peer runner command: ${args.first}');
      _usage();
  }
}

void _usage() {
  stderr.writeln('usage: dart tool/peer_runner.dart run|worker');
  exit(64);
}

Future<void> _runPeer(List<String> args) async {
  final options = _parseOptions(args);
  final peer = options['peer'];
  final scenario = options['scenario'] ?? narrowBatchInsertScenario;
  final database = options['database'];
  final metrics = options['metrics'];
  final traceRegionPath = options['trace-region'];
  final rows = int.tryParse(options['rows'] ?? '100') ?? 100;
  if (peer == null || database == null) {
    stderr.writeln('peer run requires --peer and --database');
    exit(64);
  }
  final peerName = _peerNameOption('--peer', peer);
  final stopwatch = Stopwatch()..start();
  PeerScenarioResult? result;
  UnsupportedPeerScenario? unsupported;
  try {
    result = await runPeerScenario(
      peerName: peerName,
      scenarioName: scenario,
      databasePath: database,
      rows: rows,
      traceRegionPath: traceRegionPath,
    );
  } on UnsupportedPeerScenario catch (error) {
    unsupported = error;
  } finally {
    stopwatch.stop();
    _writePeerMetrics(
      metricsPath: metrics,
      stopwatch: stopwatch,
      result: result,
      unsupported: unsupported,
    );
  }
}

Future<void> _runPeerWorker(List<String> args) async {
  final options = _parseOptions(args);
  final unexpectedOptions =
      options.keys.where((key) => key != 'peers').toList();
  if (unexpectedOptions.isNotEmpty) {
    stderr.writeln(
      'peer worker received unexpected option: --${unexpectedOptions.first}',
    );
    exit(64);
  }
  final peers = _peerListOption(
    '--peers',
    options['peers'] ?? '',
    allowEmpty: true,
  );

  final runtimes = _openWorkerRuntimeBindings(peers: peers);
  if (runtimes.isEmpty) {
    stderr.writeln(
      'peer worker could not find a Tracelite runtime library. '
      'Build native artifacts and run dart pub get before using '
      '--runner=worker.',
    );
    exit(66);
  }
  stdout.writeln(
    jsonEncode({
      'command': 'ready',
      'runtime_libraries': runtimes.map((runtime) => runtime.path).toList(),
      'native_assets': workerNativeAssetBindings(peers: peers),
    }),
  );
  await stdout.flush();

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    Object? requestId;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('worker request must be a JSON object');
      }
      requestId = decoded['id'];
      if (decoded['command'] == 'shutdown') {
        break;
      }
      stdout.writeln(
        jsonEncode(await _runPeerWorkerRequest(decoded, runtimes)),
      );
      await stdout.flush();
    } on Object catch (error, stackTrace) {
      stdout.writeln(
        jsonEncode({
          if (requestId != null) 'id': requestId,
          'exit_code': 65,
          'stdout': '',
          'stderr': '$error\n$stackTrace',
        }),
      );
      await stdout.flush();
    }
  }
}

Future<Map<String, Object?>> _runPeerWorkerRequest(
  Map<String, Object?> request,
  List<_WorkerRuntimeBinding> runtimes,
) async {
  final id = request['id'];
  final peer = _requiredWorkerString(request, 'peer');
  final scenario = _requiredWorkerString(request, 'scenario');
  final database = _requiredWorkerString(request, 'database');
  final metrics = _requiredWorkerString(request, 'metrics');
  final regionPath = _requiredWorkerString(request, 'region');
  final rows = _requiredWorkerInt(request, 'rows');
  final stopwatch = Stopwatch()..start();
  PeerScenarioResult? result;
  UnsupportedPeerScenario? unsupported;
  var exitCode = 0;
  var stderrText = '';

  try {
    for (final runtime in runtimes) {
      runtime.attach(regionPath);
    }
    try {
      result = await runPeerScenario(
        peerName: peer,
        scenarioName: scenario,
        databasePath: database,
        rows: rows,
        traceRegionPath: regionPath,
      );
    } on UnsupportedPeerScenario catch (error) {
      unsupported = error;
    }
  } on Object catch (error, stackTrace) {
    exitCode = 65;
    stderrText = '$error\n$stackTrace';
  } finally {
    stopwatch.stop();
    _writePeerMetrics(
      metricsPath: metrics,
      stopwatch: stopwatch,
      result: result,
      unsupported: unsupported,
    );
    final resetErrors = <String>[];
    for (final runtime in runtimes.reversed) {
      try {
        runtime.reset();
      } on Object catch (error) {
        resetErrors.add('${runtime.path}: $error');
      }
    }
    if (resetErrors.isNotEmpty) {
      exitCode = 65;
      stderrText = [
        if (stderrText.isNotEmpty) stderrText,
        'peer worker runtime reset failed:',
        ...resetErrors,
      ].join('\n');
    }
  }

  return {
    'id': id,
    'exit_code': exitCode,
    'stdout': '',
    'stderr': stderrText,
    'runtime_libraries': runtimes.map((runtime) => runtime.path).toList(),
  };
}

void _writePeerMetrics({
  required String? metricsPath,
  required Stopwatch stopwatch,
  required PeerScenarioResult? result,
  required UnsupportedPeerScenario? unsupported,
}) {
  if (metricsPath == null || metricsPath.isEmpty) return;
  File(metricsPath).writeAsStringSync(
    jsonEncode({
      'schema': 'tracelite.peer_metrics.v1',
      'status': unsupported == null ? 'ok' : 'unsupported',
      if (unsupported != null) 'unsupported_reason': unsupported.message,
      'scenario_elapsed_ns': stopwatch.elapsedMicroseconds * 1000,
      if (result != null) ...result.toJson(),
    }),
  );
}

Map<String, String> _parseOptions(List<String> args) {
  final result = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      stderr.writeln('unexpected argument: $arg');
      exit(64);
    }
    final withoutPrefix = arg.substring(2);
    final equals = withoutPrefix.indexOf('=');
    if (equals >= 0) {
      result[withoutPrefix.substring(0, equals)] =
          withoutPrefix.substring(equals + 1);
      continue;
    }
    final key = withoutPrefix;
    if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
      result[key] = 'true';
      continue;
    }
    result[key] = args[++i];
  }
  return result;
}

String _peerNameOption(String option, String value) {
  final peers = _peerListOption(option, value);
  if (peers.length != 1) {
    stderr.writeln(
      '$option must name exactly one peer: ${defaultPeerNames.join(', ')}',
    );
    exit(64);
  }
  return peers.single;
}

List<String> _peerListOption(
  String option,
  String value, {
  bool allowEmpty = false,
}) {
  try {
    return parsePeerNames(value, allowEmpty: allowEmpty);
  } on PeerNameListError catch (error) {
    stderr.writeln('$option ${error.message}');
    exit(64);
  }
}

String _requiredWorkerString(Map<String, Object?> request, String key) {
  final value = request[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('worker request missing string "$key"');
}

int _requiredWorkerInt(Map<String, Object?> request, String key) {
  final value = request[key];
  if (value is int) return value;
  throw FormatException('worker request missing int "$key"');
}

typedef _WorkerAttachNative = Int32 Function(Pointer<Utf8>);
typedef _WorkerAttachDart = int Function(Pointer<Utf8>);
typedef _WorkerResetNative = Void Function();
typedef _WorkerResetDart = void Function();

class _WorkerRuntimeBinding {
  _WorkerRuntimeBinding._({
    required this.path,
    required _WorkerAttachDart attach,
    required _WorkerResetDart reset,
  })  : _attach = attach,
        _reset = reset;

  final String path;
  final _WorkerAttachDart _attach;
  final _WorkerResetDart _reset;

  static _WorkerRuntimeBinding? tryOpen(String path) {
    try {
      final library = DynamicLibrary.open(path);
      return _WorkerRuntimeBinding._(
        path: path,
        attach: library.lookupFunction<_WorkerAttachNative, _WorkerAttachDart>(
          'tlt_attach',
        ),
        reset: library.lookupFunction<_WorkerResetNative, _WorkerResetDart>(
          'tlt_reset_runtime',
        ),
      );
    } on Object {
      return null;
    }
  }

  void attach(String regionPath) {
    final pointer = regionPath.toNativeUtf8();
    try {
      final result = _attach(pointer);
      if (result != 0) {
        throw StateError('tlt_attach returned $result');
      }
    } finally {
      calloc.free(pointer);
    }
  }

  void reset() {
    _reset();
  }
}

List<_WorkerRuntimeBinding> _openWorkerRuntimeBindings({
  Iterable<String> peers = const [],
}) {
  return [
    for (final path in workerRuntimeLibraryPaths(peers: peers))
      if (_WorkerRuntimeBinding.tryOpen(path) case final runtime?) runtime,
  ];
}
