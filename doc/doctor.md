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

Doctor only checks whether a Flutter runtime is reachable. To verify the
visualizer itself, run:

```bash
dart run bin/tracelite.dart visualizer-check --build=host
```

That command resolves the visualizer app dependencies, runs `flutter analyze`,
runs `flutter test`, builds the current host release bundle, and verifies that
the bundle was produced.
