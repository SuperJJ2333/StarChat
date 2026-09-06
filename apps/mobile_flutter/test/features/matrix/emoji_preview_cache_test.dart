import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/emoji_preview_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('byte budget evicts old previews while disk avoids reloading originals',
      () async {
    var loads = 0;
    var diskReads = 0;
    final disk = <String, Uint8List>{};
    final cache = EmojiPreviewCache(
        maxBytes: 2,
        read: (key) async {
          diskReads++;
          return disk[key];
        },
        write: (key, bytes) async {
          disk[key] = bytes;
        },
        transform: (bytes) async => bytes);
    Future<Uint8List> original() async {
      loads++;
      return Uint8List(2);
    }

    await cache.load('a', original);
    await cache.load('b', original);
    await cache.load('a', original);
    expect(loads, 2);
    expect(diskReads, 3);
  });
  test(
      'GIF preview is PNG first frame and oversized canvas never reaches codec',
      () async {
    final gif = Uint8List.fromList([
      71,
      73,
      70,
      56,
      57,
      97,
      1,
      0,
      1,
      0,
      128,
      0,
      0,
      0,
      0,
      0,
      255,
      255,
      255,
      33,
      249,
      4,
      1,
      0,
      0,
      0,
      0,
      44,
      0,
      0,
      0,
      0,
      1,
      0,
      1,
      0,
      0,
      2,
      2,
      68,
      1,
      0,
      59
    ]);
    final png = await createEmojiPreview(gif);
    expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final oversized =
        Uint8List.fromList([71, 73, 70, 56, 57, 97, 255, 255, 255, 255]);
    await expectLater(createEmojiPreview(oversized), throwsFormatException);
  });
  test('encrypted previews persist without exposing bytes and isolate accounts',
      () async {
    final root = Directory(
        '${Directory.current.path}/../../docs/verification/artifacts/2026-09-06/cache-entry/favorites/encryption-test');
    await root.create(recursive: true);
    final keys = _Keys();
    final a = EncryptedEmojiPreviewStore('account-a',
        keys: keys, directory: () async => root);
    final b = EncryptedEmojiPreviewStore('account-b',
        keys: keys, directory: () async => root);
    final bytes = Uint8List.fromList(List.generate(64, (i) => i));
    await a.write('same-item', bytes);
    final files = await root
        .list(recursive: true)
        .where((e) => e is File && e.path.endsWith('.bin'))
        .cast<File>()
        .toList();
    expect(await files.single.readAsBytes(), isNot(equals(bytes)));
    expect(await b.read('same-item'), isNull);
    final reopened = EncryptedEmojiPreviewStore('account-a',
        keys: keys, directory: () async => root);
    expect(await reopened.read('same-item'), bytes);
    await files.single.writeAsBytes([1, 2, 3]);
    expect(await reopened.read('same-item'), isNull);
    await a.delete('same-item');
  });
  test('preview contains at most 160px and one static frame', () async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xffabcdef), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(800, 400);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    final preview = await createEmojiPreview(bytes!.buffer.asUint8List());
    final codec = await ui.instantiateImageCodec(preview);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 160);
    expect(frame.image.height, 80);
    expect(codec.frameCount, 1);
    frame.image.dispose();
    codec.dispose();
  });
  test('preview requests deduplicate and reuse disk without original',
      () async {
    final disk = <String, Uint8List>{};
    var loads = 0;
    final cache = EmojiPreviewCache(
        read: (k) async => disk[k],
        write: (k, b) async {
          disk[k] = b;
        },
        delete: (k) async {
          disk.remove(k);
        },
        transform: (b) async => Uint8List.fromList([7]));
    Future<Uint8List> original() async {
      loads++;
      return Uint8List(1000);
    }

    await Future.wait(List.generate(5, (_) => cache.load('a', original)));
    expect(loads, 1);
    cache.clearMemory();
    expect(await cache.load('a', original), [7]);
    expect(loads, 1);
    await cache.remove('a');
    expect(disk, isEmpty);
  });
  test('different large originals are processed serially', () async {
    var active = 0;
    var maxActive = 0;
    final cache = EmojiPreviewCache(transform: (b) async {
      active++;
      if (active > maxActive) maxActive = active;
      await Future<void>.delayed(Duration(milliseconds: 5));
      active--;
      return b;
    });
    await Future.wait(
        List.generate(6, (i) => cache.load('$i', () async => Uint8List(1))));
    expect(maxActive, 1);
  });
  test('remove while loading prevents cache resurrection', () async {
    final gate = Completer<Uint8List>();
    final disk = <String, Uint8List>{};
    final cache = EmojiPreviewCache(
        write: (k, b) async {
          disk[k] = b;
        },
        delete: (k) async {
          disk.remove(k);
        },
        transform: (b) async => b);
    final load = cache.load('a', () => gate.future);
    await Future<void>.delayed(Duration.zero);
    await cache.remove('a');
    gate.complete(Uint8List(1));
    await load;
    expect(disk, isEmpty);
  });
}

final class _Keys implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
