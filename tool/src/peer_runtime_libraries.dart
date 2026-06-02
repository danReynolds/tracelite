import 'dart:convert';
import 'dart:io';

import 'package:tracelite/src/native_artifacts.dart' as native_artifacts;

List<String> workerRuntimeLibraryPaths({Iterable<String> peers = const []}) {
  final peerSet = peers.toSet();
  final includeAll = peerSet.isEmpty;
  final usesSqliteShim = includeAll ||
      peerSet.any((peer) =>
          peer == 'sqlite3' || peer == 'drift' || peer == 'sqlite_async');
  final usesResqlite = includeAll || peerSet.contains('resqlite');
  final paths = <String>{};

  void addPath(String path) {
    if (path.isEmpty) return;
    final file = File(path);
    if (file.existsSync()) {
      paths.add(file.absolute.path);
    }
  }

  if (usesResqlite) {
    addPath(native_artifacts.defaultRuntimeLibraryPath());
  }
  if (usesSqliteShim) {
    addPath(native_artifacts.sqliteShimLibraryPath());
    addPath(native_artifacts.sqliteShimLibraryName());
  }

  final nativeAssets = File('.dart_tool/native_assets.yaml');
  if (nativeAssets.existsSync()) {
    final raw = nativeAssets.readAsStringSync();
    final jsonStart = raw.indexOf('{');
    if (jsonStart >= 0) {
      final decoded = jsonDecode(raw.substring(jsonStart));
      if (decoded is Map<String, Object?>) {
        final assets = decoded['native-assets'];
        if (assets is Map) {
          for (final platformAssets in assets.values) {
            if (platformAssets is! Map) continue;
            for (final entry in platformAssets.entries) {
              final key = entry.key;
              final asset = entry.value;
              if (key is String &&
                  key.contains('package:resqlite') &&
                  !usesResqlite) {
                continue;
              }
              if (key is String &&
                  key.contains('package:sqlite3') &&
                  !usesSqliteShim) {
                continue;
              }
              if (key is String &&
                  key.contains('sqlite3_connection_pool') &&
                  !usesResqlite) {
                continue;
              }
              if (asset is! List || asset.length < 2) continue;
              final kind = asset[0];
              final location = asset[1];
              if (location is! String) continue;
              if (kind == 'absolute' || kind == 'system') {
                addPath(location);
              }
            }
          }
        }
      }
    }
  }

  return paths.toList(growable: false);
}
