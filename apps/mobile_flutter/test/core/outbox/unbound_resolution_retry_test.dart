import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/outbox/message_send_scheduler.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_message.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/persistent_outbox_manager.dart';

final class _ImmediateLease implements OutboxLease {
  final txids = <String>[];
  @override
  Future<String> send(String text, String transactionId) async {
    txids.add(transactionId);
    return 'event-$transactionId';
  }

  @override
  Future<void> release() async {}
}

void main() {
  testWidgets('pending resolution does not spend bound transport capacity',
      (tester) async {
    final outbox =
        PersistentOutboxManager(InMemoryOutboxStore(), accountId: 'me');
    final pending = Completer<String?>();
    var resolutions = 0;
    for (var i = 0; i < 4; i++) {
      await outbox.save(receiverId: 'unbound$i', content: 'pending');
    }
    final row = (await outbox.save(
        receiverId: 'bound', roomId: 'room', content: 'ready'))!;
    final lease = _ImmediateLease();
    final scheduler = MessageSendScheduler(
        outbox: outbox,
        senderFor: (_) => null,
        leaseFactory: (_) async => lease,
        resolveUnbound: (_) {
          resolutions++;
          return pending.future;
        });
    addTearDown(scheduler.dispose);
    addTearDown(outbox.dispose);
    unawaited(scheduler.drain());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(lease.txids, [row.txid]);
    expect(resolutions, 2, reason: 'resolution has its own bounded capacity');
    await tester.pump(const Duration(seconds: 31));
    await scheduler.drain();
    expect(resolutions, 2,
        reason: 'timed out observers cannot duplicate resolvers');
    scheduler.dispose();
    pending.complete('late-room');
    await tester.pump();
    expect((await outbox.unsent()).every((row) => !row.hasRoom), isTrue);
  });

  testWidgets('online pending resolution retries without a network edge',
      (tester) async {
    final outbox =
        PersistentOutboxManager(InMemoryOutboxStore(), accountId: 'me');
    final first = await outbox.save(receiverId: 'peer', content: 'first');
    final second = await outbox.save(receiverId: 'peer', content: 'second');
    var calls = 0;
    final scheduler = MessageSendScheduler(
      outbox: outbox,
      senderFor: (_) => null,
      resolveUnbound: (_) async => ++calls == 1 ? null : '!ready:test',
    );
    addTearDown(scheduler.dispose);
    addTearDown(outbox.dispose);
    await scheduler.drain();
    expect(calls, 1);
    await scheduler.drain();
    expect(calls, 1, reason: 'explicit drains must not bypass backoff');
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 2);
    expect((await outbox.byLocalId(first!.localId))!.roomId, '!ready:test');
    expect((await outbox.byLocalId(second!.localId))!.txid, second.txid);
  });

  testWidgets('pending resolution stops with a retryable failed durable row',
      (tester) async {
    final outbox =
        PersistentOutboxManager(InMemoryOutboxStore(), accountId: 'me');
    final row = await outbox.save(receiverId: 'peer', content: 'keep');
    var calls = 0;
    final scheduler = MessageSendScheduler(
      outbox: outbox,
      senderFor: (_) => null,
      resolveUnbound: (_) async {
        calls++;
        return null;
      },
    );
    addTearDown(scheduler.dispose);
    addTearDown(outbox.dispose);
    await scheduler.drain();
    for (final seconds in [2, 5, 15]) {
      await tester.pump(Duration(seconds: seconds));
    }
    expect(calls, 4);
    final stored = (await outbox.byLocalId(row!.localId))!;
    expect(stored.status, OutboxStatus.failed);
    expect(stored.roomId, isNull);
    expect(stored.txid, row.txid);
    await tester.pump(const Duration(minutes: 1));
    expect(calls, 4);
    await outbox.updateStatus(row.localId, OutboxStatus.queued);
    await scheduler.drain();
    expect(calls, 5, reason: 'manual retry begins a new bounded attempt');
    scheduler.dispose();
    await tester.pump(const Duration(minutes: 1));
    expect(calls, 5, reason: 'disposed account never retries');
  });
}
