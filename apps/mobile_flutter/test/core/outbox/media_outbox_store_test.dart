import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('pending byte cap charges originals until explicit cancel releases them',
      () async {
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('media-byte-cap-');
    final db = SqliteMediaOutboxStore(
        owner: const MediaOutboxOwner(
            accountId: '@a:t', homeserver: 'https://t', generation: 'db'),
        directory: () async => root,
        availableBytes: () async => 1 << 30,
        seal: (_, __) async {},
        maxRetainedBytes: 5);
    Future<MediaOutboxTask> add(String id) => db.persistBytes(
        txid: id,
        roomId: '!r:t',
        bytes: Uint8List.fromList([1, 2, 3]),
        mimeType: 'application/octet-stream',
        filename: 'f');
    try {
      await add('one');
      await expectLater(
          add('two'),
          throwsA(isA<MediaOutboxException>()
              .having((e) => e.reason, 'reason', 'pending-capacity')));
      expect((await db.byTxid('two'))!.stage, MediaOutboxStage.failed);
      await db.setStage('one', MediaOutboxStage.canceled);
      await db.releaseTerminalSource('one');
      expect((await add('three')).stage, MediaOutboxStage.queued);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
  test(
      'a preexisting pending symlink cannot overwrite outside the owned directory',
      () async {
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('media-no-follow-');
    final outside = await File('${root.path}/untouched').writeAsBytes([9, 9]);
    const owner = MediaOutboxOwner(
        accountId: '@a:t', homeserver: 'https://t', generation: 'db');
    final db = SqliteMediaOutboxStore(
        owner: owner,
        directory: () async => root,
        availableBytes: () async => 1 << 30,
        seal: (_, __) async {},
        checkpoint: (boundary) async {
          if (boundary == 'intent') {
            final id = sha256.convert(utf8.encode('symlink'));
            await Link('${root.path}/${owner.scope}/sources/$id.bin.part')
                .create(outside.path);
          }
        });
    try {
      await expectLater(
          db.persistBytes(
              txid: 'symlink',
              roomId: '!r:t',
              bytes: Uint8List.fromList([1, 2, 3]),
              mimeType: 'application/octet-stream',
              filename: 'f'),
          throwsA(isA<MediaOutboxException>()));
      expect(await outside.readAsBytes(), [9, 9]);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
  test('prepared file semantics survive reopen without keys or event content',
      () async {
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('media-semantic-');
    const owner = MediaOutboxOwner(
        accountId: '@a:t', homeserver: 'https://t', generation: 'db');
    SqliteMediaOutboxStore open() => SqliteMediaOutboxStore(
        owner: owner,
        directory: () async => root,
        availableBytes: () async => 1 << 30,
        seal: (_, __) async {});
    var db = open();
    await db.persistBytes(
        txid: 'file',
        roomId: '!r:t',
        bytes: Uint8List.fromList([1, 2]),
        mimeType: 'image/jpeg',
        filename: 'image.jpg',
        prepared: true,
        asFile: true,
        width: 400,
        height: 300);
    await db.close();
    db = open();
    final task = (await db.byTxid('file'))!;
    expect(task.prepared, isTrue);
    expect(task.asFile, isTrue);
    expect((task.width, task.height), (400, 300));
    await db.close();
    await root.delete(recursive: true);
  });
  late Directory root;
  late File original;
  late SqliteMediaOutboxStore store;
  const owner = MediaOutboxOwner(
      accountId: '@a:test', homeserver: 'https://test', generation: 'db-a');

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('media-outbox-test-');
    original = await File('${root.path}/picked.bin')
        .writeAsBytes(List.generate(150000, (i) => i % 251));
    store = SqliteMediaOutboxStore(
        owner: owner,
        directory: () async => root,
        seal: (_, __) async {},
        availableBytes: () async => 1 << 30);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test('durable source is independent of picker and cache lifetime', () async {
    final task = await store.persistFile(
        txid: 'fixed-tx',
        roomId: '!r:test',
        source: original,
        mimeType: 'application/octet-stream',
        filename: 'a.bin');
    expect(task.stage, MediaOutboxStage.queued);
    expect(task.length, 150000);
    final source = await store.verifiedSource(task);
    expect(source.path, isNot(original.path));
    await original.delete();
    await store.close();
    final restored = await store.byTxid('fixed-tx');
    expect(restored?.digest, task.digest);
    expect(await (await store.verifiedSource(restored!)).length(), 150000);
    expect(await store.pending(), hasLength(1));
  });

  test('same txid cannot replace source or room', () async {
    await store.persistFile(
        txid: 'fixed',
        roomId: '!r:test',
        source: original,
        mimeType: 'application/octet-stream',
        filename: 'a.bin');
    await expectLater(
        store.persistFile(
            txid: 'fixed',
            roomId: '!other:test',
            source: original,
            mimeType: 'application/octet-stream',
            filename: 'a.bin'),
        throwsA(isA<MediaOutboxException>()));
    expect(await store.pending(), hasLength(1));
  });

  test('low space retains selected original and actionable intent', () async {
    await store.close();
    store = SqliteMediaOutboxStore(
        owner: owner,
        directory: () async => root,
        seal: (_, __) async {},
        availableBytes: () async => 1000);
    await expectLater(
        store.persistFile(
            txid: 'low',
            roomId: '!r:test',
            source: original,
            mimeType: 'application/octet-stream',
            filename: 'a.bin'),
        throwsA(isA<MediaOutboxException>()));
    expect(await original.exists(), isTrue);
    expect((await store.byTxid('low'))?.failure, 'low-space');
  });

  test('tamper is rejected, same account new database cannot read old task',
      () async {
    final task = await store.persistFile(
        txid: 'fixed',
        roomId: '!r:test',
        source: original,
        mimeType: 'application/octet-stream',
        filename: 'a.bin');
    final source = await store.verifiedSource(task);
    await source.writeAsBytes([0]);
    await expectLater(
        store.verifiedSource(task), throwsA(isA<MediaOutboxException>()));
    final other = SqliteMediaOutboxStore(
        owner: const MediaOutboxOwner(
            accountId: '@a:test',
            homeserver: 'https://test',
            generation: 'db-b'),
        directory: () async => root,
        seal: (_, __) async {},
        availableBytes: () async => 1 << 30);
    expect(await other.pending(), isEmpty);
    await other.close();
  });
}
