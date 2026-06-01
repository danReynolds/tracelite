import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tracelite/tracelite.dart';
import 'package:tracelite_visualizer/main.dart';

void main() {
  testWidgets('renders the visualizer shell', (tester) async {
    await tester.pumpWidget(
      const TraceliteVisualizerApp(initialPath: '/path/that/does/not/exist'),
    );
    await tester.pumpAndSettle();

    expect(find.text('tracelite visualizer'), findsOneWidget);
    expect(find.byIcon(Icons.folder_open), findsOneWidget);
    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('renders loaded trace and compare views at desktop size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final temp = Directory.systemTemp.createTempSync('tracelite-viz-ui-');
    addTearDown(() => temp.deleteSync(recursive: true));
    _writeDemoWorkspace(temp);

    await tester.pumpWidget(TraceliteVisualizerApp(initialPath: temp.path));
    await tester.pumpAndSettle();

    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('Workspace Insights'), findsOneWidget);
    expect(find.text('Loaded Artifacts'), findsOneWidget);
    expect(find.text('Tools'), findsOneWidget);
    expect(find.text('Raw Trace'), findsOneWidget);
    expect(find.text('Peer Compare'), findsOneWidget);
    expect(find.textContaining('point-select'), findsWidgets);

    await tester.tap(find.text('Trace'));
    await tester.pumpAndSettle();
    expect(find.text('Trace Inspector'), findsOneWidget);
    expect(find.text('Trace Tools'), findsOneWidget);
    expect(find.text('Minimap'), findsOneWidget);
    expect(find.text('Zoom'), findsWidgets);
    expect(find.text('Pan'), findsOneWidget);
    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Keyboard'), findsOneWidget);
    expect(find.text('Timeline'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('click select'), findsOneWidget);
    expect(find.byIcon(Icons.center_focus_strong), findsOneWidget);
    expect(find.text('No span selected'), findsOneWidget);

    await tester.tap(find.text('Compare'));
    await tester.pumpAndSettle();
    expect(find.text('Peer Comparison'), findsOneWidget);
    expect(find.text('Compare Insights'), findsOneWidget);
    expect(find.text('Compare Tools'), findsOneWidget);
    expect(find.text('Measured Mean'), findsOneWidget);
    expect(find.text('Peer Metrics'), findsOneWidget);
    expect(find.text('SQL Query Shapes'), findsOneWidget);
    expect(find.text('SQL Fingerprints'), findsOneWidget);
    expect(find.textContaining('INSERT INTO TRACELITE_ITEMS'), findsOneWidget);
    expect(find.text('sqlite3'), findsWidgets);
  });

  testWidgets('renders dense trace with searchable linked span index', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final temp = Directory.systemTemp.createTempSync('tracelite-viz-dense-');
    addTearDown(() => temp.deleteSync(recursive: true));
    await _writeDenseTraceWorkspace(temp, spanCount: 12000);

    await tester.pumpWidget(TraceliteVisualizerApp(initialPath: temp.path));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Trace'));
    await tester.pumpAndSettle();
    expect(find.text('Trace Inspector'), findsOneWidget);
    expect(find.text('12000'), findsWidgets);

    await tester.drag(find.byType(ListView).last, const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.text('Span Index'), findsOneWidget);
    expect(find.text('12000 matches'), findsOneWidget);

    await tester.drag(find.byType(ListView).last, const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Visible Span Aggregation', skipOffstage: false),
      findsOneWidget,
    );

    await tester.drag(find.byType(ListView).last, const Offset(0, 700));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'sqlite3_step');
    await tester.pumpAndSettle();
    expect(find.text('sqlite3_step'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('span-row-0-name')));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, 900));
    await tester.pumpAndSettle();
    expect(find.text('Selected Span'), findsOneWidget);
  });

  testWidgets('decodes SQLite prepare SQL fingerprints in trace views', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final temp = Directory.systemTemp.createTempSync('tracelite-viz-sql-');
    addTearDown(() => temp.deleteSync(recursive: true));
    await _writeSqlTraceWorkspace(temp);

    await tester.pumpWidget(TraceliteVisualizerApp(initialPath: temp.path));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Trace'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, -700));
    await tester.pumpAndSettle();

    expect(find.text('Span Index'), findsOneWidget);
    expect(find.textContaining('sqlfp:v1:2a1aa0dd'), findsWidgets);
    expect(
      find.textContaining('SELECT * FROM TRACELITE_ITEMS WHERE ID = ?'),
      findsWidgets,
    );

    await tester.enterText(find.byType(TextField).last, 'TRACELITE_ITEMS');
    await tester.pumpAndSettle();
    expect(find.text('1 matches'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('span-row-0-name')));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, 700));
    await tester.pumpAndSettle();

    expect(find.text('Selected Span'), findsOneWidget);
    expect(
      find.textContaining('sql fingerprint', findRichText: true),
      findsWidgets,
    );
    expect(
      find.textContaining('fingerprinted', findRichText: true),
      findsWidgets,
    );
    expect(
      find.textContaining(
        'SELECT * FROM TRACELITE_ITEMS WHERE ID = ?',
        findRichText: true,
      ),
      findsWidgets,
    );
  });
}

void _writeDemoWorkspace(Directory dir) {
  TraceRegion.createFile('${dir.path}/empty.tlt-region');
  File('${dir.path}/compare.json').writeAsStringSync(
    jsonEncode({
      'schema': 'tracelite.compare.v1',
      'generated_at': '2026-05-12T00:00:00Z',
      'scenario': 'point-select',
      'rows': 10,
      'repetitions': 1,
      'peers': [
        {
          'peer': 'sqlite3',
          'status': 'ok',
          'successful_repetitions': 1,
          'failed_repetitions': 0,
          'unsupported_repetitions': 0,
          'summary': {
            'measured_elapsed_ns': _stats(1200000),
            'elapsed_ns': _stats(5000000),
            'sqlite3_step_count': _stats(42),
            'sqlite3_step_total_ns': _stats(900000),
            'events': _stats(100),
            'dropped_events': _stats(0),
            'unmatched_begin_events': _stats(0),
            'unmatched_end_events': _stats(0),
          },
          'samples': [
            {
              'repetition': 1,
              'status': 'ok',
              'measured_elapsed_ns': 1200000,
              'elapsed_ns': 5000000,
              'events': 100,
              'spans': 50,
              'diagnostics': {
                'dropped_events': 0,
                'unmatched_begin_events': 0,
                'unmatched_end_events': 0,
              },
              'span_groups': [
                {
                  'span_name': 'sqlite3_step',
                  'count': 42,
                  'total_ns': 900000,
                  'p50_ns': 1000,
                  'p90_ns': 2000,
                  'p99_ns': 3000,
                },
              ],
              'sql_fingerprint_groups': [
                {
                  'fingerprint': 'sqlfp:v1:2a1aa0dda20c1116',
                  'normalized_sql':
                      'INSERT INTO TRACELITE_ITEMS(ID, NAME) VALUES (?, ?)',
                  'prepare_count': 10,
                  'prepare_total_ns': 700000,
                  'prepare_p50_ns': 40000,
                  'prepare_p90_ns': 80000,
                  'prepare_p99_ns': 90000,
                },
              ],
            },
          ],
          'capabilities': ['sql'],
        },
      ],
    }),
  );
}

Future<void> _writeDenseTraceWorkspace(
  Directory dir, {
  required int spanCount,
}) async {
  final runtime = await _ensureRuntimeLibrary();
  final tracePath = '${dir.path}/dense.tlt-region';
  TraceRegion.createFile(tracePath, ringDataWords: 1 << 20);
  final recorder = TraceRecorder.attach(
    regionPath: tracePath,
    runtimeLibraryPath: runtime.absolute.path,
    processName: 'visualizer_dense_test',
    threadName: 'main',
  );
  expect(recorder.isActive, isTrue);
  for (var i = 0; i < 4; i++) {
    recorder.registerSpan(
      userSpanIdStart + i,
      i.isEven ? 'sqlite3_step' : 'sqlite3_prepare_v3',
      category: 'sqlite',
    );
  }
  for (var i = 0; i < spanCount; i++) {
    final spanId = userSpanIdStart + (i % 4);
    recorder.begin(spanId, args: [i]);
    recorder.end(spanId, args: [i % 17]);
  }
  recorder.detach();
}

Future<void> _writeSqlTraceWorkspace(Directory dir) async {
  final runtime = await _ensureRuntimeLibrary();
  final tracePath = '${dir.path}/sql.tlt-region';
  TraceRegion.createFile(tracePath, ringDataWords: 1 << 14);
  final recorder = TraceRecorder.attach(
    regionPath: tracePath,
    runtimeLibraryPath: runtime.absolute.path,
    processName: 'visualizer_sql_test',
    threadName: 'main',
  );
  expect(recorder.isActive, isTrue);

  final sqlId = recorder.internString(
    'sqlfp:v1:2a1aa0dda20c1116:SELECT * FROM TRACELITE_ITEMS WHERE ID = ?',
  );
  recorder.begin(
    BuiltinSpans.sqlite3PrepareV3,
    args: [0x101, sqlId, 0],
    correlationId: 99,
  );
  recorder.end(
    BuiltinSpans.sqlite3PrepareV3,
    args: [0x202, 0],
    correlationId: 99,
  );
  recorder.detach();
}

Future<File> _ensureRuntimeLibrary() async {
  final root = _repoRoot();
  final extension = switch (Platform.operatingSystem) {
    'macos' => 'dylib',
    'windows' => 'dll',
    _ => 'so',
  };
  final file = File('${root.path}/build/libtracelite_runtime.$extension');
  if (file.existsSync()) return file;

  Directory('${root.path}/build').createSync(recursive: true);
  final args = switch (Platform.operatingSystem) {
    'macos' => [
      '-dynamiclib',
      '-O2',
      '-Inative',
      'native/tracelite_runtime.c',
      '-o',
      file.path,
    ],
    'windows' => [
      '-shared',
      '-O2',
      '-Inative',
      'native/tracelite_runtime.c',
      '-o',
      file.path,
    ],
    _ => [
      '-shared',
      '-fPIC',
      '-O2',
      '-Inative',
      'native/tracelite_runtime.c',
      '-o',
      file.path,
    ],
  };

  final result = await Process.run('cc', args, workingDirectory: root.path);
  if (result.exitCode != 0) {
    fail(
      'failed to build tracelite runtime library:\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
  return file;
}

Directory _repoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/native/tracelite_runtime.c').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not find tracelite repo root from ${Directory.current.path}');
    }
    dir = parent;
  }
}

Map<String, Object?> _stats(num value) => {
  'count': 1,
  'total': value,
  'min': value,
  'max': value,
  'mean': value,
  'median': value,
  'p90': value,
  'p99': value,
  'stddev': 0,
};
