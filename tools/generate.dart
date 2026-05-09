// tracelite — schema generator.
//
// Reads tools/spans.yaml and emits:
//
//   - lib/src/builtin_spans.g.dart    Dart constants
//   - native/builtin_spans.g.h        C #defines
//   - doc/format-spec.appendix.md     Markdown appendix tables
//   - doc/span-registry.generated.md  span-registry tables
//
// Run: dart run tools/generate.dart
//
// Run with --check to verify outputs are up to date without writing
// (useful in CI).
//
// This file has no external package dependencies beyond `yaml` so the
// generator can run in a minimal environment.

// ignore_for_file: avoid_print

import 'dart:io';
import 'package:yaml/yaml.dart';

void main(List<String> args) async {
  final check = args.contains('--check');
  final repoRoot = _findRepoRoot();

  final yamlPath = '$repoRoot/tools/spans.yaml';
  final yamlText = await File(yamlPath).readAsString();
  final yamlDoc = loadYaml(yamlText) as YamlMap;

  final spec = SpansSpec.fromYaml(yamlDoc);
  spec.validate();

  final outputs = {
    '$repoRoot/lib/src/builtin_spans.g.dart': spec.dartConstants(),
    '$repoRoot/native/builtin_spans.g.h': spec.cHeader(),
    '$repoRoot/doc/format-spec.appendix.md': spec.formatAppendix(),
    '$repoRoot/doc/span-registry.generated.md': spec.registryTables(),
  };

  var failures = 0;
  for (final entry in outputs.entries) {
    final path = entry.key;
    final wanted = entry.value;
    final file = File(path);
    final exists = await file.exists();
    final actual = exists ? await file.readAsString() : '';

    if (check) {
      if (actual != wanted) {
        print('STALE: $path');
        failures++;
      }
    } else {
      await file.parent.create(recursive: true);
      await file.writeAsString(wanted);
      print('wrote: $path  (${wanted.length} bytes)');
    }
  }

  if (check && failures > 0) {
    print('\n$failures generated file(s) out of date. Run `dart run tools/generate.dart` and commit.');
    exit(1);
  }
  if (!check) {
    print('\nGenerated ${outputs.length} files from $yamlPath');
  }
}

String _findRepoRoot() {
  var dir = Directory.current.path;
  while (dir != '/' && dir.isNotEmpty) {
    if (File('$dir/tools/spans.yaml').existsSync()) return dir;
    dir = Directory(dir).parent.path;
  }
  throw StateError('Could not locate tools/spans.yaml from ${Directory.current.path}');
}

// ---------------------------------------------------------------------
// Domain model
// ---------------------------------------------------------------------

class SpansSpec {
  SpansSpec({
    required this.formatVersion,
    required this.ranges,
    required this.spans,
  });

  final List<int> formatVersion;
  final Map<String, List<int>> ranges;
  final List<SpanDef> spans;

  factory SpansSpec.fromYaml(YamlMap doc) {
    final fv = (doc['format_version'] as YamlList).cast<int>().toList();

    final ranges = <String, List<int>>{};
    for (final entry in (doc['ranges'] as YamlMap).entries) {
      ranges[entry.key as String] =
          (entry.value as YamlList).cast<int>().toList();
    }

    final spans = <SpanDef>[];
    for (final s in (doc['spans'] as YamlList)) {
      spans.add(SpanDef.fromYaml(s as YamlMap));
    }

    return SpansSpec(formatVersion: fv, ranges: ranges, spans: spans);
  }

  void validate() {
    final seenIds = <int>{};
    final seenNames = <String>{};
    for (final span in spans) {
      if (!seenIds.add(span.id)) {
        throw FormatException('duplicate span id 0x${span.id.toRadixString(16)}: ${span.name}');
      }
      if (!seenNames.add(span.name)) {
        throw FormatException('duplicate span name: ${span.name}');
      }

      // Range membership
      final categoryRange = ranges[_categoryToRangeKey(span.category)];
      if (categoryRange == null) {
        throw FormatException('unknown range for category ${span.category} on ${span.name}');
      }
      if (span.id < categoryRange[0] || span.id > categoryRange[1]) {
        throw FormatException(
          'span ${span.name} (0x${span.id.toRadixString(16)}) is outside '
          'category $span.category range '
          '0x${categoryRange[0].toRadixString(16)}–0x${categoryRange[1].toRadixString(16)}',
        );
      }

      // Schemas: at most one of (begin/end) vs instant should be non-empty.
      final hasBeginEnd = span.beginArgs.isNotEmpty || span.endArgs.isNotEmpty;
      final hasInstant = span.instantArgs.isNotEmpty;
      if (hasBeginEnd && hasInstant) {
        throw FormatException(
          '${span.name}: cannot have both begin/end_args and instant_args; '
          'pick one phase model',
        );
      }

      // List args must be the last positional arg in their phase.
      for (final phase in [span.beginArgs, span.endArgs, span.instantArgs]) {
        for (var i = 0; i < phase.length; i++) {
          if (phase[i].type.startsWith('list_') && i != phase.length - 1) {
            throw FormatException(
              '${span.name}: list arg ${phase[i].name} must be the last '
              'arg in its phase; format-spec §9 requires this.',
            );
          }
        }
      }
    }
  }

  String _categoryToRangeKey(String category) {
    return switch (category) {
      'tracelite' => 'tracelite',
      'sqlite_c' => 'sqlite_c',
      'dart_recorder' => 'dart_recorder',
      'ffi_bridge' => 'ffi_bridge',
      'user' => 'user',
      _ => throw FormatException('unknown category: $category'),
    };
  }

  // -------------------------------------------------------------------
  // Output: Dart constants
  // -------------------------------------------------------------------
  String dartConstants() {
    final buf = StringBuffer();
    buf.writeln('// GENERATED FILE — DO NOT EDIT.');
    buf.writeln('// Source: tools/spans.yaml');
    buf.writeln('// Regenerate with: dart run tools/generate.dart');
    buf.writeln('');
    buf.writeln('// ignore_for_file: constant_identifier_names, public_member_api_docs');
    buf.writeln('');
    buf.writeln('/// Format version this build of tracelite produces / consumes.');
    buf.writeln('const List<int> kFormatVersion = [${formatVersion.join(', ')}];');
    buf.writeln('');
    buf.writeln('/// Built-in span IDs. Stable across format minor versions.');
    buf.writeln('class BuiltinSpans {');
    buf.writeln('  BuiltinSpans._();');
    buf.writeln();
    for (final span in spans) {
      final dartName = _toDartIdentifier(span.name);
      final hex = span.id.toRadixString(16).toUpperCase().padLeft(4, '0');
      buf.writeln('  /// `${span.name}` — category: ${span.category}');
      buf.writeln('  static const int $dartName = 0x$hex;');
      buf.writeln();
    }
    buf.writeln('}');
    buf.writeln();
    buf.writeln('/// Mapping from span ID to canonical name.');
    buf.writeln('const Map<int, String> kSpanNames = {');
    for (final span in spans) {
      buf.writeln('  0x${span.id.toRadixString(16).toUpperCase().padLeft(4, '0')}: \'${span.name}\',');
    }
    buf.writeln('};');
    return buf.toString();
  }

  String _toDartIdentifier(String name) {
    // sqlite3_step → sqlite3Step ; dart.gc.minor → dartGcMinor ; _trace_start → traceStart
    var s = name;
    if (s.startsWith('_')) s = s.substring(1);
    final parts = s.split(RegExp(r'[._]'));
    final head = parts.first;
    final tail = parts.skip(1).map((p) => p.isEmpty
        ? ''
        : (p[0].toUpperCase() + p.substring(1)));
    return head + tail.join();
  }

  // -------------------------------------------------------------------
  // Output: C header
  // -------------------------------------------------------------------
  String cHeader() {
    final buf = StringBuffer();
    buf.writeln('/* GENERATED FILE — DO NOT EDIT. */');
    buf.writeln('/* Source: tools/spans.yaml */');
    buf.writeln('/* Regenerate with: dart run tools/generate.dart */');
    buf.writeln();
    buf.writeln('#ifndef TRACELITE_BUILTIN_SPANS_G_H');
    buf.writeln('#define TRACELITE_BUILTIN_SPANS_G_H');
    buf.writeln();
    buf.writeln(
        '#define TRACELITE_FORMAT_MAJOR ${formatVersion[0]}');
    buf.writeln(
        '#define TRACELITE_FORMAT_MINOR ${formatVersion[1]}');
    buf.writeln();
    for (final span in spans) {
      final macro = 'SPAN_${span.name.toUpperCase().replaceAll('.', '_').replaceAll('_', '_')}';
      final hex = span.id.toRadixString(16).toUpperCase().padLeft(4, '0');
      buf.writeln('/* ${span.name} (${span.category}) */');
      buf.writeln('#define $macro 0x$hex');
    }
    buf.writeln();
    buf.writeln('#endif /* TRACELITE_BUILTIN_SPANS_G_H */');
    return buf.toString();
  }

  // -------------------------------------------------------------------
  // Output: Markdown appendix
  // -------------------------------------------------------------------
  String formatAppendix() {
    final buf = StringBuffer();
    buf.writeln('# Format spec appendix — built-in span IDs');
    buf.writeln();
    buf.writeln('GENERATED FROM `tools/spans.yaml` — do not edit by hand.');
    buf.writeln();
    buf.writeln('| ID | Name | Category | Phases |');
    buf.writeln('|---|---|---|---|');
    for (final span in spans) {
      final hex = '0x${span.id.toRadixString(16).toUpperCase().padLeft(4, '0')}';
      final phases = <String>[];
      if (span.beginArgs.isNotEmpty) phases.add('begin(${span.beginArgs.length})');
      if (span.endArgs.isNotEmpty) phases.add('end(${span.endArgs.length})');
      if (span.instantArgs.isNotEmpty) phases.add('instant(${span.instantArgs.length})');
      buf.writeln('| `$hex` | `${span.name}` | ${span.category} | ${phases.join(', ')} |');
    }
    return buf.toString();
  }

  // -------------------------------------------------------------------
  // Output: span-registry tables (full schemas)
  // -------------------------------------------------------------------
  String registryTables() {
    final buf = StringBuffer();
    buf.writeln('# Span registry — full schemas');
    buf.writeln();
    buf.writeln('GENERATED FROM `tools/spans.yaml` — do not edit by hand.');
    buf.writeln();

    // Group by category
    final byCat = <String, List<SpanDef>>{};
    for (final s in spans) {
      byCat.putIfAbsent(s.category, () => []).add(s);
    }

    for (final entry in byCat.entries) {
      buf.writeln('## ${entry.key}');
      buf.writeln();
      buf.writeln('| ID | Name | Begin args | End args | Instant args |');
      buf.writeln('|---|---|---|---|---|');
      for (final span in entry.value) {
        final hex = '0x${span.id.toRadixString(16).toUpperCase().padLeft(4, '0')}';
        buf.writeln(
          '| `$hex` | `${span.name}` | '
          '${_argsToString(span.beginArgs)} | '
          '${_argsToString(span.endArgs)} | '
          '${_argsToString(span.instantArgs)} |',
        );
      }
      buf.writeln();
    }
    return buf.toString();
  }

  String _argsToString(List<ArgDef> args) {
    if (args.isEmpty) return '—';
    return args.map((a) => '`${a.name}: ${a.type}`').join(', ');
  }
}

class SpanDef {
  SpanDef({
    required this.id,
    required this.name,
    required this.category,
    required this.beginArgs,
    required this.endArgs,
    required this.instantArgs,
    this.deprecated = false,
    this.supersededBy,
  });

  final int id;
  final String name;
  final String category;
  final List<ArgDef> beginArgs;
  final List<ArgDef> endArgs;
  final List<ArgDef> instantArgs;
  final bool deprecated;
  final int? supersededBy;

  factory SpanDef.fromYaml(YamlMap m) {
    return SpanDef(
      id: m['id'] as int,
      name: m['name'] as String,
      category: m['category'] as String,
      beginArgs: _argList(m['begin_args']),
      endArgs: _argList(m['end_args']),
      instantArgs: _argList(m['instant_args']),
      deprecated: m['deprecated'] as bool? ?? false,
      supersededBy: m['superseded_by'] as int?,
    );
  }

  static List<ArgDef> _argList(dynamic v) {
    if (v == null) return const [];
    if (v is! YamlList) {
      throw FormatException('args must be a list, got ${v.runtimeType}');
    }
    return v.map((e) => ArgDef.fromYaml(e as YamlMap)).toList();
  }
}

class ArgDef {
  ArgDef({required this.name, required this.type});
  final String name;
  final String type;

  factory ArgDef.fromYaml(YamlMap m) =>
      ArgDef(name: m['name'] as String, type: m['type'] as String);
}
