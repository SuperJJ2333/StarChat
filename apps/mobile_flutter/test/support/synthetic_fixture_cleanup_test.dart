import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'synthetic_fixture_cleanup.dart';

void main() {
  final root = Directory(
      '../../docs/verification/artifacts/2026-11-04/aws-cdn-client-compat/cleanup-unit');
  setUpAll(() async => root.create(recursive: true));
  test(
      'retries transient cleanup after all assertions without swallowing persistent failures',
      () async {
    final directory = await root.createTemp('cleanup-');
    var calls = 0;
    final cleanup = deleteSyntheticFixture(directory, remove: (d) async {
      calls++;
      if (calls == 1) {
        throw FileSystemException(
            'synthetic', d.path, const OSError('busy', 145));
      }
      await d.delete(recursive: true);
    });
    if (Platform.isWindows) {
      await cleanup;
      expect(calls, 2);
    } else {
      await expectLater(cleanup, throwsA(isA<FileSystemException>()));
      expect(calls, 1);
      await deleteSyntheticFixture(directory);
    }
    expect(await directory.exists(), isFalse);
    final persistent = await root.createTemp('persistent-');
    await expectLater(
        deleteSyntheticFixture(persistent, attempts: 2, remove: (_) async {
          throw const FileSystemException(
              'synthetic persistent', '', OSError('busy', 145));
        }),
        throwsA(isA<FileSystemException>()));
    expect(await persistent.exists(), isTrue);
    await deleteSyntheticFixture(persistent);
  });
  test(
      'missing owned child is clean but root, outside path and symlink are refused',
      () async {
    await deleteSyntheticFixture(Directory('${root.path}/missing-child'));
    await expectLater(
        deleteSyntheticFixture(Directory('../../docs/verification/artifacts')),
        throwsArgumentError);
    await expectLater(
        deleteSyntheticFixture(Directory.systemTemp), throwsArgumentError);
    final outside = await Directory.systemTemp.createTemp('synthetic-outside-');
    final child = await Directory('${outside.path}/child').create();
    final victim = await Directory('${outside.path}/outside-victim').create();
    final marker =
        await File('${victim.path}/keep.txt').writeAsString('synthetic');
    final link = Link('${root.path}/outside-link');
    try {
      await link.create(child.path);
      await expectLater(
          deleteSyntheticFixture(Directory(link.path)), throwsArgumentError);
      expect(await outside.exists(), isTrue);
      await deleteSyntheticFixture(Directory('${link.path}/../outside-victim'));
      expect(await marker.exists(), isTrue);
      await marker.delete();
      await victim.delete();
      await child.delete();
    } finally {
      if (await link.exists()) await link.delete();
      await outside.delete();
    }
  });
}
