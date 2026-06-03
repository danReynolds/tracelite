import 'dart:io';
import 'dart:typed_data';

import 'package:drift/backends.dart' as drift_backend;
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart' as drift_native;

import 'peer_contract.dart';

final class DriftPeer implements SqlitePeer, ReactiveSqlitePeer {
  _TraceliteDriftDatabase? _db;

  @override
  String get name => 'drift';

  @override
  Future<void> open(String path) async {
    _db = _TraceliteDriftDatabase(drift_native.NativeDatabase(File(path)));
    await _db!.executor.ensureOpen(_db!);
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  @override
  Future<void> execute(String sql,
      [List<Object?> parameters = const []]) async {
    await _db!.customStatement(sql, parameters);
    _db!.notifyWritesFor(sql);
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    final rows = await _db!
        .customSelect(sql, variables: _driftVariables(parameters))
        .get();
    return [
      for (final row in rows) Map<String, Object?>.from(row.data),
    ];
  }

  @override
  Future<void> executeBatch(
    String sql,
    List<List<Object?>> parameterSets,
  ) async {
    await _db!.customStatement('BEGIN');
    try {
      await _db!.executor.runBatched(
        drift_backend.BatchedStatements(
          [sql],
          [
            for (final parameters in parameterSets)
              drift_backend.ArgumentsForBatchedStatement(0, parameters),
          ],
        ),
      );
      await _db!.customStatement('COMMIT');
      _db!.notifyWritesFor(sql);
    } catch (_) {
      await _db!.customStatement('ROLLBACK');
      rethrow;
    }
  }

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, {
    List<Object?> parameters = const [],
    Set<String> readsFrom = const {},
  }) {
    final tables = _db!.tablesFor(readsFrom);
    return _db!
        .customSelect(
          sql,
          variables: _driftVariables(parameters),
          readsFrom: tables,
        )
        .watch()
        .map((rows) => [
              for (final row in rows) Map<String, Object?>.from(row.data),
            ]);
  }
}

final class _TraceliteDriftDatabase extends drift.GeneratedDatabase {
  _TraceliteDriftDatabase(super.executor);

  late final _tablesByName = {
    for (final name in const [
      'tracelite_keyed_items',
      'tracelite_fanout_items',
      'tracelite_wide_items',
    ])
      name: _TraceliteDriftTable(name, this),
  };

  @override
  int get schemaVersion => 1;

  @override
  drift.MigrationStrategy get migration => drift.MigrationStrategy(
        onCreate: (_) async {},
      );

  @override
  Iterable<drift.TableInfo> get allTables => _tablesByName.values;

  Set<drift.ResultSetImplementation> tablesFor(Set<String> tableNames) {
    if (tableNames.isEmpty) {
      throw const UnsupportedPeerScenario(
        'drift reactive watches require readsFrom table names',
      );
    }
    final tables = <drift.ResultSetImplementation>{};
    for (final name in tableNames) {
      final table = _tablesByName[name];
      if (table == null) {
        throw UnsupportedPeerScenario(
          'drift reactive watch has no table registry entry for $name',
        );
      }
      tables.add(table);
    }
    return tables;
  }

  void notifyWritesFor(String sql) {
    final table = _writeTableFrom(sql);
    if (table == null) return;
    final driftTable = _tablesByName[table];
    if (driftTable != null) {
      markTablesUpdated([driftTable]);
    }
  }
}

final class _TraceliteDriftTable extends drift.Table
    with drift.TableInfo<_TraceliteDriftTable, Map<String, Object?>> {
  _TraceliteDriftTable(
    this.actualTableName,
    this.attachedDatabase, [
    this._alias,
  ]);

  @override
  final String actualTableName;

  @override
  final drift.DatabaseConnectionUser attachedDatabase;

  final String? _alias;

  @override
  List<drift.GeneratedColumn> get $columns => const [];

  @override
  String get aliasedName => _alias ?? actualTableName;

  @override
  Map<String, Object?> map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    return Map<String, Object?>.from(data);
  }

  @override
  _TraceliteDriftTable createAlias(String alias) {
    return _TraceliteDriftTable(actualTableName, attachedDatabase, alias);
  }
}

List<drift.Variable> _driftVariables(List<Object?> values) {
  return [for (final value in values) _driftVariable(value)];
}

drift.Variable _driftVariable(Object? value) {
  return switch (value) {
    null => const drift.Variable<Object>(null),
    bool value => drift.Variable.withBool(value),
    int value => drift.Variable.withInt(value),
    BigInt value => drift.Variable.withBigInt(value),
    String value => drift.Variable.withString(value),
    DateTime value => drift.Variable.withDateTime(value),
    Uint8List value => drift.Variable.withBlob(value),
    double value => drift.Variable.withReal(value),
    _ => drift.Variable<Object>(value),
  };
}

String? _writeTableFrom(String sql) {
  final match = RegExp(
    r'^\s*(?:'
    r'insert\s+(?:or\s+\w+\s+)?into|'
    r'replace\s+into|'
    r'update|'
    r'delete\s+from'
    r')\s+["`\[]?([A-Za-z_][A-Za-z0-9_]*)',
    caseSensitive: false,
  ).firstMatch(sql);
  return match?.group(1);
}
