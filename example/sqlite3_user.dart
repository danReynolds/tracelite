// A minimal Dart program that uses `package:sqlite3`.
//
// The repo's pubspec selects the tracelite shim through sqlite3's native
// hook configuration (`source: system`, `name: sqlite_traced`). The test
// harness sets TRACELITE_REGION and DYLD_LIBRARY_PATH before spawning this
// script, so the workload itself has no tracelite-specific code.

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

void main() {
  final db = sqlite3.open(':memory:');

  db.execute('CREATE TABLE t(id INTEGER, name TEXT)');
  db.execute('INSERT INTO t VALUES (?, ?)', [1, 'alice']);
  db.execute('INSERT INTO t VALUES (?, ?)', [2, 'bob']);
  db.execute('INSERT INTO t VALUES (?, ?)', [3, 'carol']);
  db.select("SELECT 'literal_secret' AS hidden");

  final rs = db.select('SELECT id, name FROM t WHERE id > ?', [1]);
  for (final row in rs) {
    stdout.writeln('  ${row['id']}: ${row['name']}');
  }

  db.close();
}
