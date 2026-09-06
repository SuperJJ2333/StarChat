import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_disk_store.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_session_cache.dart';

void main() {
  test('encrypted disk roundtrip and disk-only clear use original keys',
      () async {
    final root = await Directory.systemTemp.createTemp('poster-test-');
    final store = VideoPosterDiskStore(directory: () async => root);
    final cache = VideoPosterSessionCache(
        memoryMaxEntries: 1,
        diskRead: store.read,
        diskWrite: store.write,
        diskDelete: store.delete,
        diskListKeys: store.keys);
    final plain = Uint8List.fromList(List.generate(512, (i) => i % 255));
    const first = '@me:x|!room:x|first|v1|contain';
    const second = '@me:x|!room:x|second|v1|contain';
    await cache.load(first, () async => plain);
    await cache.load(second, () async => plain);
    expect(await store.keys(), unorderedEquals([first, second]));
    final files = await root.list().where((e) => e is File).toList();
    expect(files, hasLength(2));
    expect(await (files.first as File).readAsBytes(), isNot(plain));
    expect(
        (await cache.load(first, () async => throw StateError('reload'))).bytes,
        plain);
    await cache.clearAll();
    expect(await root.list().toList(), isEmpty);
    await store.dispose();
    expect(await root.exists(), isFalse);
  });
}
