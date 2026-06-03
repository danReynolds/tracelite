import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:tracelite/src/native_artifacts.dart' as native_artifacts;
import 'package:tracelite/tracelite.dart';

Future<void> main(List<String> args) async {
  if (args.any((arg) => arg == '--help' || arg == '-h')) {
    _usage(code: 0);
    return;
  }
  if (args.isNotEmpty) {
    stderr.writeln('unexpected arguments: ${args.join(' ')}');
    _usage(code: 64);
    return;
  }

  try {
    await _runSmoke();
  } on _SmokeFailure catch (failure) {
    stderr.writeln(failure.message);
    exitCode = failure.exitCode;
  }
}

Future<void> _runSmoke() async {
  final shimBuildCommand = _sqliteShimBuildCommand();
  if (shimBuildCommand == null) {
    throw _SmokeFailure(
      66,
      'sqlite shim smoke is not implemented for ${Platform.operatingSystem}.',
    );
  }

  final shim = File(native_artifacts.sqliteShimLibraryPath());
  if (!shim.existsSync()) {
    throw _SmokeFailure(66, '${shim.path} not built; run:\n$shimBuildCommand');
  }
  _copyResolverShim(shim);

  final nativeAssets = _writeSqliteNativeAssets();
  try {
    await _verifyDefaultCapture(shim.parent);
    await _verifyRawCapture(shim.parent);
  } finally {
    nativeAssets.restore();
  }
}

Future<void> _verifyDefaultCapture(Directory shimDirectory) async {
  final trace = await _runSqliteUser(
    shimDirectory: shimDirectory,
    regionName: 'tracelite-shim-$pid.tlt-region',
  );

  final registered = trace.tracks.where((track) => track.state >= 2).toList();
  _check(registered.isNotEmpty, 'shim should register as a producer');
  _check(
    registered.any((track) => track.processName == 'libsqlite_traced'),
    'standalone sqlite_traced shim should keep a stable producer name',
  );

  final spanCounts = <int, int>{};
  for (final event in trace.events) {
    spanCounts[event.spanId] = (spanCounts[event.spanId] ?? 0) + 1;
  }

  stdout.writeln(
    '  ${trace.events.length} total events from package:sqlite3 workload',
  );
  stdout.writeln('  Span breakdown:');
  final sortedEntries = spanCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final entry in sortedEntries) {
    stdout.writeln('    ${kSpanNames[entry.key] ?? hexSpanId(entry.key)}'
        ': ${entry.value} (x2 = begin+end)');
  }

  final beginCount = trace.events.where((event) => event.isBegin).length;
  final endCount = trace.events.where((event) => event.isEnd).length;
  _check(beginCount == endCount, 'every BEGIN should be matched by an END');
  _check(
    trace.diagnostics.unmatchedBeginEvents == 0,
    'trace should not contain unmatched BEGIN events',
  );
  _check(
    trace.diagnostics.unmatchedEndEvents == 0,
    'trace should not contain unmatched END events',
  );

  _check(
    spanCounts[BuiltinSpans.sqlite3PrepareV2] != null ||
        spanCounts[BuiltinSpans.sqlite3PrepareV3] != null,
    'the workload must trigger prepare_v2 or prepare_v3',
  );
  _check(
    (spanCounts[BuiltinSpans.sqlite3Step] ?? 0) > 0,
    'the workload must execute at least one step',
  );
  _check(
    (spanCounts[BuiltinSpans.sqlite3Finalize] ?? 0) > 0,
    'the workload must finalize prepared statements',
  );

  final bindCount = (spanCounts[BuiltinSpans.sqlite3BindText] ?? 0) +
      (spanCounts[BuiltinSpans.sqlite3BindInt64] ?? 0);
  _check(bindCount > 0, 'INSERTs / SELECT use parameter binding');

  final stringPool = trace.strings.values.join('\n');
  _check(stringPool.contains('sqlfp:v1:'), 'SQL fingerprints should be stored');
  _check(
    stringPool.contains('INSERT INTO T VALUES (?, ?)'),
    'fingerprinted INSERT statement should be stored',
  );
  for (final secret in const [
    'alice',
    'bob',
    'carol',
    'literal_secret',
  ]) {
    _check(!stringPool.contains(secret), 'default capture leaked $secret');
  }

  final report = trace.toMarkdownReport();
  _check(report.contains('sqlite3_step'), 'report should include sqlite3_step');
  _check(report.contains('tracelite report'), 'report should render');
  _check(report.contains('SQL Fingerprints'), 'report should include SQL');
  _check(
    report.contains('INSERT INTO T VALUES (?, ?)'),
    'report should include the fingerprinted INSERT statement',
  );

  stdout.writeln('  ${trace.spans.length} spans paired by Trace.loadRegion');
  stdout.writeln('  shim intercepts real sqlite3 calls successfully');
}

Future<void> _verifyRawCapture(Directory shimDirectory) async {
  final trace = await _runSqliteUser(
    shimDirectory: shimDirectory,
    regionName: 'tracelite-shim-raw-$pid.tlt-region',
    sqlCapture: 'raw',
  );

  final stringPool = trace.strings.values.join('\n');
  _check(
    stringPool.contains("SELECT 'literal_secret' AS hidden"),
    'raw capture should include literal SQL',
  );
  _check(
    stringPool.contains('INSERT INTO t VALUES (?, ?)'),
    'raw capture should include INSERT SQL',
  );
  _check(
    stringPool.contains('SELECT id, name FROM t WHERE id > ?'),
    'raw capture should include SELECT SQL',
  );
  _check(
    !stringPool.contains('sqlfp:v1:'),
    'raw capture should not emit fingerprints',
  );
}

Future<Trace> _runSqliteUser({
  required Directory shimDirectory,
  required String regionName,
  String? sqlCapture,
}) async {
  final regionPath = _joinPath(Directory.systemTemp.path, regionName);
  try {
    TraceRegion.createFile(regionPath);
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        '--enable-experiment=native-assets',
        '--packages=${_packageConfigPath()}',
        _joinPath('example', 'sqlite3_user.dart'),
      ],
      environment: _sqliteUserEnvironment(
        regionPath: regionPath,
        shimDirectory: shimDirectory,
        sqlCapture: sqlCapture,
      ),
      workingDirectory: Directory.current.path,
    );

    _check(
      result.exitCode == 0,
      'sqlite3_user exited non-zero. stderr:\n${result.stderr}\n'
      'stdout:\n${result.stdout}',
    );
    _check(
      result.stdout.toString().contains('bob'),
      'sqlite3_user should print query results',
    );

    return Trace.loadRegion(regionPath);
  } finally {
    try {
      File(regionPath).deleteSync();
    } catch (_) {}
  }
}

void _copyResolverShim(File shim) {
  final resolverShim = File(native_artifacts.sqliteShimLibraryName());
  resolverShim.writeAsBytesSync(shim.readAsBytesSync());
}

_NativeAssetsSnapshot _writeSqliteNativeAssets() {
  final file = File(_joinPath('.dart_tool', 'native_assets.yaml'));
  final previous = file.existsSync() ? file.readAsStringSync() : null;
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${jsonEncode({
          'format-version': [1, 0, 0],
          'native-assets': {
            _nativeAssetsTarget(): {
              'package:sqlite3/src/ffi/libsqlite3.g.dart': [
                'system',
                native_artifacts.sqliteShimLibraryName(),
              ],
            },
          },
        })}\n',
  );
  return _NativeAssetsSnapshot(file, previous);
}

String _nativeAssetsTarget() {
  final target = ffi.Abi.current().toString();
  if (const {
    'linux_arm64',
    'linux_x64',
    'macos_arm64',
    'macos_x64',
    'windows_arm64',
    'windows_x64',
  }.contains(target)) {
    return target;
  }
  throw _SmokeFailure(
    66,
    'sqlite native-assets smoke is not implemented for ABI $target.',
  );
}

String? _sqliteShimBuildCommand() {
  final sqliteAmalgamation =
      Platform.environment['TRACELITE_SQLITE_AMALGAMATION'];
  return native_artifacts.sqliteShimBuildCommand(
    embeddedSqliteSourcePath:
        sqliteAmalgamation == null || sqliteAmalgamation.isEmpty
            ? null
            : sqliteAmalgamation,
  );
}

Map<String, String> _sqliteUserEnvironment({
  required String regionPath,
  required Directory shimDirectory,
  String? sqlCapture,
}) {
  final shimPath = shimDirectory.absolute.path;
  final inheritedPath =
      Platform.environment['PATH'] ?? Platform.environment['Path'] ?? '';
  return {
    'TRACELITE_REGION': regionPath,
    if (sqlCapture != null) 'TRACELITE_SQL_CAPTURE': sqlCapture,
    'DYLD_LIBRARY_PATH': shimPath,
    'LD_LIBRARY_PATH': shimPath,
    'PATH': inheritedPath.isEmpty
        ? shimPath
        : '$shimPath${Platform.pathSeparator}$inheritedPath',
  };
}

String _packageConfigPath() {
  return File(_joinPath('.dart_tool', 'package_config.json')).absolute.path;
}

String _joinPath(String first, String second) {
  return '$first${Platform.pathSeparator}$second';
}

void _check(bool condition, String message) {
  if (!condition) {
    throw _SmokeFailure(65, message);
  }
}

void _usage({required int code}) {
  stdout.writeln(
    'usage: dart --packages=.dart_tool/package_config.json '
    'tool/sqlite_shim_smoke.dart',
  );
  stdout.writeln(
    'Set TRACELITE_SQLITE_AMALGAMATION=/path/to/sqlite3.c on Windows.',
  );
  if (code != 0) {
    exitCode = code;
  }
}

class _SmokeFailure implements Exception {
  _SmokeFailure(this.exitCode, this.message);

  final int exitCode;
  final String message;
}

class _NativeAssetsSnapshot {
  _NativeAssetsSnapshot(this.file, this.previous);

  final File file;
  final String? previous;

  void restore() {
    if (previous == null) {
      try {
        file.deleteSync();
      } catch (_) {}
    } else {
      file.writeAsStringSync(previous!);
    }
  }
}
