import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/outbox/message_send_scheduler.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_message.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/persistent_outbox_manager.dart';

void main() {
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
