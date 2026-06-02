import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('visualizer release workflow packages every desktop host', () {
    final workflow =
        File('.github/workflows/visualizer-release.yml').readAsStringSync();

    expect(workflow, contains('name: Visualizer Release'));
    expect(workflow, contains('workflow_dispatch:'));
    expect(workflow, contains("tags:"));
    for (final runner in ['ubuntu-24.04', 'macos-14', 'windows-2025']) {
      expect(workflow, contains('os: $runner'));
    }
    expect(workflow, contains('subosito/flutter-action@v2'));
    expect(workflow, contains('dart pub get'));
    expect(workflow, contains('--package=host'));
    expect(workflow, contains('--require-clean-source=true'));
    expect(workflow, contains('--skip-heavy-visualizer-tests=true'));
    expect(workflow, isNot(contains('--skip-native-visualizer-tests=true')));
    expect(workflow, contains('actions/upload-artifact@v7.0.1'));
  });

  test('visualizer release workflow supports credentialed macOS release', () {
    final workflow =
        File('.github/workflows/visualizer-release.yml').readAsStringSync();

    expect(workflow, contains('sign_macos:'));
    for (final secret in [
      'MACOS_CERTIFICATE_P12_BASE64',
      'MACOS_CERTIFICATE_PASSWORD',
      'MACOS_SIGN_IDENTITY',
      'MACOS_NOTARY_APPLE_ID',
      'MACOS_NOTARY_TEAM_ID',
      'MACOS_NOTARY_PASSWORD',
    ]) {
      expect(workflow, contains(secret));
    }
    expect(workflow, contains('xcrun notarytool store-credentials'));
    expect(workflow, contains('--macos-sign-identity='));
    expect(workflow, contains('--macos-notary-profile=tracelite-notary'));
  });

  test('visualizer release workflow can publish release assets', () {
    final workflow =
        File('.github/workflows/visualizer-release.yml').readAsStringSync();

    expect(workflow, contains('publish_release:'));
    expect(workflow, contains('actions/download-artifact@v8.0.1'));
    expect(workflow, contains('gh release create'));
    expect(workflow, contains('gh release upload'));
    expect(workflow, contains('contents: write'));
  });
}
