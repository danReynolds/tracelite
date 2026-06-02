# tracelite visualizer

Desktop-first Flutter app for inspecting tracelite SQLite traces and benchmark
artifacts.

The app is intentionally generic. It does not know about any particular SQLite
library; it opens tracelite trace/artifact schemas and renders trace health,
span timing, SQLite call volume, peer comparison, workload summaries, and
graph-data validation.

## Run

From the repository root:

```bash
dart run bin/tracelite.dart visualize build/visualizer-demo
dart run bin/tracelite.dart visualize --release build/visualizer-demo
```

During app development:

```bash
cd tool/visualizer_app
flutter run -d macos -a ../../build/visualizer-demo
```

## Use

- Overview inventories loaded artifacts and load issues.
- Workspace and Compare insights explain trust, trace-health, noise, peer
  spread, and likely bottleneck signals before you inspect raw rows.
- Trace inspects raw `.tlt-region` spans. Use the minimap brush to jump through
  the run, the zoom slider or `+`/`-` to resize the visible window, double-click
  or scroll over the timeline to zoom at the cursor, drag horizontally to pan,
  hover to preview, and click near a tiny bar or span-index row to pin details.
  The span index can stay global or switch to visible-window mode so search
  results follow the current zoomed timeline window. `F` focuses the active span
  and `Home` fits the full trace. The timeline uses enlarged bars, wider hit
  targets, and nearest-span picking so dense traces do not require perfect
  clicks.
- Compare ranks peers by measured elapsed time, scenario elapsed time, SQLite
  call volume, and trace health.
- Artifacts lists the raw trace, suite, decision, workload, and graph-data
  documents discovered in the workspace.

## Test

From the repository root:

```bash
dart tool/visualizer_check.dart
dart tool/visualizer_check.dart --build=host
dart tool/visualizer_check.dart --package=host
```

These direct source-checkout commands resolve app dependencies, analyze, and run
the widget/unit tests without rebuilding the root peer native assets. The second
command also builds the release bundle for the current desktop host and verifies
that the expected artifact exists. The third command also creates a release
archive and manifest under `build/visualizer-release/`. The equivalent routed
CLI is `dart run bin/tracelite.dart visualizer-check`.

During app development:

```bash
flutter analyze
flutter test
flutter build macos
```

## Release Boundary

`dart tool/visualizer_check.dart --package=host` is the source-checkout release
artifact command. It runs the same health checks, builds the host release app,
packages the platform bundle, and writes
`tracelite_visualizer-<abi>.manifest.json` with the source revision, dirty
state, archive byte size, SHA-256 checksum, and signing/notarization status.
Add `--require-clean-source=true` when producing attachable release evidence.

Default macOS archives are unsigned local developer artifacts. Linux and Windows
signing are recorded as external because their signing systems live outside
tracelite. For a credentialed macOS release, add:

```bash
dart tool/visualizer_check.dart \
  --package=host \
  --require-clean-source=true \
  --macos-sign-identity="Developer ID Application: Example" \
  --macos-notary-profile=tracelite-notary
```

That path signs the app, verifies the signature, submits the archive to Apple
notarytool, staples the ticket, then creates the final distributable archive.
Linux and Windows signing remain release-system responsibilities and are
recorded as external in the manifest.

The `Visualizer Release` GitHub workflow builds the same audited archives on
macOS, Linux, and Windows, uploads each archive plus manifest as workflow
artifacts, and can publish them to a draft GitHub release from a tag or manual
dispatch. Hosted release packaging skips only the tagged heavyweight dense-trace
widget stress test; run `flutter test` locally for full stress coverage. Set
`sign_macos=true` only after configuring
`MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`,
`MACOS_SIGN_IDENTITY`, `MACOS_NOTARY_APPLE_ID`, `MACOS_NOTARY_TEAM_ID`, and
`MACOS_NOTARY_PASSWORD` repository secrets.
