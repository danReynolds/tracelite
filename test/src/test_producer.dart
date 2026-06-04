import 'dart:io';

import 'package:test/test.dart';

Future<File> ensureTestProducerBuilt() async {
  final producer = File('build/test_producer');
  if (await producer.exists()) return producer;

  Directory('build').createSync(recursive: true);
  final result = await Process.run('cc', [
    '-std=c11',
    '-O2',
    '-Inative',
    'native/tracelite_runtime.c',
    'native/test_producer.c',
    '-o',
    producer.path,
  ]);

  if (result.exitCode != 0 || !await producer.exists()) {
    fail(
      'failed to build build/test_producer.\n'
      'command: cc -std=c11 -O2 -Inative native/tracelite_runtime.c '
      'native/test_producer.c -o build/test_producer\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }

  return producer;
}
