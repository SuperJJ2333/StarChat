import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/persistent_outbox_manager.dart';

void main() {
  test(
      'new text is durable before authority and binds its original identity once',
      () async {
    final manager =
        PersistentOutboxManager(InMemoryOutboxStore(), accountId: '@me:test');
    var canonical = '!canonical:test';
    final journal = RoomOutboxJournal(
        manager: manager,
        roomId: null,
        receiverId: '@peer:test',
        beforeClaim: (id) async {
          await manager
              .bindRoomForReceiver('@peer:test', canonical, localIds: [id]);
          return canonical == '!visible:test';
        });
    final row = (await journal.persist(txid: 'stable', content: 'hello'))!;
    expect(row.roomId, isNull);
    expect(await journal.claim(row.localId), isFalse);
    final bound = (await journal.findByTxid('stable'))!;
    expect(bound.roomId, '!canonical:test');
    expect(bound.localId, row.localId);
    canonical = '!visible:test';
    await journal.claim(row.localId);
    expect((await journal.findByTxid('stable'))!.roomId, '!canonical:test',
        reason: 'binding never moves an existing target');
    manager.dispose();
  });
}
