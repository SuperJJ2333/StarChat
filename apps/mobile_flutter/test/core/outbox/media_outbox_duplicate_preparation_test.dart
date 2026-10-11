import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_recovery_service.dart';

void main() {
  for (final replacement in [false, true]) {
    test(
        'duplicate same transaction joins ${replacement ? "replacement" : "same"} handle preparation',
        () async {
      sqfliteFfiInit();
      final root = await Directory.systemTemp.createTemp('duplicate-');
      final store = SqliteMediaOutboxStore(
          owner: const MediaOutboxOwner(
              accountId: '@duplicate:t',
              homeserver: 'https://t',
              generation: 'db'),
          directory: () async => root,
          availableBytes: () async => 1 << 30,
          seal: (_, __) async {});
      var sends = 0;
      final service = MediaOutboxRecoveryService(
          store: store,
          isCurrentOwner: () => true,
          authorize: (_) async => true,
          send: (_, __) async {
            sends++;
            return r'$one';
          });
      final otherStore = replacement
          ? SqliteMediaOutboxStore(
              owner: store.owner,
              directory: () async => root,
              availableBytes: () async => 1 << 30,
              seal: (_, __) async {})
          : store;
      final other = replacement
          ? MediaOutboxRecoveryService(
              store: otherStore,
              isCurrentOwner: () => true,
              authorize: (_) async => true,
              send: (_, __) async {
                sends++;
                return r'$one';
              })
          : service;
      var resolves = 0;
      final entered = Completer<void>();
      final resolver = Completer<File>();
      final releaseHold = service.holdForeground('same');
      final original =
          await File('${root.path}/picked').writeAsBytes([1, 2, 3]);
      Future<MediaOutboxTask> prepare(MediaOutboxRecoveryService target) =>
          target.persistResolvedFile(
              txid: 'same',
              roomId: '!a:t',
              mimeType: 'video/mp4',
              filename: 'v.mp4',
              resolve: () {
                resolves++;
                if (!entered.isCompleted) entered.complete();
                return resolver.future;
              });
      final first = prepare(service)
          .then((task) => service.dispatch(task, userRetry: true))
          .then<Object>((event) => event, onError: (Object error) => error);
      await entered.future;
      final duplicate = prepare(other)
          .then((task) => other.dispatch(task, userRetry: true))
          .then<Object>((event) => event, onError: (Object error) => error);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final sentBeforeResolve = sends;
      resolver.complete(original);
      final firstResult = await first;
      final result = await duplicate;
      final finalTask = (await store.byTxid('same'))!;
      releaseHold();
      service.dispose();
      await service.close();
      if (replacement) {
        other.dispose();
        await other.close();
      }
      await root.delete(recursive: true);
      expect(finalTask.stage, MediaOutboxStage.sent,
          reason:
              'a duplicate caller must join preparation or preserve it; first=$firstResult; duplicate=$result');
      expect(sentBeforeResolve, 0);
      expect(firstResult, r'$one');
      expect(result, r'$one');
      expect(sends, 1);
      expect(resolves, 1);
    });
  }

  test(
      'conflicting immutable parameters cannot join or poison a live preparation',
      () async {
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('media-conflict-');
    const owner = MediaOutboxOwner(
        accountId: '@conflict:t', homeserver: 'https://t', generation: 'db');
    SqliteMediaOutboxStore open() => SqliteMediaOutboxStore(
        owner: owner,
        directory: () async => root,
        availableBytes: () async => 1 << 30,
        seal: (_, __) async {});
    final store = open(), other = open();
    final entered = Completer<void>(), resolver = Completer<File>();
    final original = await File('${root.path}/picked').writeAsBytes([1, 2, 3]);
    final first = store.persistResolvedFile(
        txid: 'same',
        roomId: '!a:t',
        mimeType: 'video/mp4',
        filename: 'v.mp4',
        resolve: () {
          entered.complete();
          return resolver.future;
        });
    await entered.future;
    var duplicateLoads = 0;
    try {
      for (var i = 0; i < 8; i++) {
        await expectLater(
            other
                .persistPreparedBytes(
                    txid: 'same',
                    roomId: i == 0 ? '!other:t' : '!a:t',
                    mimeType: i == 1 ? 'image/png' : 'video/mp4',
                    filename: i == 2 ? 'other.mp4' : 'v.mp4',
                    durationMs: i == 3 ? 1 : null,
                    prepared: i == 4,
                    asFile: i == 5,
                    width: i == 6 ? 1 : null,
                    height: i == 7 ? 1 : null,
                    load: () async {
                      duplicateLoads++;
                      throw StateError('must not resolve conflicting input');
                    })
                .timeout(const Duration(seconds: 2)),
            throwsA(isA<MediaOutboxException>()
                .having((e) => e.reason, 'reason', 'transaction-conflict')));
        expect((await store.byTxid('same'))!.stage, MediaOutboxStage.preparing);
      }
    } finally {
      resolver.complete(original);
      final task = await first;
      expect(task.stage, MediaOutboxStage.queued);
      expect(task.length, 3);
      await store.close();
      await other.close();
      await root.delete(recursive: true);
    }
    expect(duplicateLoads, 0);
  });

  test('replacement cancel and close keep joined preparation until real settle',
      () async {
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('media-joined-close-');
    const owner = MediaOutboxOwner(
        accountId: '@close:t', homeserver: 'https://t', generation: 'db');
    SqliteMediaOutboxStore open() => SqliteMediaOutboxStore(
        owner: owner,
        directory: () async => root,
        availableBytes: () async => 1 << 30,
        seal: (_, __) async {});
    final store = open(), other = open();
    final entered = Completer<void>(), resolver = Completer<File>();
    final original = await File('${root.path}/picked').writeAsBytes([1, 2, 3]);
    Future<Object> capture(Future<MediaOutboxTask> operation) => operation
        .then<Object>((task) => task, onError: (Object error) => error);
    final first = capture(store.persistResolvedFile(
        txid: 'same',
        roomId: '!a:t',
        mimeType: 'video/mp4',
        filename: 'v.mp4',
        resolve: () {
          entered.complete();
          return resolver.future;
        }));
    await entered.future;
    var duplicateFinished = false;
    final second = capture(other.persistResolvedFile(
            txid: 'same',
            roomId: '!a:t',
            mimeType: 'video/mp4',
            filename: 'v.mp4',
            resolve: () => throw StateError('duplicate resolver invoked')))
        .whenComplete(() => duplicateFinished = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final beforeCancel = duplicateFinished;
    await other.setStage('same', MediaOutboxStage.canceled);
    await other.releaseTerminalSource('same');
    var closed = false;
    final closing = other.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final closedBeforeSettle = closed;
    resolver.complete(original);
    final outcomes = await Future.wait([first, second]);
    await closing;
    final finalTask = (await store.byTxid('same'))!;
    await store.close();
    await root.delete(recursive: true);
    expect(beforeCancel, isFalse);
    expect(closedBeforeSettle, isFalse);
    expect(
        outcomes,
        everyElement(isA<MediaOutboxException>()
            .having((e) => e.reason, 'reason', 'canceled')));
    expect(finalTask.stage, MediaOutboxStage.canceled);
    expect(finalTask.length, 0);
  });
}
