import 'dart:io';

const sqliteShimWrappedSymbols = [
  'sqlite3_open',
  'sqlite3_open_v2',
  'sqlite3_close',
  'sqlite3_close_v2',
  'sqlite3_prepare_v3',
  'sqlite3_prepare_v2',
  'sqlite3_step',
  'sqlite3_reset',
  'sqlite3_finalize',
  'sqlite3_bind_int64',
  'sqlite3_bind_int',
  'sqlite3_bind_null',
  'sqlite3_bind_double',
  'sqlite3_bind_text',
  'sqlite3_bind_blob',
  'sqlite3_bind_blob64',
  'sqlite3_clear_bindings',
  'sqlite3_column_count',
  'sqlite3_column_int',
  'sqlite3_column_int64',
  'sqlite3_column_double',
  'sqlite3_column_text',
  'sqlite3_column_blob',
  'sqlite3_column_bytes',
  'sqlite3_exec',
  'sqlite3_changes',
  'sqlite3_total_changes',
  'sqlite3_last_insert_rowid',
  'sqlite3_errcode',
  'sqlite3_errmsg',
];

final class NativeBuildStep {
  const NativeBuildStep(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;

  String get shellCommand =>
      [executable, ...arguments].map(_shellQuote).join(' ');
}

final class NativeBuildPlan {
  const NativeBuildPlan(this.steps);

  final List<NativeBuildStep> steps;

  String get shellCommand =>
      steps.map((step) => '  ${step.shellCommand}').join('\n');
}

String dynamicLibraryExtension({String? operatingSystem}) {
  return switch (operatingSystem ?? Platform.operatingSystem) {
    'macos' => 'dylib',
    'windows' => 'dll',
    _ => 'so',
  };
}

String defaultRuntimeLibraryPath({String? operatingSystem}) {
  return 'build/libtracelite_runtime.'
      '${dynamicLibraryExtension(operatingSystem: operatingSystem)}';
}

String? runtimeBuildCommand({String? operatingSystem}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final output = defaultRuntimeLibraryPath(operatingSystem: os);
  return switch (os) {
    'macos' => '  cc -dynamiclib -O2 -Inative native/tracelite_runtime.c '
        '-o $output',
    'windows' => '  cc -shared -O2 -Inative native/tracelite_runtime.c '
        '-o $output',
    _ => '  cc -shared -fPIC -O2 -Inative native/tracelite_runtime.c '
        '-o $output',
  };
}

String sqliteShimLibraryName({String? operatingSystem}) {
  return switch (operatingSystem ?? Platform.operatingSystem) {
    'windows' => 'sqlite_traced.dll',
    'macos' => 'libsqlite_traced.dylib',
    _ => 'libsqlite_traced.so',
  };
}

String sqliteShimLibraryPath({String? operatingSystem}) {
  return 'build/${sqliteShimLibraryName(operatingSystem: operatingSystem)}';
}

String? sqliteShimUnsupportedReason({String? operatingSystem}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  return switch (os) {
    'windows' => 'Windows SQLite shim tracing requires sqlite_traced.dll to '
        'provide the full sqlite3 ABI. package:sqlite3 resolves SQLite '
        'symbols from sqlite_traced.dll, and Windows does not re-export '
        'dependency symbols from that DLL handle. Build the embedded shim '
        'variant with a SQLite amalgamation source file, or ship a full '
        'forwarding DLL.',
    _ => null,
  };
}

NativeBuildPlan? sqliteShimBuildPlan({
  String? operatingSystem,
  String? embeddedSqliteSourcePath,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final output = sqliteShimLibraryPath(operatingSystem: os);
  return switch (os) {
    'macos' => NativeBuildPlan([
        NativeBuildStep('cc', [
          '-dynamiclib',
          '-O2',
          '-Inative',
          'native/tracelite_runtime.c',
          'native/shim_sqlite3.c',
          '-Wl,-reexport-lsqlite3',
          '-o',
          output,
        ]),
      ]),
    'linux' => NativeBuildPlan([
        NativeBuildStep('cc', [
          '-shared',
          '-fPIC',
          '-O2',
          '-Inative',
          'native/tracelite_runtime.c',
          'native/shim_sqlite3.c',
          '-Wl,--no-as-needed',
          '-lsqlite3',
          '-o',
          output,
        ]),
      ]),
    'windows' when embeddedSqliteSourcePath != null =>
      sqliteEmbeddedShimBuildPlan(
        operatingSystem: os,
        sqliteAmalgamationPath: embeddedSqliteSourcePath,
      ),
    _ => null,
  };
}

String? sqliteShimBuildCommand({
  String? operatingSystem,
  String? embeddedSqliteSourcePath,
}) {
  return sqliteShimBuildPlan(
    operatingSystem: operatingSystem,
    embeddedSqliteSourcePath: embeddedSqliteSourcePath,
  )?.shellCommand;
}

NativeBuildPlan? sqliteEmbeddedShimBuildPlan({
  String? operatingSystem,
  required String sqliteAmalgamationPath,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  if (os != 'windows') return null;

  const sqliteObject = 'build/sqlite3_tracelite_embedded.o';
  const shimObject = 'build/shim_sqlite3_embedded.o';
  return NativeBuildPlan([
    NativeBuildStep('cc', [
      '-O2',
      '-DSQLITE_API=__declspec(dllexport)',
      for (final symbol in sqliteShimWrappedSymbols) '-D$symbol=tlt_$symbol',
      '-c',
      sqliteAmalgamationPath,
      '-o',
      sqliteObject,
    ]),
    NativeBuildStep('cc', [
      '-O2',
      '-DTRACELITE_SQLITE3_EMBEDDED',
      '-DTRACELITE_SQLITE_PRODUCER_NAME="libsqlite_traced"',
      '-Inative',
      '-c',
      'native/shim_sqlite3.c',
      '-o',
      shimObject,
    ]),
    NativeBuildStep('cc', [
      '-shared',
      '-O2',
      '-Inative',
      'native/tracelite_runtime.c',
      shimObject,
      sqliteObject,
      '-o',
      sqliteShimLibraryPath(operatingSystem: os),
    ]),
  ]);
}

String _shellQuote(String argument) {
  if (argument.isEmpty) return "''";
  if (RegExp(r'^[A-Za-z0-9_./:=+,-]+$').hasMatch(argument)) {
    return argument;
  }
  return "'${argument.replaceAll("'", "'\"'\"'")}'";
}
