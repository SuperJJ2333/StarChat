import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';

void main() {
  test('revoked joiner waits for settlement then rejects without poisoning source',
      () async {
    sqfliteFfiInit();
    final root = await Directory(Platform.environment['STARCHAT_REVIEW_TMP']!)
        .createTemp('revoked-joiner-');
    const owner = MediaOutboxOwner(
        accountId: '@revoke:t', homeserver: 'https://t', generation: 'db');
    SqliteMediaOutboxStore open() => SqliteMediaOutboxStore(
        owner: owner,
        directory: () async => root,
        availableBytes: () async => 1 << 30,
        seal: (_, __) async {});
    final originalStore = open(), joiningStore = open();
    final entered = Completer<void>(), resolver = Completer<File>();
    final source = await File('${root.path}/picked').writeAsBytes([1, 2, 3]);
    final first = originalStore.persistResolvedFile(
        txid: 'same', roomId: '!room:t', mimeType: 'video/mp4',
        filename: 'v.mp4', isCurrentOwner: () => true,
        resolve: () { entered.complete(); return resolver.future; });
    await entered.future;
    var current = true, finished = false, closed = false;
    final second = joiningStore.persistResolvedFile(
        txid: 'same', roomId: '!room:t', mimeType: 'video/mp4',
        filename: 'v.mp4', isCurrentOwner: () => current,
        resolve: () => throw StateError('duplicate resolver must not run'))
        .then<Object>((task) => task, onError: (Object error) => error)
        .whenComplete(() => finished = true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    current = false;
    final closing = joiningStore.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final earlyFinished = finished, earlyClosed = closed;
    resolver.complete(source);
    final firstResult = await first, secondResult = await second;
    await closing;
    final stored = (await originalStore.byTxid('same'))!;
    await originalStore.close();
    await root.delete(recursive: true);
    expect(earlyFinished, isFalse);
    expect(earlyClosed, isFalse);
    expect(firstResult.stage, MediaOutboxStage.queued);
    expect(secondResult, isA<MediaOutboxException>()
        .having((e) => e.reason, 'reason', 'owner-unavailable'));
    expect(stored.stage, MediaOutboxStage.queued);
    expect(stored.length, 3);
  });
}
