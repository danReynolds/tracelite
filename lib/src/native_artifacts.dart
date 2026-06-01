import 'dart:io';

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

String runtimeBuildCommand({String? operatingSystem}) {
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

String? sqliteShimBuildCommand({String? operatingSystem}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final output = sqliteShimLibraryPath(operatingSystem: os);
  return switch (os) {
    'macos' => '  cc -dynamiclib -O2 -Inative native/tracelite_runtime.c '
        'native/shim_sqlite3.c -Wl,-reexport-lsqlite3 -o $output',
    'linux' => '  cc -shared -fPIC -O2 -Inative native/tracelite_runtime.c '
        'native/shim_sqlite3.c -lsqlite3 -o $output',
    _ => null,
  };
}
