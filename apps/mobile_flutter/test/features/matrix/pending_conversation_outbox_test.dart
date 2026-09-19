import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_message.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/persistent_outbox_manager.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';
import 'package:liuhetong_mobile/core/network_state_manager.dart';
import 'package:liuhetong_mobile/features/matrix/pending_conversation_page.dart';

/// Offline First 收口：pending conversation 里输入的消息**不依赖页面生命周期**。
///
/// 覆盖用户验收场景 1 的核心缺陷：进程被杀/页面被销毁后，typed message 仍在
/// 持久化 outbox 里，重开页面（甚至"重开 App"——用同一存储上的新 manager
/// 模拟）依然可见、依然会发。
void main() {
  const peer = ContactDetails(
    userId: 'peer-1',
    username: 'peer',
    matrixUserId: '@peer:test',
    nickname: 'Peer 昵称',
  );

  DirectChatRoom safeRoom(String roomId) => DirectChatRoom(
        roomId: roomId,
        encrypted: true,
        joinedMemberCount: 2,
        participantIds: <String>{'@me:test', '@peer:test'},
      );

  Future<void> pumpPage(
    WidgetTester tester, {
    required PersistentOutboxManager outbox,
    required Future<DirectChatRoom> Function() openRoom,
    void Function(PendingConversationResult?)? onResult,
    ValueNotifier<NetworkState>? networkState,
  }) async {
    await tester.pumpWidget(CupertinoApp(
      home: Builder(
        builder: (context) => CupertinoButton(
          child: const Text('enter'),
          onPressed: () async {
            final result =
                await Navigator.of(context).push<PendingConversationResult>(
              CupertinoPageRoute(
                builder: (_) => PendingConversationPage(
                  contact: peer,
                  openRoom: openRoom,
                  outbox: outbox,
                  networkState: networkState,
                ),
              ),
            );
            onResult?.call(result);
          },
        ),
      ),
    ));
    await tester.tap(find.text('enter'));
    await tester.pumpAndSettle();
  }

  testWidgets('输入即落盘：页面销毁后消息仍在（同一存储的新 manager 也能读到）',
      (tester) async {
    final store = InMemoryOutboxStore();
    final outbox = PersistentOutboxManager(store, accountId: 'me');
    final never = Completer<DirectChatRoom>();

    await pumpPage(tester, outbox: outbox, openRoom: () => never.future);
    await tester.enterText(find.byKey(const Key('composer-input')), '离线消息');
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pump();

    // 立刻可见 + “等待发送”（网络问题绝不是红色失败）。
    expect(find.text('离线消息'), findsOneWidget);
    expect(find.text('等待发送'), findsOneWidget);

    final persisted = await outbox.unsent();
    expect(persisted, hasLength(1), reason: '用户一按发送就已经落盘');
    expect(persisted.single.content, '离线消息');
    expect(persisted.single.receiverId, '@peer:test');
    expect(persisted.single.roomId, isNull, reason: '房间还没建立');
    expect(persisted.single.status, OutboxStatus.queued);

    // 页面被销毁（离开/被杀）。用非 CupertinoApp 根节点强制整棵树重建，
    // 否则 Navigator 会被复用、旧路由仍然盖在新页面之上。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    outbox.dispose();

    // "重开 App"：同一存储上的新 manager + 新页面。
    final restarted = PersistentOutboxManager(store, accountId: 'me');
    await pumpPage(tester,
        outbox: restarted, openRoom: () => Completer<DirectChatRoom>().future);

    expect(find.text('离线消息'), findsOneWidget,
        reason: '重开后消息不能丢（旧的页内内存队列会丢）');
    expect(find.text('等待发送'), findsOneWidget,
        reason: '未送达的消息重开后仍显示等待发送');
    expect((await restarted.unsent()).single.localId, persisted.single.localId);
    restarted.dispose();
  });

  testWidgets('房间建立：把该接收方所有没有房间号的行绑定到真实房间号', (tester) async {
    final store = InMemoryOutboxStore();
    final outbox = PersistentOutboxManager(store, accountId: 'me');
    // 上一次进程留下的行（还没绑定房间号）。
    final leftover = await outbox.save(
        receiverId: '@peer:test', content: '上次留下的', status: OutboxStatus.waitingNetwork);
    final room = Completer<DirectChatRoom>();
    PendingConversationResult? result;

    await pumpPage(tester,
        outbox: outbox,
        openRoom: () => room.future,
        onResult: (value) => result = value);
    await tester.enterText(find.byKey(const Key('composer-input')), '本页输入');
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pump();

    room.complete(safeRoom('!dm:test'));
    await tester.pumpAndSettle();

    expect(result?.roomId, '!dm:test');
    expect(result?.outboxLocalIds, hasLength(2));
    final bound = await outbox.unsent();
    expect(bound, hasLength(2));
    for (final row in bound) {
      expect(row.roomId, '!dm:test',
          reason: '本页输入与上一次进程遗留的行都要绑定到真实房间号');
    }
    expect((await outbox.byLocalId(leftover!.localId))!.roomId, '!dm:test');
    expect(result?.queued, contains('本页输入'));
    outbox.dispose();
  });

  testWidgets('后台建立失败：消息仍在 outbox，重试成功后照样能绑定并续发', (tester) async {
    final store = InMemoryOutboxStore();
    final outbox = PersistentOutboxManager(store, accountId: 'me');
    var attempts = 0;
    PendingConversationResult? result;

    await pumpPage(tester,
        outbox: outbox,
        openRoom: () {
          attempts++;
          if (attempts == 1) {
            return Future<DirectChatRoom>.error(StateError('无网络'));
          }
          return Future<DirectChatRoom>.value(safeRoom('!dm:test'));
        },
        onResult: (value) => result = value);

    await tester.enterText(find.byKey(const Key('composer-input')), '别丢了我');
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();

    expect(attempts, 1);
    expect(await outbox.unsent(), hasLength(1),
        reason: '建立会话失败不影响已落盘的消息');

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(result?.roomId, '!dm:test');
    expect((await outbox.unsent()).single.roomId, '!dm:test');
    expect((await outbox.unsent()).single.content, '别丢了我');
    outbox.dispose();
  });

  testWidgets('项5-3：断网失败后网络恢复自动继续建房，无需手动重试',
      (tester) async {
    final network = ValueNotifier<NetworkState>(NetworkState.offline);
    addTearDown(network.dispose);
    var attempts = 0;
    final outbox = PersistentOutboxManager(InMemoryOutboxStore());
    PendingConversationResult? captured;
    await pumpPage(
      tester,
      outbox: outbox,
      networkState: network,
      openRoom: () async {
        attempts++;
        if (attempts == 1) throw StateError('offline');
        return safeRoom('!recovered:test');
      },
      onResult: (result) => captured = result,
    );
    await tester.pump();
    expect(attempts, 1, reason: '前置：断网下首次建立失败');

    // 网络恢复（offline → online）：自动继续，无需手点「重试」。
    network.value = NetworkState.online;
    await tester.pumpAndSettle();

    expect(attempts, 2, reason: '网络恢复必须自动继续建房');
    expect(captured?.roomId, '!recovered:test');
    expect(find.byType(PendingConversationPage), findsNothing);
  });
}
