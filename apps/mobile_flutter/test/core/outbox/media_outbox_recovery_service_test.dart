import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_recovery_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Throttle implements Exception {
  final int statusCode = 429;
  final int retryAfterMs = 3600000;
}

void main() {
  late Directory root;
  late SqliteMediaOutboxStore store;
  late MediaOutboxTask task;
  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('media-recovery-test-');
    store = SqliteMediaOutboxStore(
        owner: const MediaOutboxOwner(
            accountId: '@a:test',
            homeserver: 'https://test',
            generation: 'db-a'),
        directory: () async => root,
        seal: (_, __) async {},
        availableBytes: () async => 1 << 30);
    task = await store.persistFile(
        txid: 'fixed',
        roomId: '!r:test',
        source: await File('${root.path}/picked').writeAsBytes([1, 2, 3]),
        mimeType: 'application/octet-stream',
        filename: 'f');
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test(
      'a hanging room does not prevent later timer retry or a fresh recovery scan',
      () async {
    Future<MediaOutboxTask> add(String id) => store.persistFile(
        txid: id,
        roomId: '!$id:test',
        source: File('${root.path}/picked'),
        mimeType: 'application/octet-stream',
        filename: 'f');
    await add('b');
    final aAck = Completer<String>();
    final bFirst = Completer<void>();
    final bRetried = Completer<void>();
    final cStarted = Completer<void>();
    var bCalls = 0;
    final service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => true,
        authorize: (_) async => true,
        send: (task, _) async {
          if (task.txid == 'fixed') return aAck.future;
          if (task.txid == 'b') {
            if (++bCalls == 1) {
              bFirst.complete();
              throw const SocketException('synthetic offline');
            }
            bRetried.complete();
          } else if (task.txid == 'c') {
            cStarted.complete();
          }
          return r'$other';
        });
    final firstScan = service.recover();
    await bFirst.future.timeout(const Duration(seconds: 2));
    await add('c');
    final nextScan = service.recover();
    var sawC = false;
    var sawRetry = false;
    try {
      await cStarted.future.timeout(const Duration(milliseconds: 700));
      sawC = true;
    } on TimeoutException {/* Expected RED; settle A before asserting. */}
    try {
      await bRetried.future.timeout(const Duration(seconds: 3));
      sawRetry = true;
    } on TimeoutException {/* Expected RED; settle A before asserting. */}
    aAck.complete(r'$a');
    await firstScan;
    await nextScan;
    service.dispose();
    await service.close();
    expect(sawC, isTrue, reason: 'fresh C must start while A is pending');
    expect(sawRetry, isTrue,
        reason: 'B retry timer must start another scan while A is pending');
  });

  test('20 competing dispatches hold one real transport and fixed txid',
      () async {
    var calls = 0;
    final pending = Completer<String>();
    final service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => true,
        authorize: (_) async => true,
        send: (task, source) {
          calls++;
          expect(task.txid, 'fixed');
          return pending.future;
        });
    final results = List.generate(20, (_) => service.dispatch(task));
    while (calls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(calls, 1);
    pending.complete(r'$event');
    expect(await Future.wait(results), everyElement(r'$event'));
    expect((await store.byTxid('fixed'))!.stage, MediaOutboxStage.sent);
  });

  test('two room slots preserve room order without a slow room blocking others',
      () async {
    Future<MediaOutboxTask> add(String id, String room) => store.persistFile(
        txid: id,
        roomId: room,
        source: File('${root.path}/picked'),
        mimeType: 'application/octet-stream',
        filename: 'f');
    await add('a2', task.roomId);
    final b = await add('b', '!b:test');
    await add('c', '!c:test');
    final aAck = Completer<String>();
    final bAck = Completer<String>();
    final starts = <String>[];
    final pairEntered = Completer<void>();
    final cEntered = Completer<void>();
    final service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => true,
        authorize: (_) async => true,
        send: (task, _) {
          starts.add(task.txid);
          if (starts.contains('fixed') &&
              starts.contains('b') &&
              !pairEntered.isCompleted) {
            pairEntered.complete();
          }
          if (task.txid == 'c') cEntered.complete();
          if (task.txid == 'fixed') return aAck.future;
          if (task.txid == 'b') return bAck.future;
          return Future.value('\$${'next'}');
        });
    final recovering = service.recover(waitForSettlement: true);
    await pairEntered.future.timeout(const Duration(seconds: 5));
    // Always settle the pending futures even on the expected RED assertion.
    final beforeSettle = List<String>.of(starts);
    final sameFlight = service.dispatch(b);
    bAck.complete(r'$b');
    List<String> beforeA;
    try {
      // ACK completion alone is not real settlement: durable ACK/cleanup must
      // finish before the room slot may pass to C.
      await sameFlight;
      await cEntered.future.timeout(const Duration(seconds: 5));
      beforeA = List<String>.of(starts);
    } finally {
      aAck.complete(r'$a');
      await recovering;
    }
    expect(beforeSettle, unorderedEquals(['fixed', 'b']));
    expect(beforeA, unorderedEquals(['fixed', 'b', 'c']));
    expect(beforeA.last, 'c');
    expect(starts.where((id) => id == 'b'), hasLength(1));
    expect(starts.last, 'a2');
    service.dispose();
  });

  test('cancel retains pinned file until real transport settles', () async {
    final pending = Completer<String>();
    final entered = Completer<void>();
    final source = await store.verifiedSource(task);
    final service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => true,
        authorize: (_) async => true,
        send: (_, __) {
          entered.complete();
          return pending.future;
        });
    final sending = service.dispatch(task);
    final assertion =
        expectLater(sending, throwsA(isA<MediaOutboxException>()));
    await entered.future;
    await service.cancel(task.txid);
    await service.recover(); // Startup cleanup cannot unlink a live transport.
    expect(await source.exists(), isTrue);
    pending.complete(r'$late');
    await assertion;
    expect((await store.byTxid(task.txid))!.stage, MediaOutboxStage.canceled);
    expect(await source.exists(), isFalse);
  });

  test('suspended owner cannot publish ACK and original stays recoverable',
      () async {
    final pending = Completer<String>();
    final entered = Completer<void>();
    final service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => true,
        authorize: (_) async => true,
        send: (_, __) {
          entered.complete();
          return pending.future;
        });
    final sending = service.dispatch(task);
    final assertion =
        expectLater(sending, throwsA(isA<MediaOutboxException>()));
    await entered.future;
    service.suspend();
    pending.complete(r'$late');
    await assertion;
    expect(await (await store.verifiedSource(task)).exists(), isTrue);
    expect(
        (await store.byTxid(task.txid))!.stage, isNot(MediaOutboxStage.sent));
  });

  test('permission rejection never reads or sends the original', () async {
    var calls = 0;
    final service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => true,
        authorize: (_) async => false,
        send: (_, __) async {
          calls++;
          return r'$event';
        });
    await service.recover(waitForSettlement: true);
    expect(calls, 0);
    expect((await store.byTxid(task.txid))!.failure, 'permission-denied');
  });

  test(
      'manual retry cannot shorten a server deadline beyond automatic retry budget',
      () async {
    var sends = 0;
    final service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => true,
        authorize: (_) async => true,
        send: (_, __) async {
          sends++;
          throw _Throttle();
        });
    await expectLater(service.dispatch(task), throwsA(isA<_Throttle>()));
    await expectLater(
        service.dispatch(task, userRetry: true),
        throwsA(isA<MediaOutboxException>()
            .having((e) => e.reason, 'reason', 'retry-not-due')));
    expect(sends, 1);
    service.dispose();
  });

  test(
      'cancel during source copy never resurrects queued or deletes active write',
      () async {
    await store.close();
    final entered = Completer<void>();
    final release = Completer<void>();
    var held = false;
    store = SqliteMediaOutboxStore(
        owner: store.owner,
        directory: () async => root,
        availableBytes: () async => 1 << 30,
        seal: (_, __) async {},
        checkpoint: (boundary) async {
          if (boundary == 'copy' && !held) {
            held = true;
            entered.complete();
            await release.future;
          }
        });
    final service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => true,
        authorize: (_) async => true,
        send: (_, __) async => r'$event');
    final pending = service.persistFile(
        txid: 'copy-cancel',
        roomId: '!r:test',
        source: File('${root.path}/picked'),
        mimeType: 'application/octet-stream',
        filename: 'f');
    final assertion =
        expectLater(pending, throwsA(isA<MediaOutboxException>()));
    await entered.future;
    await service.cancel('copy-cancel');
    release.complete();
    await assertion;
    expect(
        (await store.byTxid('copy-cancel'))!.stage, MediaOutboxStage.canceled);
    final files = await root
        .list(recursive: true)
        .where((entry) => entry.path.endsWith('.part'))
        .toList();
    expect(files, isEmpty);
  });
}
