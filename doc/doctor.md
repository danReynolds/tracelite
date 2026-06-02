# tracelite doctor

`tracelite doctor` is the first command to run in a fresh checkout or CI image.
It checks the local source layout, generated files, Dart dependency resolution,
native build artifacts, compiler availability, and visualizer runtime.

```bash
dart run bin/tracelite.dart doctor
```

Useful options:

```bash
dart run bin/tracelite.dart doctor --root=/path/to/tracelite
dart run bin/tracelite.dart doctor --strict=true
dart run bin/tracelite.dart doctor --json=build/tracelite-doctor.json
dart run bin/tracelite.dart doctor \
  --visualizer-release=build/visualizer-release \
  --require-visualizer-release-platforms=macos,linux,windows \
  --require-signed-macos-release=true
```

Default mode fails only on broken checkout state, such as missing source or
generated files. Missing build outputs are warnings with exact build commands,
because a fresh clone can be healthy before native artifacts have been built.
The native commands are platform-specific: macOS builds `*.dylib`, Linux builds
`*.so`, and Windows reports the SQLite shim as unsupported until that loader
strategy is implemented.

Strict mode treats warnings as failures. Use it for release images and benchmark
hosts where the native runtime, SQLite shim, and dependency graph should already
be prepared before a suite starts.

The JSON artifact uses schema `tracelite.doctor.v1` and records every check with
`ok`, `warn`, or `fail` status plus an action for non-ok checks. Store it next
to benchmark artifacts when diagnosing CI or machine-specific setup failures.

Doctor can also audit visualizer release evidence. Pass
`--visualizer-release=...` as either a specific
`tracelite_visualizer-<abi>.manifest.json` file or a directory tree containing
manifest files. The check validates the manifest schema, platform/ABI metadata,
archive existence, byte size, SHA-256 checksum, clean source state, and
signing/notarization status. `--require-visualizer-release-platforms=...` fails
when required platform manifests are missing. macOS signing and notarization are
warnings by default for local developer packages; add
`--require-signed-macos-release=true` for attachable release evidence.

Doctor only checks whether a Flutter runtime is reachable. To verify the
visualizer itself, run:

```bash
dart run bin/tracelite.dart visualizer-check --build=host
```

That command resolves the visualizer app dependencies, runs `flutter analyze`,
runs `flutter test`, builds the current host release bundle, and verifies that
the bundle was produced.

For distributable visualizer archives, run the `Visualizer Release` GitHub
workflow. It packages macOS, Linux, and Windows host builds with the same
`visualizer-check --package=host --require-clean-source=true` path, uploads the
archive/manifest evidence, runs doctor over the downloaded artifacts, and can
publish the artifacts to a draft GitHub release. The workflow requires
macOS/Linux/Windows manifest coverage in that audit and turns on
`--require-signed-macos-release=true` when the manual `sign_macos` input is
true. The workflow skips only the tagged heavyweight dense-trace widget stress
test; run `flutter test` locally for full visualizer stress coverage. macOS
signing and notarization require the workflow's release secrets.
After downloading the workflow artifacts, run doctor with
`--visualizer-release=<downloaded-directory>` to prove the archives still match
their manifests.
