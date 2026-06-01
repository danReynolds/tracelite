import 'package:test/test.dart';
import 'package:tracelite/src/native_artifacts.dart' as native_artifacts;

void main() {
  test('runtime library paths follow platform dynamic-library naming', () {
    expect(
      native_artifacts.defaultRuntimeLibraryPath(operatingSystem: 'macos'),
      'build/libtracelite_runtime.dylib',
    );
    expect(
      native_artifacts.defaultRuntimeLibraryPath(operatingSystem: 'linux'),
      'build/libtracelite_runtime.so',
    );
    expect(
      native_artifacts.defaultRuntimeLibraryPath(operatingSystem: 'windows'),
      'build/libtracelite_runtime.dll',
    );
  });

  test('sqlite shim resolver names match native-hook lookup conventions', () {
    expect(
      native_artifacts.sqliteShimLibraryPath(operatingSystem: 'macos'),
      'build/libsqlite_traced.dylib',
    );
    expect(
      native_artifacts.sqliteShimLibraryPath(operatingSystem: 'linux'),
      'build/libsqlite_traced.so',
    );
    expect(
      native_artifacts.sqliteShimLibraryPath(operatingSystem: 'windows'),
      'build/sqlite_traced.dll',
    );
  });

  test('sqlite shim build commands are explicit about supported platforms', () {
    expect(
      native_artifacts.sqliteShimBuildCommand(operatingSystem: 'macos'),
      allOf(
        contains('-dynamiclib'),
        contains('-Wl,-reexport-lsqlite3'),
        contains('build/libsqlite_traced.dylib'),
      ),
    );
    expect(
      native_artifacts.sqliteShimBuildCommand(operatingSystem: 'linux'),
      allOf(
        contains('-shared -fPIC'),
        contains('-Wl,--no-as-needed'),
        contains('-lsqlite3'),
        contains('build/libsqlite_traced.so'),
      ),
    );
    expect(
      native_artifacts.sqliteShimBuildCommand(operatingSystem: 'windows'),
      isNull,
    );
  });
}
