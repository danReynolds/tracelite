import 'dart:convert';
import 'dart:io';

import 'package:tracelite/src/native_artifacts.dart' as native_artifacts;

List<String> workerRuntimeLibraryPaths({Iterable<String> peers = const []}) {
  final needs = _runtimeNeeds(peers);
  final paths = <String>{};

  void addPath(String path) {
    if (path.isEmpty) return;
    final file = File(path);
    if (file.existsSync()) {
      paths.add(file.absolute.path);
    }
  }

  if (needs.usesResqlite) {
    addPath(native_artifacts.defaultRuntimeLibraryPath());
  }
  if (needs.usesSqliteShim) {
    addPath(native_artifacts.sqliteShimLibraryPath());
    addPath(native_artifacts.sqliteShimLibraryName());
  }

  for (final asset in workerNativeAssetBindings(peers: peers)) {
    final kind = asset['kind'];
    final location = asset['location'];
    if (location is String && (kind == 'absolute' || kind == 'system')) {
      addPath(location);
    }
  }

  return paths.toList(growable: false);
}

List<Map<String, Object?>> workerNativeAssetBindings({
  Iterable<String> peers = const [],
}) {
  final needs = _runtimeNeeds(peers);
  final bindings = <Map<String, Object?>>[];
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
              if (key is! String || !_includeNativeAssetKey(key, needs)) {
                continue;
              }
              if (asset is! List || asset.length < 2) continue;
              final kind = asset[0];
              final location = asset[1];
              if (location is! String) continue;
              bindings.add({
                'asset': key,
                'kind': kind,
                'location': location,
                if (kind == 'absolute') 'exists': File(location).existsSync(),
              });
            }
          }
        }
      }
    }
  }

  return bindings;
}

bool _includeNativeAssetKey(String key, _RuntimeNeeds needs) {
  if (key.contains('package:resqlite') && !needs.usesResqlite) {
    return false;
  }
  if (key.contains('package:sqlite3') && !needs.usesSqliteShim) {
    return false;
  }
  if (key.contains('sqlite3_connection_pool') && !needs.usesResqlite) {
    return false;
  }
  return true;
}

_RuntimeNeeds _runtimeNeeds(Iterable<String> peers) {
  final peerSet = peers.toSet();
  final includeAll = peerSet.isEmpty;
  return _RuntimeNeeds(
    usesSqliteShim: includeAll ||
        peerSet.any((peer) =>
            peer == 'sqlite3' || peer == 'drift' || peer == 'sqlite_async'),
    usesResqlite: includeAll || peerSet.contains('resqlite'),
  );
}

final class _RuntimeNeeds {
  const _RuntimeNeeds({
    required this.usesSqliteShim,
    required this.usesResqlite,
  });

  final bool usesSqliteShim;
  final bool usesResqlite;
}
