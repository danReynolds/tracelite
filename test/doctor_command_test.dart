import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test('doctor reports local checkout status and writes JSON', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-doctor-command-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final jsonPath = '${tempDir.path}/doctor.json';
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'doctor',
        '--json=$jsonPath',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'doctor failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    final stdoutText = result.stdout.toString();
    expect(stdoutText, contains('# tracelite doctor'));
    expect(stdoutText, contains('Status:'));
    expect(stdoutText, contains('native/tracelite_runtime.c'));

    final artifact =
        jsonDecode(File(jsonPath).readAsStringSync()) as Map<String, Object?>;
    expect(artifact['schema'], 'tracelite.doctor.v1');
    expect(artifact['status'], isIn(['ready', 'warning']));
    expect(artifact['root'], Directory.current.absolute.path);
    final checks = artifact['checks']! as List<Object?>;
    expect(
      checks,
      contains(
        containsPair('detail', 'native/tracelite_runtime.c'),
      ),
    );
  });

  test('doctor fails for a non-tracelite root', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-doctor-invalid-root-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'doctor',
        '--root=${tempDir.path}',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 65);
    expect(result.stdout.toString(), contains('Status: `failed`'));
    expect(result.stdout.toString(), contains('missing pubspec.yaml'));
  });

  test('doctor validates visualizer release manifest evidence', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-doctor-release-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    _writeFixtureCheckout(tempDir);
    final releaseDir = Directory('${tempDir.path}/release')..createSync();
    final artifactDir = Directory('${releaseDir.path}/linux-x64')..createSync();
    _writeVisualizerReleaseFixture(
      artifactDir,
      platform: 'linux',
      abi: 'linux-x64',
      signingStatus: 'external',
      notarizationStatus: 'not_applicable',
    );
    final jsonPath = '${tempDir.path}/doctor.json';

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'doctor',
        '--root=${tempDir.path}',
        '--visualizer-release=${releaseDir.path}',
        '--require-visualizer-release-platforms=linux',
        '--json=$jsonPath',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'doctor failed.\nstdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('visualizer release checksum'));
    final artifact =
        jsonDecode(File(jsonPath).readAsStringSync()) as Map<String, Object?>;
    final checks = artifact['checks']! as List<Object?>;
    expect(
      checks,
      contains(
        allOf(
          containsPair('name', 'visualizer release platforms'),
          containsPair('status', 'ok'),
        ),
      ),
    );
  });

  test('doctor fails when visualizer release checksum does not match',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-doctor-release-checksum-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    _writeFixtureCheckout(tempDir);
    final releaseDir = Directory('${tempDir.path}/release')..createSync();
    _writeVisualizerReleaseFixture(
      releaseDir,
      platform: 'linux',
      abi: 'linux-x64',
      signingStatus: 'external',
      notarizationStatus: 'not_applicable',
      archiveSha256: 'not-the-real-digest',
    );

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'doctor',
        '--root=${tempDir.path}',
        '--visualizer-release=${releaseDir.path}',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 65);
    expect(result.stdout.toString(), contains('Status: `failed`'));
    expect(result.stdout.toString(), contains('visualizer release checksum'));
    expect(result.stdout.toString(), contains('not-the-real-digest'));
  });

  test('doctor requires signed macOS release evidence when requested',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-doctor-release-signing-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    _writeFixtureCheckout(tempDir);
    final releaseDir = Directory('${tempDir.path}/release')..createSync();
    _writeVisualizerReleaseFixture(
      releaseDir,
      platform: 'macos',
      abi: 'macos-arm64',
      signingStatus: 'unsigned',
      notarizationStatus: 'not_requested',
    );

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'doctor',
        '--root=${tempDir.path}',
        '--visualizer-release=${releaseDir.path}',
        '--require-signed-macos-release=true',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 65);
    expect(result.stdout.toString(), contains('Status: `failed`'));
    expect(result.stdout.toString(), contains('macOS signing status'));
    expect(result.stdout.toString(), contains('macOS notarization status'));
  });

  test('doctor strict mode fails on warnings', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'tracelite-doctor-strict-warning-test-',
    );
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    _writeFixtureCheckout(tempDir);

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/tracelite.dart',
        'doctor',
        '--root=${tempDir.path}',
        '--strict=true',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 65);
    expect(result.stdout.toString(), contains('Status: `failed`'));
    expect(
      result.stdout.toString(),
      contains('.dart_tool/package_config.json'),
    );
    expect(
      result.stderr.toString(),
      contains('strict mode treats doctor warnings as failures'),
    );
  });
}

void _writeFixtureCheckout(Directory root) {
  for (final directory in const [
    'bin',
    'native',
    'tool',
    'tool/src',
    'tool/visualizer_app',
    'lib/src',
    'doc',
  ]) {
    Directory('${root.path}/$directory').createSync(recursive: true);
  }

  for (final file in const [
    'pubspec.yaml',
    'bin/tracelite.dart',
    'tool/tracelite_dev.dart',
    'tool/src/peer.dart',
    'native/tracelite_runtime.c',
    'native/tracelite_runtime.h',
    'native/shim_sqlite3.c',
    'tool/spans.yaml',
    'lib/src/builtin_spans.g.dart',
    'native/builtin_spans.g.h',
    'doc/format-spec.appendix.md',
    'doc/span-registry.generated.md',
  ]) {
    File('${root.path}/$file').writeAsStringSync('\n');
  }
}

File _writeVisualizerReleaseFixture(
  Directory releaseDir, {
  required String platform,
  required String abi,
  required String signingStatus,
  required String notarizationStatus,
  String? archiveSha256,
  int? archiveBytes,
}) {
  final archive = File('${releaseDir.path}/tracelite_visualizer-$abi.zip');
  final contents = utf8.encode('visualizer archive for $abi');
  archive.writeAsBytesSync(contents);
  final manifest = File(
    '${releaseDir.path}/tracelite_visualizer-$abi.manifest.json',
  );
  manifest.writeAsStringSync(
    '${jsonEncode({
          'schema': 'tracelite.visualizer_release.v1',
          'generated_at': '2026-06-02T00:00:00Z',
          'platform': platform,
          'abi': abi,
          'source': {
            'revision': 'abcdef1234567890',
            'dirty': false,
          },
          'archive_path': archive.path,
          'archive_bytes': archiveBytes ?? contents.length,
          'archive_sha256':
              archiveSha256 ?? sha256.convert(contents).toString(),
          'signing': {
            'status': signingStatus,
          },
          'notarization': {
            'status': notarizationStatus,
          },
        })}\n',
  );
  return manifest;
}
