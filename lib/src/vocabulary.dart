import 'producer.dart';

enum TraceDefinitionKind { span, counter, gauge }

final class TraceDefinition {
  const TraceDefinition({
    required this.id,
    required this.name,
    required this.category,
    required this.kind,
  });

  final int id;
  final String name;
  final String category;
  final TraceDefinitionKind kind;
}

final class TraceVocabulary {
  const TraceVocabulary({
    required this.name,
    required this.definitions,
  });

  final String name;
  final List<TraceDefinition> definitions;

  Map<int, String> get spanNames => {
        for (final definition in definitions) definition.id: definition.name,
      };

  void register(TraceRecorder recorder) {
    if (!recorder.isActive) return;
    for (final definition in definitions) {
      recorder.registerSpan(
        definition.id,
        definition.name,
        category: definition.category,
      );
    }
  }
}

extension TraceVocabularyRecorder on TraceRecorder {
  void registerVocabulary(TraceVocabulary vocabulary) {
    vocabulary.register(this);
  }
}
