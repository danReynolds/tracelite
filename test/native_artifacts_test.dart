import 'dart:io';

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

  test('runtime build commands are explicit about supported platforms', () {
    expect(
      native_artifacts.runtimeBuildCommand(operatingSystem: 'macos'),
      allOf(
        contains('-dynamiclib'),
        contains('native/tracelite_runtime.c'),
        contains('build/libtracelite_runtime.dylib'),
      ),
    );
    expect(
      native_artifacts.runtimeBuildCommand(operatingSystem: 'linux'),
      allOf(
        contains('-shared -fPIC'),
        contains('native/tracelite_runtime.c'),
        contains('build/libtracelite_runtime.so'),
      ),
    );
    expect(
      native_artifacts.runtimeBuildCommand(operatingSystem: 'windows'),
      allOf(
        contains('-shared'),
        contains('native/tracelite_runtime.c'),
        contains('build/libtracelite_runtime.dll'),
      ),
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

  test('windows embedded shim plan renames traced symbols behind wrappers', () {
    final plan = native_artifacts.sqliteEmbeddedShimBuildPlan(
      operatingSystem: 'windows',
      sqliteAmalgamationPath: 'third_party/sqlite3.c',
    );
    expect(plan, isNotNull);
    expect(plan!.steps, hasLength(3));

    final command = plan.shellCommand;
    expect(command, contains('third_party/sqlite3.c'));
    expect(command, contains('build/sqlite_traced.dll'));
    expect(command, contains('TRACELITE_SQLITE3_EMBEDDED'));
    expect(command, contains('TRACELITE_SQLITE_PRODUCER_NAME'));
    expect(command, contains('libsqlite_traced'));
    expect(command, contains('SQLITE_API=__declspec(dllexport)'));
    for (final symbol in native_artifacts.sqliteShimWrappedSymbols) {
      expect(command, contains('-D$symbol=tlt_$symbol'));
    }
  });

  test('windows sqlite shim command accepts an embedded sqlite source', () {
    final command = native_artifacts.sqliteShimBuildCommand(
      operatingSystem: 'windows',
      embeddedSqliteSourcePath: r'C:\sqlite\sqlite3.c',
    );
    expect(command, isNotNull);
    expect(command, contains(r'C:\sqlite\sqlite3.c'));
    expect(command, contains('build/sqlite_traced.dll'));
  });

  test('sqlite shim unsupported platforms explain the support boundary', () {
    expect(
      native_artifacts.sqliteShimUnsupportedReason(operatingSystem: 'macos'),
      isNull,
    );
    expect(
      native_artifacts.sqliteShimUnsupportedReason(operatingSystem: 'linux'),
      isNull,
    );
    expect(
      native_artifacts.sqliteShimUnsupportedReason(operatingSystem: 'windows'),
      allOf(
        contains('full sqlite3 ABI'),
        contains('sqlite_traced.dll'),
        contains('does not re-export dependency symbols'),
        contains('SQLite amalgamation'),
      ),
    );
  });

  test('sqlite wrapped-symbol build list matches exported C wrappers', () {
    final source = File('native/shim_sqlite3.c').readAsStringSync();
    expect(
      source,
      contains('#ifndef TRACELITE_SQLITE3_EMBEDDED\n#include <dlfcn.h>'),
    );
    for (final symbol in native_artifacts.sqliteShimWrappedSymbols) {
      final wrapperPattern = RegExp(
        r'TLT_SQLITE_API\s+'
                r'(?:int|long long|double|const unsigned char\*|'
                r'const void\*|const char\*)\s+' +
            RegExp.escape(symbol) +
            r'\s*\(',
      );
      expect(
        source,
        matches(wrapperPattern),
        reason: '$symbol must be exported by the shim wrapper',
      );
      expect(
        source,
        matches(RegExp(r'\btlt_' + RegExp.escape(symbol) + r'\s*\(')),
        reason: '$symbol must have an embedded-mode renamed target',
      );
    }
  });
}
