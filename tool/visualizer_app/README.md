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
  `F` focuses the active span and `Home` fits the full trace. The timeline uses
  enlarged bars, wider hit targets, and nearest-span picking so dense traces do
  not require perfect clicks.
- Compare ranks peers by measured elapsed time, scenario elapsed time, SQLite
  call volume, and trace health.
- Artifacts lists the raw trace, suite, decision, workload, and graph-data
  documents discovered in the workspace.

## Test

```bash
flutter analyze
flutter test
flutter build macos
```

## Release Boundary

`flutter build macos` produces the local release app under
`build/macos/Build/Products/Release/tracelite_visualizer.app`. Distribution
outside local developer machines still needs a project signing identity,
notarization decision, and release artifact packaging.
