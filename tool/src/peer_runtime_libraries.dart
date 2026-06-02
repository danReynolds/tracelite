import 'dart:convert';
import 'dart:io';

import 'package:tracelite/src/native_artifacts.dart' as native_artifacts;

List<String> workerRuntimeLibraryPaths() {
  final paths = <String>{};

  void addPath(String path) {
    if (path.isEmpty) return;
    final file = File(path);
    if (file.existsSync()) {
      paths.add(file.absolute.path);
    }
  }

  addPath(native_artifacts.defaultRuntimeLibraryPath());
  addPath(native_artifacts.sqliteShimLibraryPath());
  addPath(native_artifacts.sqliteShimLibraryName());

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
            for (final asset in platformAssets.values) {
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
