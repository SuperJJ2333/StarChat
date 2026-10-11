import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_recovery_service.dart';

void main() {
  late Directory root;
  late SqliteMediaOutboxStore store;
  setUp(() async {
    sqfliteFfiInit();
    root = await Directory(Platform.environment['STARCHAT_REVIEW_TMP']!)
        .createTemp('durable-');
    store = SqliteMediaOutboxStore(
      owner: const MediaOutboxOwner(accountId: '@review:t', homeserver: 'https://t', generation: 'review'),
      directory: () async => root,
      availableBytes: () async => 1 << 30,
      seal: (_, __) async {},
    );
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  Future<MediaOutboxTask> add(String txid) => store.persistBytes(
      txid: txid, roomId: '!$txid:t', bytes: Uint8List.fromList([1,2,3]),
      mimeType: 'application/octet-stream', filename: 'review.bin');

  test('a hanging resolver does not prevent another durable intent', () async {
    final entered = Completer<void>();
    final source = Completer<File>();
    final original = await File('${root.path}/source').writeAsBytes([1,2,3]);
    final a = store.persistResolvedFile(
      txid: 'a', roomId: '!a:t', mimeType: 'video/mp4', filename: 'review.mp4',
      resolve: () { entered.complete(); return source.future; },
    );
    await entered.future;
    final b = add('b');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final bBeforeASettled = await store.byTxid('b');
    source.complete(original);
    await a;
    await b;
    expect(bBeforeASettled, isNotNull,
        reason: 'B must at least commit intent while A resolver is pending');
  });

  test('earlier automatic retry replaces an existing later timer', () async {
    final a = await add('a');
    await store.setStage(a.txid, MediaOutboxStage.ackUnknown,
        nextRetryAt: DateTime.now().add(const Duration(seconds: 5)));
    await add('b');
    var bCalls = 0;
    final service = MediaOutboxRecoveryService(
      store: store, isCurrentOwner: () => true, authorize: (_) async => true,
      send: (task, _) async {
        if (task.txid == 'b' && ++bCalls == 1) {
          throw const SocketException('synthetic');
        }
        return r'$accepted';
      },
    );
    await service.recover();
    await Future<void>.delayed(const Duration(milliseconds: 3000));
    final observedCalls = bCalls;
    service.dispose();
    await service.close();
    expect(observedCalls, 2,
        reason: 'B two-second retry must not wait for A five-second deadline');
  });

  test('replacement owner cancellation retains an active source copy', () async {
    await store.close();
    final entered = Completer<void>();
    final released = Completer<void>();
    var current = true;
    store = SqliteMediaOutboxStore(
      owner: store.owner, directory: () async => root,
      availableBytes: () async => 1 << 30, seal: (_, __) async {},
      checkpoint: (boundary) async {
        if (boundary == 'copy' && !entered.isCompleted) {
          entered.complete();
          await released.future;
        }
      },
    );
    final old = MediaOutboxRecoveryService(
      store: store, isCurrentOwner: () => current,
      authorize: (_) async => true, send: (_, __) async => r'$accepted',
    );
    final releaseHold = old.holdForeground('copy');
    final copying = old.persistBytes(txid: 'copy', roomId: '!a:t',
        bytes: Uint8List.fromList([1,2,3]), mimeType: 'application/octet-stream',
        filename: 'review.bin');
    final result = expectLater(copying, throwsA(isA<MediaOutboxException>()));
    await entered.future;
    final part = (await root.list(recursive: true).toList())
        .whereType<File>().singleWhere((f) => f.path.endsWith('.part'));
    current = false;
    old.suspend();
    final replacementStore = SqliteMediaOutboxStore(
      owner: store.owner, directory: () async => root,
      availableBytes: () async => 1 << 30, seal: (_, __) async {},
    );
    final replacement = MediaOutboxRecoveryService(
      store: replacementStore, isCurrentOwner: () => true,
      authorize: (_) async => true, send: (_, __) async => r'$accepted',
    );
    Object? cancellationError;
    try {
      await replacement.cancel('copy');
    } catch (error) {
      cancellationError = error;
    }
    final retainedBeforeSettle = await part.exists();
    released.complete();
    await result;
    releaseHold();
    old.dispose();
    replacement.dispose();
    await replacement.close();
    expect(cancellationError, isNull,
        reason: 'cancellation must defer cleanup instead of deleting an active copy');
    expect(retainedBeforeSettle, isTrue,
        reason: 'a replacement service must respect the real old copy lifetime');
  });

  test('replacement recovery retries a suspended same-owner flight after settle', () async {
    final task = await add('late');
    final entered = Completer<void>();
    final ack = Completer<String>();
    final old = MediaOutboxRecoveryService(store: store,
      isCurrentOwner: () => true, authorize: (_) async => true,
      send: (_, __) { entered.complete(); return ack.future; });
    final sending = old.dispatch(task);
    final rejected = expectLater(sending, throwsA(isA<MediaOutboxException>()));
    await entered.future;
    old.suspend();
    final replacementStore = SqliteMediaOutboxStore(
      owner: store.owner, directory: () async => root,
      availableBytes: () async => 1 << 30, seal: (_, __) async {});
    var newSends = 0;
    final replacement = MediaOutboxRecoveryService(store: replacementStore,
      isCurrentOwner: () => true, authorize: (_) async => true,
      send: (_, __) async { newSends++; return r'$same-txid'; });
    await replacement.recover();
    ack.complete(r'$late-old-ack');
    await rejected;
    await replacement.recover(waitForSettlement: true);
    final outcome = (await replacementStore.byTxid(task.txid))!;
    old.dispose();
    replacement.dispose();
    await replacement.close();
    expect(newSends, 1, reason: 'settled orphan must become ACK-unknown, not permanent not-admitted');
    expect(outcome.stage, MediaOutboxStage.sent);
  });
}
