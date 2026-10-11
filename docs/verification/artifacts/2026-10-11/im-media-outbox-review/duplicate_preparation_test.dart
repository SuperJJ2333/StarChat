import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_recovery_service.dart';

void main() {
  test('duplicate same transaction never poisons a live preparation', () async {
    sqfliteFfiInit();
    final root = await Directory(Platform.environment['STARCHAT_REVIEW_TMP']!)
        .createTemp('duplicate-');
    final store = SqliteMediaOutboxStore(
        owner: const MediaOutboxOwner(accountId: '@duplicate:t',
            homeserver: 'https://t', generation: 'db'),
        directory: () async => root, availableBytes: () async => 1 << 30,
        seal: (_, __) async {});
    var sends = 0;
    final service = MediaOutboxRecoveryService(store: store,
        isCurrentOwner: () => true, authorize: (_) async => true,
        send: (_, __) async { sends++; return r'$one'; });
    final entered = Completer<void>();
    final resolver = Completer<File>();
    final releaseHold = service.holdForeground('same');
    final original = await File('${root.path}/picked').writeAsBytes([1, 2, 3]);
    Future<MediaOutboxTask> prepare() => service.persistResolvedFile(
        txid: 'same', roomId: '!a:t', mimeType: 'video/mp4', filename: 'v.mp4',
        resolve: () {
          if (!entered.isCompleted) entered.complete();
          return resolver.future;
        });
    final first = prepare()
        .then((task) => service.dispatch(task, userRetry: true))
        .then<Object>((event) => event, onError: (Object error) => error);
    await entered.future;
    final duplicate = prepare()
        .then((task) => service.dispatch(task, userRetry: true))
        .then<Object>((event) => event, onError: (Object error) => error);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    resolver.complete(original);
    final firstResult = await first;
    final result = await duplicate;
    final finalTask = (await store.byTxid('same'))!;
    releaseHold();
    service.dispose();
    await service.close();
    await root.delete(recursive: true);
    expect(finalTask.stage, MediaOutboxStage.sent,
        reason: 'a duplicate caller must join preparation or preserve it; first=$firstResult; duplicate=$result');
    expect(sends, 1);
  });
}
