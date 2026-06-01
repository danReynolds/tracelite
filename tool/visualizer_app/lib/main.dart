import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tracelite/tracelite.dart';

import 'src/workspace.dart';

void main(List<String> args) {
  runApp(TraceliteVisualizerApp(initialPath: _initialPath(args)));
}

String _initialPath(List<String> args) {
  if (args.isNotEmpty && args.first.trim().isNotEmpty) return args.first;
  final candidates = [
    '../../build/tracelite-production-suite',
    '../..',
    Directory.current.path,
  ];
  for (final candidate in candidates) {
    if (FileSystemEntity.isFileSync(candidate) ||
        FileSystemEntity.isDirectorySync(candidate)) {
      return candidate;
    }
  }
  return Directory.current.path;
}

class TraceliteVisualizerApp extends StatelessWidget {
  const TraceliteVisualizerApp({super.key, required this.initialPath});

  final String initialPath;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xff14635f);
    return MaterialApp(
      title: 'tracelite visualizer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        scaffoldBackgroundColor: const Color(0xfff7f8f5),
        visualDensity: VisualDensity.compact,
        useMaterial3: true,
      ),
      home: VisualizerHome(initialPath: initialPath),
    );
  }
}

class VisualizerHome extends StatefulWidget {
  const VisualizerHome({super.key, required this.initialPath});

  final String initialPath;

  @override
  State<VisualizerHome> createState() => _VisualizerHomeState();
}

class _VisualizerHomeState extends State<VisualizerHome> {
  late final TextEditingController _pathController;
  late Future<VisualizerWorkspace> _workspace;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _pathController = TextEditingController(text: widget.initialPath);
    _workspace = VisualizerWorkspace.load(widget.initialPath);
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  void _loadPath([String? explicitPath]) {
    final path = (explicitPath ?? _pathController.text).trim();
    if (path.isEmpty) return;
    _pathController.text = path;
    setState(() {
      _workspace = VisualizerWorkspace.load(path);
    });
  }

  Future<void> _openFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'tracelite artifacts',
          extensions: ['tlt-region', 'tlt', 'json'],
        ),
      ],
    );
    if (file == null) return;
    _loadPath(file.path);
  }

  Future<void> _openDirectory() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty) return;
    _loadPath(path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _PathBar(
              controller: _pathController,
              onOpen: _loadPath,
              onOpenFile: _openFile,
              onOpenDirectory: _openDirectory,
            ),
            Expanded(
              child: FutureBuilder<VisualizerWorkspace>(
                future: _workspace,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return _LoadError(error: snapshot.error.toString());
                  }
                  final workspace = snapshot.requireData;
                  return Row(
                    children: [
                      NavigationRail(
                        selectedIndex: _selectedIndex,
                        onDestinationSelected: (index) {
                          setState(() => _selectedIndex = index);
                        },
                        labelType: NavigationRailLabelType.all,
                        destinations: const [
                          NavigationRailDestination(
                            icon: Icon(Icons.dashboard_outlined),
                            selectedIcon: Icon(Icons.dashboard),
                            label: Text('Overview'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.timeline_outlined),
                            selectedIcon: Icon(Icons.timeline),
                            label: Text('Trace'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.compare_arrows_outlined),
                            selectedIcon: Icon(Icons.compare_arrows),
                            label: Text('Compare'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.inventory_2_outlined),
                            selectedIcon: Icon(Icons.inventory_2),
                            label: Text('Artifacts'),
                          ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: IndexedStack(
                          index: _selectedIndex,
                          children: [
                            OverviewPage(workspace: workspace),
                            TracePage(workspace: workspace),
                            ComparePage(workspace: workspace),
                            ArtifactsPage(workspace: workspace),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PathBar extends StatelessWidget {
  const _PathBar({
    required this.controller,
    required this.onOpen,
    required this.onOpenFile,
    required this.onOpenDirectory,
  });

  final TextEditingController controller;
  final VoidCallback onOpen;
  final Future<void> Function() onOpenFile;
  final Future<void> Function() onOpenDirectory;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Row(
        children: [
          Icon(Icons.storage, color: colors.primary),
          const SizedBox(width: 10),
          const Text(
            'tracelite visualizer',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: TextField(
              controller: controller,
              onSubmitted: (_) => onOpen(),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.folder_open),
                border: OutlineInputBorder(),
                labelText: 'Trace, artifact, graph-data directory, or suite',
              ),
            ),
          ),
          const SizedBox(width: 10),
          Tooltip(
            message: 'Choose a trace or artifact file',
            child: IconButton.filledTonal(
              onPressed: () {
                onOpenFile();
              },
              icon: const Icon(Icons.note_add_outlined),
            ),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: 'Choose a workspace directory',
            child: IconButton.filledTonal(
              onPressed: () {
                onOpenDirectory();
              },
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Open'),
          ),
        ],
      ),
    );
  }
}

class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key, required this.workspace});

  final VisualizerWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    final insights = _workspaceInsights(workspace);
    return _PageScaffold(
      title: 'Workspace',
      subtitle: workspace.rootPath,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _MetricTile(
                icon: Icons.timeline,
                label: 'traces',
                value: '${workspace.traces.length}',
                detail: _traceDetail(workspace),
              ),
              _MetricTile(
                icon: Icons.compare_arrows,
                label: 'compare artifacts',
                value: '${workspace.compares.length}',
                detail: _compareDetail(workspace),
              ),
              _MetricTile(
                icon: Icons.fact_check,
                label: 'decisions',
                value: '${workspace.decisions.length}',
                detail: workspace.decisions.isEmpty
                    ? 'none'
                    : workspace.decisions.first.verdict,
              ),
              _MetricTile(
                icon: Icons.health_and_safety,
                label: 'load issues',
                value: '${workspace.issues.length}',
                detail: workspace.issues.isEmpty ? 'clean' : 'needs review',
              ),
            ],
          ),
          if (insights.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Section(
              title: 'Workspace Insights',
              child: _InsightList(insights: insights.take(6).toList()),
            ),
          ],
          const SizedBox(height: 20),
          _Section(
            title: 'Loaded Artifacts',
            child: _ArtifactSummary(workspace: workspace),
          ),
          const SizedBox(height: 16),
          const _Section(
            title: 'Tools',
            child: _ToolGuide(
              entries: [
                _ToolGuideEntry(
                  icon: Icons.dashboard,
                  title: 'Overview',
                  body:
                      'Inventory the workspace and check whether anything failed to load.',
                ),
                _ToolGuideEntry(
                  icon: Icons.timeline,
                  title: 'Raw Trace',
                  body:
                      'Inspect raw spans with minimap navigation, zoom, hover preview, and pinned selection.',
                ),
                _ToolGuideEntry(
                  icon: Icons.compare_arrows,
                  title: 'Peer Compare',
                  body:
                      'Compare peers by measured elapsed time, scenario time, SQLite work, and trace health.',
                ),
                _ToolGuideEntry(
                  icon: Icons.inventory_2,
                  title: 'Artifacts',
                  body:
                      'Browse every loaded trace, suite, decision, workload, and graph-data bundle.',
                ),
              ],
            ),
          ),
          if (workspace.issues.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Section(
              title: 'Load Issues',
              child: _IssueList(issues: workspace.issues),
            ),
          ],
        ],
      ),
    );
  }

  String _traceDetail(VisualizerWorkspace workspace) {
    if (workspace.traces.isEmpty) return 'none';
    final events = workspace.traces.fold<int>(
      0,
      (sum, trace) => sum + trace.trace.events.length,
    );
    return '$events events';
  }

  String _compareDetail(VisualizerWorkspace workspace) {
    if (workspace.compares.isEmpty) return 'none';
    final peers = <String>{};
    for (final compare in workspace.compares) {
      for (final peer in compare.peers) {
        peers.add(peer.name);
      }
    }
    return '${peers.length} peers';
  }

  List<BenchmarkInsight> _workspaceInsights(VisualizerWorkspace workspace) {
    final insights = <BenchmarkInsight>[];
    for (final decision in workspace.decisions) {
      insights.addAll(benchmarkArtifactInsights(decision.artifact));
    }
    for (final compare in workspace.compares) {
      insights.addAll(benchmarkArtifactInsights(compare.artifact));
    }
    insights.sort((a, b) {
      final bySeverity = _insightSeverityRank(
        a.severity,
      ).compareTo(_insightSeverityRank(b.severity));
      if (bySeverity != 0) return bySeverity;
      return a.title.compareTo(b.title);
    });
    return insights;
  }
}

class TracePage extends StatefulWidget {
  const TracePage({super.key, required this.workspace});

  final VisualizerWorkspace workspace;

  @override
  State<TracePage> createState() => _TracePageState();
}

class _TracePageState extends State<TracePage> {
  final TextEditingController _spanFilterController = TextEditingController();
  int _selectedIndex = 0;
  TraceSpan? _selectedSpan;
  _VisibleRange? _visibleRange;
  String _spanFilter = '';

  @override
  void dispose() {
    _spanFilterController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TracePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selectedIndex >= widget.workspace.traces.length) {
      _selectedIndex = math.max(0, widget.workspace.traces.length - 1);
    }
    if (oldWidget.workspace != widget.workspace) {
      _selectedSpan = null;
      _visibleRange = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final traces = widget.workspace.traces;
    final trace = traces.isEmpty ? null : traces[_selectedIndex];
    final matchingSpans = trace == null ? <TraceSpan>[] : _matchingSpans(trace);
    final visibleRange = trace == null ? null : _visibleRangeFor(trace);
    final visibleSpans = trace == null || visibleRange == null
        ? <TraceSpan>[]
        : _visibleSpans(trace, visibleRange);
    final visibleGroups = trace == null
        ? <SpanGroupStats>[]
        : _spanGroupsFor(trace, visibleSpans);
    return _PageScaffold(
      title: 'Trace Inspector',
      subtitle: trace?.path ?? 'Open a .tlt-region trace to inspect spans',
      child: trace == null
          ? const _EmptyState(
              icon: Icons.timeline,
              title: 'No raw trace loaded',
              body: 'Open a .tlt-region file or a directory containing traces.',
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (traces.length > 1) ...[
                  _ArtifactPicker(
                    label: 'Trace file',
                    value: _selectedIndex,
                    itemCount: traces.length,
                    itemLabel: (index) => traces[index].name,
                    onChanged: (index) {
                      if (index == null) return;
                      setState(() {
                        _selectedIndex = index;
                        _selectedSpan = null;
                        _visibleRange = null;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                ],
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _MetricTile(
                      icon: Icons.event,
                      label: 'events',
                      value: '${trace.trace.events.length}',
                      detail: '${trace.trace.tracks.length} producers',
                    ),
                    _MetricTile(
                      icon: Icons.view_timeline,
                      label: 'spans',
                      value: '${trace.trace.spans.length}',
                      detail: formatNs(trace.durationNs),
                    ),
                    _MetricTile(
                      icon: Icons.storage,
                      label: 'sqlite3_step',
                      value: '${trace.sqliteStepCount}',
                      detail: formatNs(trace.sqliteStepTotalNs),
                    ),
                    _MetricTile(
                      icon: trace.hasHealthIssues
                          ? Icons.warning_amber
                          : Icons.check_circle,
                      label: 'trace health',
                      value: trace.hasHealthIssues ? 'review' : 'clean',
                      detail:
                          '${trace.trace.diagnostics.droppedEvents}/'
                          '${trace.trace.diagnostics.unmatchedBeginEvents}/'
                          '${trace.trace.diagnostics.unmatchedEndEvents}',
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const _Section(
                  title: 'Trace Tools',
                  child: _ToolGuide(
                    entries: [
                      _ToolGuideEntry(
                        icon: Icons.map_outlined,
                        title: 'Minimap',
                        body:
                            'Click or drag the overview brush to jump through long traces.',
                      ),
                      _ToolGuideEntry(
                        icon: Icons.zoom_in,
                        title: 'Zoom',
                        body:
                            'Use the slider, +/- buttons, double-click, or scroll over the timeline to inspect dense spans.',
                      ),
                      _ToolGuideEntry(
                        icon: Icons.pan_tool_alt,
                        title: 'Pan',
                        body:
                            'Drag horizontally inside the timeline to move through the visible time window.',
                      ),
                      _ToolGuideEntry(
                        icon: Icons.touch_app,
                        title: 'Preview',
                        body:
                            'Hover to preview. Click near a tiny bar or a span row to pin it in the inspector.',
                      ),
                      _ToolGuideEntry(
                        icon: Icons.keyboard,
                        title: 'Keyboard',
                        body:
                            '+/- zoom, left/right pan, F focuses the active span, Home fits the trace.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Timeline',
                  child: SizedBox(
                    height: 430,
                    child: TraceTimeline(
                      trace: trace,
                      selected: _selectedSpan,
                      onSelected: (span) {
                        setState(() => _selectedSpan = span);
                      },
                      onViewportChanged: _handleViewportChanged,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Span Index',
                  child: SpanIndexPanel(
                    trace: trace,
                    spans: matchingSpans,
                    selected: _selectedSpan,
                    filterController: _spanFilterController,
                    onFilterChanged: (value) {
                      setState(() => _spanFilter = value.trim());
                    },
                    onSelected: (span) {
                      setState(() => _selectedSpan = span);
                    },
                  ),
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Visible Span Aggregation (${visibleSpans.length})',
                  child: SpanAggregationTable(groups: visibleGroups),
                ),
              ],
            ),
    );
  }

  List<TraceSpan> _matchingSpans(TraceDocument trace) {
    final filter = _spanFilter.toLowerCase();
    final spans =
        trace.completeSpans.where((span) {
          if (filter.isEmpty) return true;
          final name = trace.trace.spanName(span.spanId).toLowerCase();
          final args = _spanArgsSummary(trace, span).toLowerCase();
          return name.contains(filter) ||
              args.contains(filter) ||
              '${span.trackId}'.contains(filter) ||
              '${span.begin.correlationId ?? ''}'.contains(filter);
        }).toList()..sort((a, b) {
          final byStart = a.startNs.compareTo(b.startNs);
          if (byStart != 0) return byStart;
          return b.durationNs.compareTo(a.durationNs);
        });
    return spans;
  }

  _VisibleRange _visibleRangeFor(TraceDocument trace) {
    final full = _fullTraceRange(trace);
    final current = _visibleRange;
    if (current == null) return full;
    final start = current.startNs.clamp(full.startNs, full.endNs - 1).toInt();
    final end = current.endNs.clamp(start + 1, full.endNs).toInt();
    return _VisibleRange(start, end);
  }

  void _handleViewportChanged(int startNs, int endNs) {
    if (!mounted) return;
    final current = _visibleRange;
    if (current != null &&
        current.startNs == startNs &&
        current.endNs == endNs) {
      return;
    }
    setState(() {
      _visibleRange = _VisibleRange(startNs, endNs);
    });
  }

  List<TraceSpan> _visibleSpans(
    TraceDocument trace,
    _VisibleRange visibleRange,
  ) {
    return trace.visibleSpansIn(visibleRange.startNs, visibleRange.endNs);
  }

  List<SpanGroupStats> _spanGroupsFor(
    TraceDocument trace,
    Iterable<TraceSpan> spans,
  ) {
    return spans
        .groupStatsByType(spanNames: trace.trace.spanNames)
        .where((group) => group.stats.count > 0)
        .toList()
      ..sort((a, b) {
        final byTotal = b.stats.totalNs.compareTo(a.stats.totalNs);
        if (byTotal != 0) return byTotal;
        return a.spanName.compareTo(b.spanName);
      });
  }
}

final class _VisibleRange {
  const _VisibleRange(this.startNs, this.endNs);

  final int startNs;
  final int endNs;
}

class ComparePage extends StatefulWidget {
  const ComparePage({super.key, required this.workspace});

  final VisualizerWorkspace workspace;

  @override
  State<ComparePage> createState() => _ComparePageState();
}

class _ComparePageState extends State<ComparePage> {
  int _selectedIndex = 0;

  @override
  void didUpdateWidget(covariant ComparePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selectedIndex >= widget.workspace.compares.length) {
      _selectedIndex = math.max(0, widget.workspace.compares.length - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final compares = widget.workspace.compares;
    final compare = compares.isEmpty ? null : compares[_selectedIndex];
    final insights = compare == null
        ? const <BenchmarkInsight>[]
        : benchmarkArtifactInsights(compare.artifact);
    return _PageScaffold(
      title: 'Peer Comparison',
      subtitle: compare == null
          ? 'Open a tracelite.compare.v1 artifact or suite manifest'
          : '${compare.scenario} - ${compare.peers.length} peers',
      child: compare == null
          ? const _EmptyState(
              icon: Icons.compare_arrows,
              title: 'No compare artifact loaded',
              body: 'Open a compare JSON or a suite manifest.',
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (compares.length > 1) ...[
                  _ArtifactPicker(
                    label: 'Compare artifact',
                    value: _selectedIndex,
                    itemCount: compares.length,
                    itemLabel: (index) =>
                        '${compares[index].scenario} (${compares[index].name})',
                    onChanged: (index) {
                      if (index == null) return;
                      setState(() => _selectedIndex = index);
                    },
                  ),
                  const SizedBox(height: 16),
                ],
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _MetricTile(
                      icon: Icons.route,
                      label: 'scenario',
                      value: compare.scenario,
                      detail: '${compare.rows} rows',
                    ),
                    _MetricTile(
                      icon: Icons.repeat,
                      label: 'repetitions',
                      value: '${compare.repetitions}',
                      detail: compare.generatedAt ?? 'generated locally',
                    ),
                    _MetricTile(
                      icon: Icons.groups,
                      label: 'peers',
                      value: '${compare.peers.length}',
                      detail: _statusDetail(compare),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _Section(
                  title: 'Compare Insights',
                  child: _InsightList(insights: insights.take(6).toList()),
                ),
                const SizedBox(height: 16),
                const _Section(
                  title: 'Compare Tools',
                  child: _ToolGuide(
                    entries: [
                      _ToolGuideEntry(
                        icon: Icons.timer,
                        title: 'Measured Mean',
                        body:
                            'The timed workload body. This is usually the first number to compare.',
                      ),
                      _ToolGuideEntry(
                        icon: Icons.route,
                        title: 'Scenario Mean',
                        body:
                            'End-to-end child-process scenario time, useful for harness overhead checks.',
                      ),
                      _ToolGuideEntry(
                        icon: Icons.health_and_safety,
                        title: 'Trace Health',
                        body:
                            'Dropped, unmatched-begin, and unmatched-end event counts. Non-zero means inspect before trusting timings.',
                      ),
                      _ToolGuideEntry(
                        icon: Icons.fingerprint,
                        title: 'SQL Fingerprints',
                        body:
                            'Normalized prepare groups show query-shape cost without exposing literal values.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Peer Metrics',
                  child: PeerComparisonTable(compare: compare),
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'SQL Query Shapes',
                  child: PeerSqlFingerprintBreakdown(compare: compare),
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Top SQLite Work By Peer',
                  child: PeerSpanBreakdown(compare: compare),
                ),
              ],
            ),
    );
  }

  String _statusDetail(CompareDocument compare) {
    final statuses = <String, int>{};
    for (final peer in compare.peers) {
      statuses[peer.status] = (statuses[peer.status] ?? 0) + 1;
    }
    return statuses.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join(', ');
  }
}

class ArtifactsPage extends StatelessWidget {
  const ArtifactsPage({super.key, required this.workspace});

  final VisualizerWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      title: 'Artifacts',
      subtitle: '${workspace.artifactCount} loaded from ${workspace.rootPath}',
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _Section(
            title: 'Traces',
            child: _SimpleArtifactTable(
              rows: [
                for (final trace in workspace.traces)
                  [
                    trace.name,
                    '${trace.trace.events.length} events',
                    trace.hasHealthIssues ? 'health issues' : 'clean',
                  ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Graph Data',
            child: GraphDataTable(graphData: workspace.graphData),
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Workloads',
            child: WorkloadTable(workloads: workspace.workloads),
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Suites And Decisions',
            child: _SimpleArtifactTable(
              rows: [
                for (final suite in workspace.suites)
                  [suite.name, suite.profile, '${suite.runs.length} runs'],
                for (final decision in workspace.decisions)
                  [decision.name, decision.verdict, decision.expectation],
              ],
            ),
          ),
          if (workspace.unknownArtifacts.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Section(
              title: 'Other JSON',
              child: _SimpleArtifactTable(
                rows: [
                  for (final artifact in workspace.unknownArtifacts)
                    [artifact.name, artifact.schema, artifact.path],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

const double _timelineTop = 34;
const double _timelineLaneHeight = 34;
const double _timelineRightPadding = 18;
const double _timelineBarTopInset = 7;
const double _timelineBarHeight = 20;
const double _timelineMinBarWidth = 5;
const double _timelineHitSlopPixels = 9;
const double _timelineNearestPickPixels = 16;
const int _maxDetailedTimelineSpans = 10000;
const double _minDetailedTimelineSpanPixels = 2.5;

double _timelineLeftGutter(double width) {
  return math.min(190, math.max(118, width * 0.30));
}

double _timelineWidthFor(double width) {
  return math.max(
    1,
    width - _timelineLeftGutter(width) - _timelineRightPadding,
  );
}

int _traceStartNs(TraceDocument trace) {
  final events = trace.trace.events;
  return events.isEmpty ? 0 : events.first.timestampNs;
}

_VisibleRange _fullTraceRange(TraceDocument trace) {
  final start = _traceStartNs(trace);
  return _VisibleRange(start, start + math.max(1, trace.durationNs));
}

class TraceTimeline extends StatefulWidget {
  const TraceTimeline({
    super.key,
    required this.trace,
    required this.selected,
    required this.onSelected,
    required this.onViewportChanged,
  });

  final TraceDocument trace;
  final TraceSpan? selected;
  final ValueChanged<TraceSpan?> onSelected;
  final void Function(int startNs, int endNs) onViewportChanged;

  @override
  State<TraceTimeline> createState() => _TraceTimelineState();
}

class _TraceTimelineState extends State<TraceTimeline> {
  static const double _minimumFocusedSpanPixels = 28;

  TraceSpan? _hoveredSpan;
  late int _viewStartNs;
  late int _viewEndNs;
  double _lastTimelineWidth = 1000;

  @override
  void initState() {
    super.initState();
    _fitToTrace(notify: false);
  }

  @override
  void didUpdateWidget(covariant TraceTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trace != widget.trace) {
      _hoveredSpan = null;
      _fitToTrace(notify: false);
    } else if (!identical(oldWidget.selected, widget.selected) &&
        widget.selected != null) {
      final selected = widget.selected!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(widget.selected, selected)) return;
        _focusSpan(selected);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final trace = widget.trace.trace;
    final activeSpan = widget.selected ?? _hoveredSpan;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TimelineToolbar(
          visibleLabel: _visibleWindowLabel,
          densityLabel: '${_visibleSpanCount()} visible spans',
          selectedLabel: activeSpan == null
              ? '${trace.spans.length} spans'
              : trace.spanName(activeSpan.spanId),
          zoomLevel: _zoomLevel,
          onZoomLevelChanged: _setZoomLevel,
          onFit: () => _fitToTrace(),
          canFocusSelection: activeSpan != null,
          onFocusSelection: _focusActiveSpan,
          onZoomIn: () => _zoomAtFraction(0.5, 0.55),
          onZoomOut: () => _zoomAtFraction(0.5, 1.8),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 56,
          child: _TimelineMinimap(
            trace: widget.trace,
            colorScheme: Theme.of(context).colorScheme,
            viewStartNs: _viewStartNs,
            viewEndNs: _viewEndNs,
            selected: activeSpan,
            onViewportChanged: _setViewport,
          ),
        ),
        const SizedBox(height: 8),
        const _TimelineGestureLegend(),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _lastTimelineWidth = constraints.maxWidth;
              final size = Size(constraints.maxWidth, constraints.maxHeight);
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Focus(
                  autofocus: true,
                  onKeyEvent: _handleKeyEvent,
                  child: Listener(
                    onPointerSignal: (event) =>
                        _handlePointerSignal(event, size),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.precise,
                      onHover: (event) {
                        final span = _spanAt(event.localPosition, size);
                        if (!identical(span, _hoveredSpan)) {
                          setState(() => _hoveredSpan = span);
                        }
                      },
                      onExit: (_) {
                        if (_hoveredSpan != null) {
                          setState(() => _hoveredSpan = null);
                        }
                      },
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (details) {
                          _panByPixels(details.delta.dx, size.width);
                        },
                        onDoubleTapDown: (details) {
                          _zoomAt(details.localPosition, size.width, 0.45);
                        },
                        onTapUp: (details) {
                          final span = _spanAt(details.localPosition, size);
                          widget.onSelected(span);
                        },
                        child: CustomPaint(
                          painter: _TimelinePainter(
                            trace: widget.trace,
                            selected: widget.selected,
                            hovered: _hoveredSpan,
                            colorScheme: Theme.of(context).colorScheme,
                            viewStartNs: _viewStartNs,
                            viewEndNs: _viewEndNs,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        _SelectedSpanDetails(
          trace: widget.trace,
          span: widget.selected,
          hoveredSpan: _hoveredSpan,
        ),
      ],
    );
  }

  String get _visibleWindowLabel {
    final fullDuration = math.max(1, _traceEndNs - _traceStartNs);
    final visibleDuration = math.max(1, _viewEndNs - _viewStartNs);
    final percent = (visibleDuration / fullDuration) * 100;
    return '${formatNs(visibleDuration)} visible (${_formatPercent(percent)}%)';
  }

  double get _zoomLevel {
    final fullDuration = math.max(1, _traceEndNs - _traceStartNs);
    final visibleDuration = math.max(1, _viewEndNs - _viewStartNs);
    final minWindow = _minimumWindowNs(fullDuration);
    if (fullDuration <= minWindow) return 1;
    final fullLog = math.log(fullDuration);
    final minLog = math.log(minWindow);
    final visibleLog = math.log(visibleDuration.clamp(minWindow, fullDuration));
    return ((fullLog - visibleLog) / (fullLog - minLog)).clamp(0.0, 1.0);
  }

  int get _traceStartNs {
    final events = widget.trace.trace.events;
    return events.isEmpty ? 0 : events.first.timestampNs;
  }

  int get _traceEndNs => _traceStartNs + math.max(1, widget.trace.durationNs);

  void _fitToTrace({bool notify = true}) {
    void update() {
      _viewStartNs = _traceStartNs;
      _viewEndNs = _traceEndNs;
    }

    if (notify) {
      setState(update);
      widget.onViewportChanged(_traceStartNs, _traceEndNs);
    } else {
      update();
    }
  }

  void _handlePointerSignal(PointerSignalEvent event, Size size) {
    if (event is! PointerScrollEvent) return;
    if (event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs()) {
      _panByPixels(-event.scrollDelta.dx, size.width);
      return;
    }
    final factor = event.scrollDelta.dy > 0 ? 1.20 : 0.82;
    _zoomAt(event.localPosition, size.width, factor);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      _panByPixels(80, _lastTimelineWidth);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _panByPixels(-80, _lastTimelineWidth);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      _zoomAtFraction(0.5, 0.82);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      _zoomAtFraction(0.5, 1.20);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _focusActiveSpan();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _fitToTrace();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _setZoomLevel(double value) {
    final fullStart = _traceStartNs;
    final fullEnd = _traceEndNs;
    final fullDuration = math.max(1, fullEnd - fullStart);
    final minWindow = _minimumWindowNs(fullDuration);
    if (fullDuration <= minWindow) return;
    final fullLog = math.log(fullDuration);
    final minLog = math.log(minWindow);
    final targetLog = fullLog - (fullLog - minLog) * value.clamp(0.0, 1.0);
    final targetDuration = math
        .exp(targetLog)
        .round()
        .clamp(minWindow, fullDuration)
        .toInt();
    final center = _viewStartNs + ((_viewEndNs - _viewStartNs) / 2).round();
    _setViewport(
      center - (targetDuration / 2).round(),
      center + (targetDuration / 2).round(),
    );
  }

  void _zoomAtFraction(double fraction, double factor) {
    final width = _lastTimelineWidth;
    final leftGutter = _timelineLeftGutter(width);
    final timelineWidth = _timelineWidthFor(width);
    _zoomAt(
      Offset(leftGutter + timelineWidth * fraction, _timelineTop),
      width,
      factor,
    );
  }

  void _zoomAt(Offset position, double width, double factor) {
    final fullStart = _traceStartNs;
    final fullEnd = _traceEndNs;
    final fullDuration = math.max(1, fullEnd - fullStart);
    final currentDuration = math.max(1, _viewEndNs - _viewStartNs);
    final minWindow = _minimumWindowNs(fullDuration);
    final requested = (currentDuration * factor).round();
    final newDuration = requested.clamp(minWindow, fullDuration).toInt();
    final leftGutter = _timelineLeftGutter(width);
    final timelineWidth = _timelineWidthFor(width);
    final fraction = position.dx < leftGutter
        ? 0.5
        : ((position.dx - leftGutter) / timelineWidth).clamp(0.0, 1.0);
    final anchorNs = _viewStartNs + (currentDuration * fraction).round();
    final newStart = anchorNs - (newDuration * fraction).round();
    _setViewport(newStart, newStart + newDuration);
  }

  void _panByPixels(double deltaDx, double width) {
    final timelineWidth = _timelineWidthFor(width);
    final visibleDuration = math.max(1, _viewEndNs - _viewStartNs);
    final shiftNs = (-(deltaDx / timelineWidth) * visibleDuration).round();
    if (shiftNs == 0) return;
    _setViewport(_viewStartNs + shiftNs, _viewEndNs + shiftNs);
  }

  void _setViewport(int startNs, int endNs) {
    final fullStart = _traceStartNs;
    final fullEnd = _traceEndNs;
    final fullDuration = math.max(1, fullEnd - fullStart);
    final requestedDuration = math.max(1, endNs - startNs);
    final duration = math.min(requestedDuration, fullDuration);
    final maxStart = fullEnd - duration;
    final start = startNs.clamp(fullStart, maxStart).toInt();
    final end = start + duration;
    if (_viewStartNs == start && _viewEndNs == end) return;
    setState(() {
      _viewStartNs = start;
      _viewEndNs = end;
    });
    widget.onViewportChanged(start, end);
  }

  void _focusActiveSpan() {
    final span = widget.selected ?? _hoveredSpan;
    if (span == null) return;
    _focusSpan(span, force: true);
  }

  void _focusSpan(TraceSpan span, {bool force = false}) {
    final endNs = span.endNs ?? span.startNs;
    final fullStart = _traceStartNs;
    final fullEnd = _traceEndNs;
    final fullDuration = math.max(1, fullEnd - fullStart);
    final spanDuration = math.max(1, endNs - span.startNs);
    final timelineWidth = _timelineWidthFor(_lastTimelineWidth);
    final currentDuration = math.max(1, _viewEndNs - _viewStartNs);
    final currentVisualWidth = (spanDuration / currentDuration) * timelineWidth;
    final fullyVisible = span.startNs >= _viewStartNs && endNs <= _viewEndNs;
    if (!force &&
        fullyVisible &&
        currentVisualWidth >= _minimumFocusedSpanPixels) {
      return;
    }
    final targetWindow = math.max(
      spanDuration,
      ((spanDuration * timelineWidth) / _minimumFocusedSpanPixels).round(),
    );
    final contextWindow = spanDuration * 24;
    final minWindow = math.max(1000, spanDuration);
    final window = math.min(
      fullDuration,
      math.max(minWindow, math.min(contextWindow, targetWindow)),
    );
    final center = span.startNs + (spanDuration / 2).round();
    _setViewport(center - (window / 2).round(), center + (window / 2).round());
  }

  TraceSpan? _spanAt(Offset position, Size size) {
    final width = size.width;
    final leftGutter = _timelineLeftGutter(width);
    final duration = _viewEndNs - _viewStartNs;
    if (duration <= 0 ||
        position.dx < leftGutter ||
        position.dy < _timelineTop) {
      return null;
    }
    final laneIndex = ((position.dy - _timelineTop) / _timelineLaneHeight)
        .floor();
    final tracks = widget.trace.trace.tracks;
    if (laneIndex < 0 || laneIndex >= tracks.length) return null;
    final trackId = tracks[laneIndex].id;
    final timelineWidth = _timelineWidthFor(width);
    final tappedNs =
        _viewStartNs +
        (((position.dx - leftGutter) / timelineWidth) * duration).round();
    final laneTop =
        _timelineTop + laneIndex * _timelineLaneHeight + _timelineBarTopInset;
    final laneBottom = laneTop + _timelineBarHeight;
    final visibleRight = leftGutter + timelineWidth;
    final candidates = <TraceSpan>[];
    TraceSpan? nearest;
    var nearestDistance = double.infinity;
    for (final span
        in widget.trace.completeSpansByTrack[trackId] ?? const <TraceSpan>[]) {
      final end = span.endNs ?? span.startNs;
      if (span.startNs > _viewEndNs) break;
      if (end < _viewStartNs || span.startNs > _viewEndNs) continue;
      final x =
          leftGutter +
          ((span.startNs - _viewStartNs) / duration).clamp(0.0, 1.0) *
              timelineWidth;
      final right =
          leftGutter +
          ((end - _viewStartNs) / duration).clamp(0.0, 1.0) * timelineWidth;
      final visualWidth = math.max(_timelineMinBarWidth, right - x);
      final visualLeft = x.clamp(leftGutter, visibleRight).toDouble();
      final visualRect = Rect.fromLTWH(
        visualLeft,
        laneTop,
        visualWidth,
        laneBottom - laneTop,
      ).inflate(_timelineHitSlopPixels);
      if (visualRect.contains(position) ||
          (tappedNs >= span.startNs && tappedNs <= end)) {
        candidates.add(span);
        continue;
      }
      final spanCenterX = visualLeft + visualWidth / 2;
      final spanCenterY = laneTop + (laneBottom - laneTop) / 2;
      final distance = math.sqrt(
        math.pow(position.dx - spanCenterX, 2) +
            math.pow(position.dy - spanCenterY, 2),
      );
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = span;
      }
    }
    candidates.sort((a, b) => a.durationNs.compareTo(b.durationNs));
    if (candidates.isNotEmpty) return candidates.first;
    return nearestDistance <= _timelineNearestPickPixels ? nearest : null;
  }

  int _visibleSpanCount() {
    return widget.trace.visibleSpanCountIn(_viewStartNs, _viewEndNs);
  }

  int _minimumWindowNs(int fullDurationNs) {
    return math.min(fullDurationNs, math.max(1000, fullDurationNs ~/ 100000));
  }
}

class _TimelineToolbar extends StatelessWidget {
  const _TimelineToolbar({
    required this.visibleLabel,
    required this.densityLabel,
    required this.selectedLabel,
    required this.zoomLevel,
    required this.onZoomLevelChanged,
    required this.onFit,
    required this.canFocusSelection,
    required this.onFocusSelection,
    required this.onZoomIn,
    required this.onZoomOut,
  });

  final String visibleLabel;
  final String densityLabel;
  final String selectedLabel;
  final double zoomLevel;
  final ValueChanged<double> onZoomLevelChanged;
  final VoidCallback onFit;
  final bool canFocusSelection;
  final VoidCallback onFocusSelection;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final controls = [
      Tooltip(
        message: 'Drag to change the visible time window',
        child: SizedBox(
          width: 210,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.zoom_in_map, color: colors.primary, size: 18),
              const SizedBox(width: 6),
              const Text(
                'Zoom',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
              ),
              Expanded(
                child: Slider(value: zoomLevel, onChanged: onZoomLevelChanged),
              ),
            ],
          ),
        ),
      ),
      Tooltip(
        message: 'Focus selected span',
        child: IconButton.filledTonal(
          onPressed: canFocusSelection ? onFocusSelection : null,
          icon: const Icon(Icons.center_focus_strong),
        ),
      ),
      Tooltip(
        message: 'Zoom out',
        child: IconButton.filledTonal(
          onPressed: onZoomOut,
          icon: const Icon(Icons.remove),
        ),
      ),
      Tooltip(
        message: 'Zoom in',
        child: IconButton.filledTonal(
          onPressed: onZoomIn,
          icon: const Icon(Icons.add),
        ),
      ),
      Tooltip(
        message: 'Fit full trace',
        child: IconButton.filledTonal(
          onPressed: onFit,
          icon: const Icon(Icons.fit_screen),
        ),
      ),
    ];

    final label = Row(
      children: [
        Icon(Icons.travel_explore, color: colors.primary, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$visibleLabel - $densityLabel - $selectedLabel',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              label,
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: controls,
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: label),
            const SizedBox(width: 8),
            Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: controls,
            ),
          ],
        );
      },
    );
  }
}

class _TimelineGestureLegend extends StatelessWidget {
  const _TimelineGestureLegend();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: const [
        _GestureChip(icon: Icons.mouse, label: 'scroll zoom'),
        _GestureChip(icon: Icons.open_with, label: 'drag pan'),
        _GestureChip(icon: Icons.touch_app, label: 'click select'),
        _GestureChip(icon: Icons.keyboard, label: '+/- arrows F Home'),
      ],
    );
  }
}

class _GestureChip extends StatelessWidget {
  const _GestureChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: colors.primary, size: 14),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineMinimap extends StatelessWidget {
  const _TimelineMinimap({
    required this.trace,
    required this.colorScheme,
    required this.viewStartNs,
    required this.viewEndNs,
    required this.selected,
    required this.onViewportChanged,
  });

  final TraceDocument trace;
  final ColorScheme colorScheme;
  final int viewStartNs;
  final int viewEndNs;
  final TraceSpan? selected;
  final void Function(int startNs, int endNs) onViewportChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(6),
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) {
              _centerViewportAt(details.localPosition, size.width);
            },
            onHorizontalDragUpdate: (details) {
              _centerViewportAt(details.localPosition, size.width);
            },
            child: CustomPaint(
              painter: _MinimapPainter(
                trace: trace,
                colorScheme: colorScheme,
                viewStartNs: viewStartNs,
                viewEndNs: viewEndNs,
                selected: selected,
              ),
            ),
          ),
        );
      },
    );
  }

  void _centerViewportAt(Offset position, double width) {
    final fullStart = _traceStartNs(trace);
    final fullEnd = fullStart + math.max(1, trace.durationNs);
    final fullDuration = math.max(1, fullEnd - fullStart);
    final visibleDuration = math.max(1, viewEndNs - viewStartNs);
    final fraction = (position.dx / math.max(1, width)).clamp(0.0, 1.0);
    final center = fullStart + (fullDuration * fraction).round();
    onViewportChanged(
      center - (visibleDuration / 2).round(),
      center + (visibleDuration / 2).round(),
    );
  }
}

class _MinimapPainter extends CustomPainter {
  const _MinimapPainter({
    required this.trace,
    required this.colorScheme,
    required this.viewStartNs,
    required this.viewEndNs,
    required this.selected,
  });

  final TraceDocument trace;
  final ColorScheme colorScheme;
  final int viewStartNs;
  final int viewEndNs;
  final TraceSpan? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final fullStart = _traceStartNs(trace);
    final fullDuration = math.max(1, trace.durationNs);
    final trackCount = math.max(1, trace.trace.tracks.length);
    final trackIndex = {
      for (var i = 0; i < trace.trace.tracks.length; i++)
        trace.trace.tracks[i].id: i,
    };
    final basePaint = Paint()
      ..color = colorScheme.primary.withValues(alpha: 0.28);
    final selectedPaint = Paint()
      ..color = colorScheme.error.withValues(alpha: 0.90)
      ..strokeWidth = 2;
    final brushPaint = Paint()
      ..color = colorScheme.primary.withValues(alpha: 0.16);
    final brushBorderPaint = Paint()
      ..color = colorScheme.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final brushHandlePaint = Paint()
      ..color = colorScheme.primary
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.square;

    final laneHeight = math.max(3.0, (size.height - 10) / trackCount);
    const maxMinimapMarks = 12000;
    var rendered = 0;
    for (final span in trace.completeSpans) {
      if (rendered >= maxMinimapMarks) break;
      final lane = trackIndex[span.trackId] ?? 0;
      final end = span.endNs ?? span.startNs;
      final x =
          ((span.startNs - fullStart) / fullDuration).clamp(0.0, 1.0) *
          size.width;
      final right =
          ((end - fullStart) / fullDuration).clamp(0.0, 1.0) * size.width;
      final y = 5 + lane * laneHeight;
      canvas.drawRect(
        Rect.fromLTWH(x, y, math.max(1.0, right - x), math.max(2, laneHeight)),
        basePaint,
      );
      rendered++;
    }

    if (selected != null) {
      final x =
          ((selected!.startNs - fullStart) / fullDuration).clamp(0.0, 1.0) *
          size.width;
      canvas.drawLine(Offset(x, 3), Offset(x, size.height - 3), selectedPaint);
    }

    final brushLeft =
        ((viewStartNs - fullStart) / fullDuration).clamp(0.0, 1.0) * size.width;
    final brushRight =
        ((viewEndNs - fullStart) / fullDuration).clamp(0.0, 1.0) * size.width;
    final brush = Rect.fromLTRB(
      brushLeft,
      3,
      math.max(brushLeft + 3, brushRight),
      size.height - 3,
    );
    canvas.drawRect(brush, brushPaint);
    canvas.drawRect(brush, brushBorderPaint);
    canvas.drawLine(
      Offset(brush.left, 8),
      Offset(brush.left, size.height - 8),
      brushHandlePaint,
    );
    canvas.drawLine(
      Offset(brush.right, 8),
      Offset(brush.right, size.height - 8),
      brushHandlePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter oldDelegate) {
    return oldDelegate.trace != trace ||
        oldDelegate.viewStartNs != viewStartNs ||
        oldDelegate.viewEndNs != viewEndNs ||
        oldDelegate.selected != selected;
  }
}

class _TimelinePainter extends CustomPainter {
  const _TimelinePainter({
    required this.trace,
    required this.selected,
    required this.hovered,
    required this.colorScheme,
    required this.viewStartNs,
    required this.viewEndNs,
  });

  final TraceDocument trace;
  final TraceSpan? selected;
  final TraceSpan? hovered;
  final ColorScheme colorScheme;
  final int viewStartNs;
  final int viewEndNs;

  @override
  void paint(Canvas canvas, Size size) {
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    final leftGutter = _timelineLeftGutter(size.width);
    final timelineWidth = _timelineWidthFor(size.width);
    final durationNs = math.max(1, viewEndNs - viewStartNs);
    final timelineRight = leftGutter + timelineWidth;
    final axisPaint = Paint()
      ..color = colorScheme.outlineVariant
      ..strokeWidth = 1;
    final lanePaint = Paint()..color = const Color(0xfff1f4f0);
    final viewportPaint = Paint()
      ..color = colorScheme.primary.withValues(alpha: 0.10);
    final selectedPaint = Paint()
      ..color = colorScheme.error.withValues(alpha: 0.90);
    final hoveredPaint = Paint()
      ..color = colorScheme.tertiary.withValues(alpha: 0.92);
    final selectedOutlinePaint = Paint()
      ..color = colorScheme.error
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final hoveredOutlinePaint = Paint()
      ..color = colorScheme.tertiary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    canvas.drawRect(
      Rect.fromLTWH(leftGutter, 0, timelineWidth, size.height),
      viewportPaint,
    );

    for (var i = 0; i < trace.trace.tracks.length; i++) {
      final y = _timelineTop + i * _timelineLaneHeight;
      if (i.isEven) {
        canvas.drawRect(
          Rect.fromLTWH(0, y, size.width, _timelineLaneHeight),
          lanePaint,
        );
      }
      canvas.drawLine(
        Offset(leftGutter, y + _timelineLaneHeight),
        Offset(size.width, y + _timelineLaneHeight),
        axisPaint,
      );
      textPainter
        ..text = TextSpan(
          text: trace.trace.tracks[i].displayName,
          style: const TextStyle(fontSize: 11, color: Color(0xff28312f)),
        )
        ..layout(maxWidth: leftGutter - 12);
      textPainter.paint(canvas, Offset(10, y + 7));
    }

    final spanPaints = <String, Paint>{};
    final trackIndex = {
      for (var i = 0; i < trace.trace.tracks.length; i++)
        trace.trace.tracks[i].id: i,
    };

    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(
        leftGutter,
        _timelineTop,
        timelineWidth,
        math.max(0, size.height - _timelineTop),
      ),
    );

    final visibleSpanCount = trace.visibleSpanCountIn(viewStartNs, viewEndNs);
    final densityMode = visibleSpanCount > _maxDetailedTimelineSpans;
    final detailedSpans = <_TimelineSpanRect>[];
    final densityRows = <int, _TimelineDensityBuckets>{};

    _TimelineSpanRect? spanRectFor(TraceSpan span, int lane) {
      final endNs = math.max(span.startNs + 1, span.endNs ?? span.startNs + 1);
      if (endNs <= viewStartNs || span.startNs >= viewEndNs) return null;
      final x =
          leftGutter +
          ((span.startNs - viewStartNs) / durationNs).clamp(0.0, 1.0) *
              timelineWidth;
      final right =
          leftGutter +
          ((endNs - viewStartNs) / durationNs).clamp(0.0, 1.0) * timelineWidth;
      final projectedWidth = math.max(0.0, right - x);
      return _TimelineSpanRect(
        span: span,
        rect: Rect.fromLTWH(
          x.clamp(leftGutter, timelineRight).toDouble(),
          _timelineTop + lane * _timelineLaneHeight + _timelineBarTopInset,
          math.max(_timelineMinBarWidth, projectedWidth),
          _timelineBarHeight,
        ),
        projectedLeft: (x - leftGutter).clamp(0.0, timelineWidth).toDouble(),
        projectedRight: (right - leftGutter)
            .clamp(0.0, timelineWidth)
            .toDouble(),
        projectedWidth: projectedWidth,
      );
    }

    void drawSpanRect(_TimelineSpanRect spanRect) {
      final span = spanRect.span;
      final isSelected = identical(span, selected);
      final isHovered = identical(span, hovered);
      final paint = isSelected
          ? selectedPaint
          : isHovered
          ? hoveredPaint
          : spanPaints.putIfAbsent(
              trace.trace.spanName(span.spanId),
              () =>
                  Paint()
                    ..color = _spanColor(trace.trace.spanName(span.spanId)),
            );
      canvas.drawRRect(
        RRect.fromRectAndRadius(spanRect.rect, const Radius.circular(3)),
        paint,
      );
      if (isSelected || isHovered) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            spanRect.rect.inflate(1),
            const Radius.circular(4),
          ),
          isSelected ? selectedOutlinePaint : hoveredOutlinePaint,
        );
      }
    }

    trace.forEachVisibleSpan(viewStartNs, viewEndNs, (span) {
      final lane = trackIndex[span.trackId];
      if (lane == null) return;
      final spanRect = spanRectFor(span, lane);
      if (spanRect == null) return;
      if (densityMode) {
        densityRows
            .putIfAbsent(
              lane,
              () => _TimelineDensityBuckets(timelineWidth.ceil()),
            )
            .add(spanRect.projectedLeft, spanRect.projectedRight);
        if (spanRect.projectedWidth < _minDetailedTimelineSpanPixels ||
            detailedSpans.length >= _maxDetailedTimelineSpans) {
          return;
        }
      }
      detailedSpans.add(spanRect);
    });

    if (densityMode) {
      final densityPaint = Paint();
      for (final entry in densityRows.entries) {
        final lane = entry.key;
        final row = entry.value;
        final laneTop =
            _timelineTop + lane * _timelineLaneHeight + _timelineBarTopInset;
        final maxCount = math.max(1, row.maxCount);
        final maxLog = math.log(maxCount + 1);
        for (var bucket = 0; bucket < row.counts.length; bucket++) {
          final count = row.counts[bucket];
          if (count == 0) continue;
          final intensity = math.log(count + 1) / maxLog;
          final height = math.max(
            4.0,
            _timelineBarHeight * (0.35 + intensity * 0.65),
          );
          densityPaint.color = colorScheme.primary.withValues(
            alpha: 0.14 + intensity * 0.50,
          );
          canvas.drawRect(
            Rect.fromLTWH(
              leftGutter + bucket,
              laneTop + (_timelineBarHeight - height) / 2,
              1.25,
              height,
            ),
            densityPaint,
          );
        }
      }
    }

    for (final spanRect in detailedSpans) {
      drawSpanRect(spanRect);
    }

    for (final highlighted in [selected, hovered]) {
      if (highlighted == null) continue;
      final lane = trackIndex[highlighted.trackId];
      if (lane == null) continue;
      final spanRect = spanRectFor(highlighted, lane);
      if (spanRect == null) continue;
      drawSpanRect(spanRect);
    }
    canvas.restore();

    final markerSpan = selected ?? hovered;
    if (markerSpan != null) {
      final markerX =
          leftGutter +
          ((markerSpan.startNs - viewStartNs) / durationNs).clamp(0.0, 1.0) *
              timelineWidth;
      if (markerSpan.startNs >= viewStartNs &&
          markerSpan.startNs <= viewEndNs) {
        final markerPaint = Paint()
          ..color =
              (selected == null ? colorScheme.tertiary : colorScheme.error)
                  .withValues(alpha: 0.60)
          ..strokeWidth = 1;
        canvas.drawLine(
          Offset(markerX, _timelineTop),
          Offset(markerX, size.height),
          markerPaint,
        );
      }
    }

    textPainter
      ..text = TextSpan(
        text:
            '${formatNs(durationNs)} visible of ${formatNs(trace.durationNs)}',
        style: TextStyle(
          fontSize: 12,
          color: colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      )
      ..layout(maxWidth: size.width - 20);
    textPainter.paint(canvas, const Offset(10, 8));

    if (densityMode) {
      textPainter
        ..text = TextSpan(
          text:
              'Large trace mode: showing density for $visibleSpanCount spans; zoom in for individual spans.',
          style: TextStyle(
            fontSize: 11,
            color: colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        )
        ..layout(maxWidth: math.max(1, size.width - leftGutter - 24));
      textPainter.paint(canvas, Offset(leftGutter + 8, 8));
    }
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter oldDelegate) {
    return oldDelegate.trace != trace ||
        oldDelegate.selected != selected ||
        oldDelegate.hovered != hovered ||
        oldDelegate.viewStartNs != viewStartNs ||
        oldDelegate.viewEndNs != viewEndNs;
  }
}

class _TimelineSpanRect {
  const _TimelineSpanRect({
    required this.span,
    required this.rect,
    required this.projectedLeft,
    required this.projectedRight,
    required this.projectedWidth,
  });

  final TraceSpan span;
  final Rect rect;
  final double projectedLeft;
  final double projectedRight;
  final double projectedWidth;
}

class _TimelineDensityBuckets {
  _TimelineDensityBuckets(int bucketCount)
    : counts = List<int>.filled(math.max(1, bucketCount), 0);

  final List<int> counts;
  int maxCount = 0;

  void add(double left, double right) {
    final bucketCount = counts.length;
    final start = left.floor().clamp(0, bucketCount - 1).toInt();
    final end = math.max(start, right.ceil().clamp(0, bucketCount - 1).toInt());
    for (var bucket = start; bucket <= end; bucket++) {
      final count = counts[bucket] + 1;
      counts[bucket] = count;
      maxCount = math.max(maxCount, count);
    }
  }
}

class _SelectedSpanDetails extends StatelessWidget {
  const _SelectedSpanDetails({
    required this.trace,
    required this.span,
    required this.hoveredSpan,
  });

  final TraceDocument trace;
  final TraceSpan? span;
  final TraceSpan? hoveredSpan;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final activeSpan = span ?? hoveredSpan;
    if (activeSpan == null) {
      return _InspectorPanel(
        icon: Icons.touch_app,
        title: 'No span selected',
        child: Text(
          'Hover a span to preview it, or click a timeline bar / span row to pin its duration, track, correlation, and args.',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      );
    }
    final selected = activeSpan;
    final sql = trace.sqlForSpan(selected);
    return _InspectorPanel(
      icon: Icons.manage_search,
      title: span == null ? 'Hovered Span' : 'Selected Span',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _InlineDatum(
                label: 'span',
                value: trace.trace.spanName(selected.spanId),
              ),
              _InlineDatum(
                label: 'duration',
                value: formatNs(selected.durationNs),
              ),
              _InlineDatum(label: 'track', value: '${selected.trackId}'),
              if (selected.begin.correlationId != null)
                _InlineDatum(
                  label: 'correlation',
                  value: '${selected.begin.correlationId}',
                ),
              if (selected.beginArgs.isNotEmpty)
                _InlineDatum(
                  label: 'begin args',
                  value: _formatSpanArgs(
                    trace,
                    selected,
                    selected.beginArgs,
                    phase: _SpanArgPhase.begin,
                  ),
                ),
              if (selected.endArgs.isNotEmpty)
                _InlineDatum(
                  label: 'end args',
                  value: _formatSpanArgs(
                    trace,
                    selected,
                    selected.endArgs,
                    phase: _SpanArgPhase.end,
                  ),
                ),
            ],
          ),
          if (sql != null) ...[
            const SizedBox(height: 10),
            Divider(color: colors.outlineVariant, height: 1),
            const SizedBox(height: 10),
            Wrap(
              spacing: 16,
              runSpacing: 10,
              children: [
                _InlineDatum(label: 'sql fingerprint', value: sql.fingerprint),
                _InlineDatum(label: 'sql mode', value: sql.mode),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText.rich(
              TextSpan(
                style: DefaultTextStyle.of(context).style,
                children: [
                  TextSpan(
                    text: 'normalized SQL: ',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(text: sql.normalizedSql),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum _SpanArgPhase { begin, end }

String _formatSpanArgs(
  TraceDocument trace,
  TraceSpan span,
  List<int> args, {
  required _SpanArgPhase phase,
}) {
  switch ((span.spanId, phase)) {
    case (BuiltinSpans.sqlite3Open, _SpanArgPhase.begin):
      return _joinNamedArgs([('filename', _stringArg(trace, args, 0))]);
    case (BuiltinSpans.sqlite3OpenV2, _SpanArgPhase.begin):
      return _joinNamedArgs([
        ('filename', _stringArg(trace, args, 0)),
        ('flags', _intArg(args, 1)),
        ('vfs', _stringArg(trace, args, 2)),
      ]);
    case (BuiltinSpans.sqlite3PrepareV2, _SpanArgPhase.begin):
      return _joinNamedArgs([
        ('db', _ptrArg(args, 0)),
        ('sql', _prepareSqlSummary(trace, span)),
      ]);
    case (BuiltinSpans.sqlite3PrepareV3, _SpanArgPhase.begin):
      return _joinNamedArgs([
        ('db', _ptrArg(args, 0)),
        ('sql', _prepareSqlSummary(trace, span)),
        ('flags', _intArg(args, 2)),
      ]);
    case (BuiltinSpans.sqlite3PrepareV2, _SpanArgPhase.end):
    case (BuiltinSpans.sqlite3PrepareV3, _SpanArgPhase.end):
      return _joinNamedArgs([
        ('stmt', _ptrArg(args, 0)),
        ('rc', _intArg(args, 1)),
      ]);
    case (BuiltinSpans.sqlite3Step, _SpanArgPhase.begin):
    case (BuiltinSpans.sqlite3Reset, _SpanArgPhase.begin):
    case (BuiltinSpans.sqlite3Finalize, _SpanArgPhase.begin):
      return _joinNamedArgs([('stmt', _stmtArg(trace, span, args, 0))]);
    case (BuiltinSpans.sqlite3Step, _SpanArgPhase.end):
    case (BuiltinSpans.sqlite3Reset, _SpanArgPhase.end):
    case (BuiltinSpans.sqlite3Finalize, _SpanArgPhase.end):
      return _joinNamedArgs([('rc', _intArg(args, 0))]);
    case (BuiltinSpans.sqlite3BindNull, _SpanArgPhase.begin):
      return _joinNamedArgs([
        ('stmt', _stmtArg(trace, span, args, 0)),
        ('idx', _intArg(args, 1)),
      ]);
    case (BuiltinSpans.sqlite3BindInt, _SpanArgPhase.begin):
    case (BuiltinSpans.sqlite3BindInt64, _SpanArgPhase.begin):
      return _joinNamedArgs([
        ('stmt', _stmtArg(trace, span, args, 0)),
        ('idx', _intArg(args, 1)),
        ('value', _intArg(args, 2)),
      ]);
    case (BuiltinSpans.sqlite3BindDouble, _SpanArgPhase.begin):
      return _joinNamedArgs([
        ('stmt', _stmtArg(trace, span, args, 0)),
        ('idx', _intArg(args, 1)),
        ('bits', _intArg(args, 2)),
      ]);
    case (BuiltinSpans.sqlite3BindText, _SpanArgPhase.begin):
    case (BuiltinSpans.sqlite3BindBlob, _SpanArgPhase.begin):
      return _joinNamedArgs([
        ('stmt', _stmtArg(trace, span, args, 0)),
        ('idx', _intArg(args, 1)),
        ('len', _intArg(args, 2)),
      ]);
    case (BuiltinSpans.sqlite3ClearBindings, _SpanArgPhase.begin):
    case (BuiltinSpans.sqlite3ColumnCount, _SpanArgPhase.begin):
      return _joinNamedArgs([('stmt', _stmtArg(trace, span, args, 0))]);
    case (BuiltinSpans.sqlite3ColumnInt, _SpanArgPhase.begin):
    case (BuiltinSpans.sqlite3ColumnInt64, _SpanArgPhase.begin):
    case (BuiltinSpans.sqlite3ColumnDouble, _SpanArgPhase.begin):
    case (BuiltinSpans.sqlite3ColumnText, _SpanArgPhase.begin):
    case (BuiltinSpans.sqlite3ColumnBlob, _SpanArgPhase.begin):
    case (BuiltinSpans.sqlite3ColumnBytes, _SpanArgPhase.begin):
      return _joinNamedArgs([
        ('stmt', _stmtArg(trace, span, args, 0)),
        ('col', _intArg(args, 1)),
      ]);
    case (BuiltinSpans.sqlite3BindNull, _SpanArgPhase.end):
    case (BuiltinSpans.sqlite3BindInt, _SpanArgPhase.end):
    case (BuiltinSpans.sqlite3BindInt64, _SpanArgPhase.end):
    case (BuiltinSpans.sqlite3BindDouble, _SpanArgPhase.end):
    case (BuiltinSpans.sqlite3BindText, _SpanArgPhase.end):
    case (BuiltinSpans.sqlite3BindBlob, _SpanArgPhase.end):
    case (BuiltinSpans.sqlite3ClearBindings, _SpanArgPhase.end):
      return _joinNamedArgs([('rc', _intArg(args, 0))]);
    case (BuiltinSpans.sqlite3ColumnCount, _SpanArgPhase.end):
    case (BuiltinSpans.sqlite3ColumnInt, _SpanArgPhase.end):
    case (BuiltinSpans.sqlite3ColumnInt64, _SpanArgPhase.end):
    case (BuiltinSpans.sqlite3ColumnDouble, _SpanArgPhase.end):
    case (BuiltinSpans.sqlite3ColumnText, _SpanArgPhase.end):
    case (BuiltinSpans.sqlite3ColumnBlob, _SpanArgPhase.end):
    case (BuiltinSpans.sqlite3ColumnBytes, _SpanArgPhase.end):
      return _joinNamedArgs([('value', _intArg(args, 0))]);
    default:
      return args.join(', ');
  }
}

String _spanArgsSummary(TraceDocument trace, TraceSpan span) {
  final parts = [
    if (span.beginArgs.isNotEmpty)
      'begin ${_formatSpanArgs(trace, span, span.beginArgs, phase: _SpanArgPhase.begin)}',
    if (span.endArgs.isNotEmpty)
      'end ${_formatSpanArgs(trace, span, span.endArgs, phase: _SpanArgPhase.end)}',
  ];
  return parts.isEmpty ? '-' : parts.join(' / ');
}

String _prepareSqlSummary(TraceDocument trace, TraceSpan span) {
  final details = trace.prepareSqlForSpan(span);
  if (details == null) return _intArg(span.beginArgs, 1);
  if (details.fingerprint == 'raw') {
    return _truncateForTable(details.normalizedSql);
  }
  return '${_shortFingerprint(details.fingerprint)} ${_truncateForTable(details.normalizedSql)}';
}

String _joinNamedArgs(List<(String, String)> args) {
  return [
    for (final (name, value) in args)
      if (value.isNotEmpty) '$name=$value',
  ].join(', ');
}

String _stringArg(TraceDocument trace, List<int> args, int index) {
  if (index >= args.length) return '';
  final id = args[index];
  final value = trace.trace.strings[id];
  if (value == null) return '$id';
  return '"${_truncateForTable(value)}"';
}

String _stmtArg(
  TraceDocument trace,
  TraceSpan span,
  List<int> args,
  int index,
) {
  final pointer = _ptrArg(args, index);
  final sql = trace.sqlForSpan(span);
  if (sql == null) return pointer;
  return '$pointer ${_shortFingerprint(sql.fingerprint)} ${_truncateForTable(sql.normalizedSql, maxLength: 96)}';
}

String _ptrArg(List<int> args, int index) {
  if (index >= args.length) return '';
  final value = args[index];
  return '0x${value.toRadixString(16)}';
}

String _intArg(List<int> args, int index) {
  if (index >= args.length) return '';
  return '${args[index]}';
}

String _truncateForTable(String value, {int maxLength = 140}) {
  if (value.length <= maxLength) return value;
  return '${value.substring(0, maxLength - 1)}...';
}

class PeerComparisonTable extends StatelessWidget {
  const PeerComparisonTable({super.key, required this.compare});

  final CompareDocument compare;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 34,
        dataRowMinHeight: 34,
        dataRowMaxHeight: 44,
        columns: const [
          DataColumn(label: Text('peer')),
          DataColumn(label: Text('status')),
          DataColumn(label: Text('reps'), numeric: true),
          DataColumn(label: Text('measured mean'), numeric: true),
          DataColumn(label: Text('measured cv'), numeric: true),
          DataColumn(label: Text('scenario mean'), numeric: true),
          DataColumn(label: Text('sqlite3_step'), numeric: true),
          DataColumn(label: Text('sqlite step time'), numeric: true),
          DataColumn(label: Text('events'), numeric: true),
          DataColumn(label: Text('trace health')),
        ],
        rows: [
          for (final peer in compare.peers)
            DataRow(
              cells: [
                DataCell(Text(peer.name)),
                DataCell(_StatusPill(status: peer.status)),
                DataCell(
                  Text('${peer.successfulRepetitions}/${compare.repetitions}'),
                ),
                DataCell(
                  Text(formatMeanNs(peer.metric('measured_elapsed_ns'))),
                ),
                DataCell(Text(formatCv(peer.metric('measured_elapsed_ns')))),
                DataCell(Text(formatMeanNs(peer.metric('elapsed_ns')))),
                DataCell(
                  Text(formatCountMean(peer.metric('sqlite3_step_count'))),
                ),
                DataCell(
                  Text(formatMeanNs(peer.metric('sqlite3_step_total_ns'))),
                ),
                DataCell(Text(formatCountMean(peer.metric('events')))),
                DataCell(Text(_healthText(peer))),
              ],
            ),
        ],
      ),
    );
  }

  String _healthText(PeerSummary peer) {
    final dropped = peer.metric('dropped_events')?.max ?? 0;
    final begin = peer.metric('unmatched_begin_events')?.max ?? 0;
    final end = peer.metric('unmatched_end_events')?.max ?? 0;
    return '$dropped/$begin/$end';
  }
}

class PeerSpanBreakdown extends StatelessWidget {
  const PeerSpanBreakdown({super.key, required this.compare});

  final CompareDocument compare;

  @override
  Widget build(BuildContext context) {
    final rows = <List<String>>[];
    for (final peer in compare.peers) {
      final sample = peer.samples
          .where((sample) => sample.status == 'ok')
          .firstOrNull;
      if (sample == null) {
        rows.add([peer.name, peer.status, '-', '-', '-']);
        continue;
      }
      for (final group in sample.spanGroups.take(5)) {
        rows.add([
          peer.name,
          group.name,
          '${group.count}',
          formatNs(group.totalNs),
          formatNs(group.p90Ns),
        ]);
      }
    }
    return _SimpleArtifactTable(
      headers: const ['peer', 'span', 'count', 'total', 'p90'],
      rows: rows,
    );
  }
}

class PeerSqlFingerprintBreakdown extends StatelessWidget {
  const PeerSqlFingerprintBreakdown({super.key, required this.compare});

  final CompareDocument compare;

  @override
  Widget build(BuildContext context) {
    final rows = <List<String>>[];
    for (final peer in compare.peers) {
      final sample = peer.samples
          .where((sample) => sample.status == 'ok')
          .firstOrNull;
      if (sample == null) {
        rows.add([peer.name, peer.status, '-', '-', '-', '-']);
        continue;
      }
      if (sample.sqlFingerprintGroups.isEmpty) {
        rows.add([peer.name, 'no SQL fingerprints', '-', '-', '-', '-']);
        continue;
      }
      for (final group in sample.sqlFingerprintGroups.take(8)) {
        rows.add([
          peer.name,
          _shortFingerprint(group.fingerprint),
          '${group.prepareCount}',
          formatNs(group.prepareTotalNs),
          formatNs(group.prepareP90Ns),
          group.normalizedSql,
        ]);
      }
    }
    return _SimpleArtifactTable(
      headers: const ['peer', 'fingerprint', 'prepares', 'total', 'p90', 'sql'],
      rows: rows,
    );
  }
}

String _shortFingerprint(String fingerprint) {
  const prefix = 'sqlfp:v1:';
  if (!fingerprint.startsWith(prefix)) return fingerprint;
  final hash = fingerprint.substring(prefix.length);
  return hash.length <= 8 ? fingerprint : '$prefix${hash.substring(0, 8)}';
}

class SpanIndexPanel extends StatelessWidget {
  const SpanIndexPanel({
    super.key,
    required this.trace,
    required this.spans,
    required this.selected,
    required this.filterController,
    required this.onFilterChanged,
    required this.onSelected,
  });

  final TraceDocument trace;
  final List<TraceSpan> spans;
  final TraceSpan? selected;
  final TextEditingController filterController;
  final ValueChanged<String> onFilterChanged;
  final ValueChanged<TraceSpan> onSelected;

  @override
  Widget build(BuildContext context) {
    final visibleRows = spans.take(300).toList();
    final omitted = spans.length - visibleRows.length;
    final colors = Theme.of(context).colorScheme;
    final tableHeight = math.min(420.0, 42.0 + visibleRows.length * 42.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: filterController,
                onChanged: onFilterChanged,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.search),
                  labelText:
                      'Filter spans by name, SQL, args, track, or correlation',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${spans.length} matches',
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: tableHeight,
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 34,
                dataRowMinHeight: 34,
                dataRowMaxHeight: 42,
                columns: const [
                  DataColumn(label: Text('span')),
                  DataColumn(label: Text('start'), numeric: true),
                  DataColumn(label: Text('duration'), numeric: true),
                  DataColumn(label: Text('track'), numeric: true),
                  DataColumn(label: Text('correlation'), numeric: true),
                  DataColumn(label: Text('args')),
                ],
                rows: [
                  for (final (index, span) in visibleRows.indexed)
                    DataRow(
                      key: ValueKey('span-row-$index'),
                      selected: identical(span, selected),
                      onSelectChanged: (_) => onSelected(span),
                      cells: [
                        DataCell(
                          Text(
                            trace.trace.spanName(span.spanId),
                            key: ValueKey('span-row-$index-name'),
                          ),
                        ),
                        DataCell(Text(formatNs(_startOffsetNs(span)))),
                        DataCell(Text(formatNs(span.durationNs))),
                        DataCell(Text('${span.trackId}')),
                        DataCell(Text('${span.begin.correlationId ?? '-'}')),
                        DataCell(
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 340),
                            child: Text(
                              _spanArgsSummary(trace, span),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
        if (omitted > 0) ...[
          const SizedBox(height: 8),
          Text(
            'Showing the first ${visibleRows.length}; refine the filter to narrow $omitted more spans.',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  int _startOffsetNs(TraceSpan span) {
    final events = trace.trace.events;
    final start = events.isEmpty ? 0 : events.first.timestampNs;
    return math.max(0, span.startNs - start);
  }
}

class SpanAggregationTable extends StatelessWidget {
  const SpanAggregationTable({super.key, required this.groups});

  final List<SpanGroupStats> groups;

  @override
  Widget build(BuildContext context) {
    return _SimpleArtifactTable(
      headers: const ['span', 'count', 'total', 'p50', 'p90', 'p99'],
      rows: [
        for (final group in groups.take(40))
          [
            group.spanName,
            '${group.stats.count}',
            formatNs(group.stats.totalNs),
            formatNs(group.stats.p50Ns),
            formatNs(group.stats.p90Ns),
            formatNs(group.stats.p99Ns),
          ],
      ],
    );
  }
}

class GraphDataTable extends StatelessWidget {
  const GraphDataTable({super.key, required this.graphData});

  final List<GraphDataDocument> graphData;

  @override
  Widget build(BuildContext context) {
    if (graphData.isEmpty) return const Text('No graph-data bundles loaded.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final graph in graphData)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _SimpleArtifactTable(
              headers: const ['dataset', 'rows', 'status'],
              rows: [
                for (final entry in graph.counts.entries)
                  [
                    entry.key,
                    '${entry.value}',
                    graph.validationErrors.isEmpty ? 'valid' : 'invalid',
                  ],
              ],
            ),
          ),
      ],
    );
  }
}

class WorkloadTable extends StatelessWidget {
  const WorkloadTable({super.key, required this.workloads});

  final List<WorkloadSummaryDocument> workloads;

  @override
  Widget build(BuildContext context) {
    if (workloads.isEmpty) return const Text('No workload summaries loaded.');
    return _SimpleArtifactTable(
      headers: const [
        'artifact',
        'workload',
        'iterations',
        'samples',
        'operations',
        'memory',
        'fanout',
      ],
      rows: [
        for (final artifact in workloads)
          for (final workload in artifact.workloads)
            [
              artifact.name,
              workload.name,
              '${workload.iterations}',
              '${workload.sampleCount}',
              '${workload.operations}',
              workload.hasMemory ? 'yes' : '-',
              workload.hasFanout ? 'yes' : '-',
            ],
      ],
    );
  }
}

class _ArtifactSummary extends StatelessWidget {
  const _ArtifactSummary({required this.workspace});

  final VisualizerWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    if (workspace.isEmpty) {
      return const Text('No supported artifacts were found at this path.');
    }
    return _SimpleArtifactTable(
      headers: const ['type', 'name', 'detail'],
      rows: [
        for (final trace in workspace.traces)
          ['trace', trace.name, '${trace.trace.events.length} events'],
        for (final compare in workspace.compares)
          [
            'compare',
            compare.name,
            '${compare.scenario}, ${compare.peers.length} peers',
          ],
        for (final suite in workspace.suites)
          ['suite', suite.name, '${suite.profile}, ${suite.runs.length} runs'],
        for (final decision in workspace.decisions)
          ['decision', decision.name, decision.verdict],
        for (final workload in workspace.workloads)
          ['workload', workload.name, '${workload.workloads.length} workloads'],
        for (final graph in workspace.graphData)
          ['graph-data', graph.name, '${graph.counts.length} datasets'],
      ],
    );
  }
}

class _IssueList extends StatelessWidget {
  const _IssueList({required this.issues});

  final List<LoadIssue> issues;

  @override
  Widget build(BuildContext context) {
    return _SimpleArtifactTable(
      headers: const ['path', 'issue'],
      rows: [
        for (final issue in issues) [issue.path, issue.message],
      ],
    );
  }
}

class _SimpleArtifactTable extends StatelessWidget {
  const _SimpleArtifactTable({
    this.headers = const ['name', 'detail', 'status'],
    required this.rows,
  });

  final List<String> headers;
  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const Text('Nothing loaded.');
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 34,
        dataRowMinHeight: 34,
        dataRowMaxHeight: 46,
        columns: [
          for (final header in headers) DataColumn(label: Text(header)),
        ],
        rows: [
          for (final row in rows)
            DataRow(
              cells: [
                for (var i = 0; i < headers.length; i++)
                  DataCell(
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Text(
                        i < row.length ? row[i] : '',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ArtifactPicker extends StatelessWidget {
  const _ArtifactPicker({
    required this.label,
    required this.value,
    required this.itemCount,
    required this.itemLabel,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int itemCount;
  final String Function(int index) itemLabel;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: DropdownButtonFormField<int>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          labelText: label,
          prefixIcon: const Icon(Icons.folder_open),
        ),
        items: [
          for (var i = 0; i < itemCount; i++)
            DropdownMenuItem(
              value: i,
              child: Text(itemLabel(i), overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class _ToolGuideEntry {
  const _ToolGuideEntry({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;
}

class _ToolGuide extends StatelessWidget {
  const _ToolGuide({required this.entries});

  final List<_ToolGuideEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [for (final entry in entries) _ToolGuideTile(entry: entry)],
    );
  }
}

class _ToolGuideTile extends StatelessWidget {
  const _ToolGuideTile({required this.entry});

  final _ToolGuideEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 245,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(entry.icon, color: colors.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 3),
                Text(
                  entry.body,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InsightList extends StatelessWidget {
  const _InsightList({required this.insights});

  final List<BenchmarkInsight> insights;

  @override
  Widget build(BuildContext context) {
    if (insights.isEmpty) {
      return const Text('No interpreted findings for this artifact.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final insight in insights)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _InsightRow(insight: insight),
          ),
      ],
    );
  }
}

class _InsightRow extends StatelessWidget {
  const _InsightRow({required this.insight});

  final BenchmarkInsight insight;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = _insightColor(colors, insight.severity);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(_insightIcon(insight.severity), color: color, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                insight.title,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 3),
              Text(
                insight.body,
                style: TextStyle(color: colors.onSurfaceVariant, height: 1.25),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Color _insightColor(ColorScheme colors, String severity) {
  return switch (severity) {
    'critical' => colors.error,
    'warning' => const Color(0xff8a5a00),
    'good' => const Color(0xff177245),
    _ => colors.primary,
  };
}

IconData _insightIcon(String severity) {
  return switch (severity) {
    'critical' => Icons.error_outline,
    'warning' => Icons.warning_amber,
    'good' => Icons.check_circle_outline,
    _ => Icons.info_outline,
  };
}

int _insightSeverityRank(String severity) {
  return switch (severity) {
    'critical' => 0,
    'warning' => 1,
    'info' => 2,
    'good' => 3,
    _ => 4,
  };
}

class _InspectorPanel extends StatelessWidget {
  const _InspectorPanel({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: colors.primary, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  child,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.detail,
  });

  final IconData icon;
  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 230,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(icon, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  detail,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _PageScaffold extends StatelessWidget {
  const _PageScaffold({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(bottom: BorderSide(color: colors.outlineVariant)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: colors.primary),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return _EmptyState(
      icon: Icons.error_outline,
      title: 'Unable to load workspace',
      body: error,
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isOk = status == 'ok';
    final isUnsupported = status == 'unsupported';
    final color = isOk
        ? const Color(0xff177245)
        : isUnsupported
        ? const Color(0xff8a5a00)
        : colors.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _InlineDatum extends StatelessWidget {
  const _InlineDatum({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: DefaultTextStyle.of(context).style,
        children: [
          TextSpan(
            text: '$label: ',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(text: value.isEmpty ? '-' : value),
        ],
      ),
    );
  }
}

Color _spanColor(String name) {
  final palette = [
    const Color(0xff2d6cdf),
    const Color(0xff15906d),
    const Color(0xffa15c14),
    const Color(0xff8054b3),
    const Color(0xffb23a48),
    const Color(0xff4a7c24),
    const Color(0xff306178),
  ];
  var hash = 0;
  for (final unit in name.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return palette[hash % palette.length].withValues(alpha: 0.88);
}

String _formatPercent(double value) {
  if (value >= 10) return value.toStringAsFixed(0);
  if (value >= 1) return value.toStringAsFixed(1);
  return value.toStringAsFixed(2);
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
