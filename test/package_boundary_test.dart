import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('published dependencies stay core-only', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    final dependencies = (pubspec['dependencies'] as YamlMap)
        .keys
        .cast<Object?>()
        .map((key) => key.toString())
        .toSet();

    expect(dependencies, containsAll(<String>['ffi', 'yaml']));
    expect(
      dependencies,
      isNot(contains(anyOf('drift', 'sqlite3', 'sqlite_async', 'resqlite'))),
      reason:
          'Peer adapters belong to the source-checkout benchmark CLI until the '
          'companion CLI package split lands. The recorder package must stay '
          'safe for peer libraries to depend on.',
    );
  });
}
