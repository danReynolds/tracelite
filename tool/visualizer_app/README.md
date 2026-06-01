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
- Trace inspects raw `.tlt-region` spans. Use the minimap brush to jump through
  the run, scroll over the timeline or use `+`/`-` to zoom, use the focus
  button to center a selected or hovered span, drag horizontally to pan, hover a
  span to preview it, and click a span or span-index row to pin its details.
  The span index scrolls internally so visible-window aggregation stays close to
  the timeline while investigating dense traces.
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
