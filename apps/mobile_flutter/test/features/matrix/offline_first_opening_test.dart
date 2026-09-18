import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/network_state_manager.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/coordinated_direct_chat.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';
import 'package:liuhetong_mobile/features/matrix/pending_conversation_page.dart';
import 'package:liuhetong_mobile/features/matrix/room_navigation_coordinator.dart';
import 'package:liuhetong_mobile/features/matrix/room_opening_policy.dart';

/// Offline First（2026-09-18）：进入好友加密会话**不得**被网络阻塞。
///
/// 覆盖产品验收：
/// 1. 无网络进入好友聊天 → 可以进入（本地有房间时立即进入，没有房间时进入
///    pending conversation）；
/// 2. 弱网进入好友聊天 → 不阻塞导航（本地已知房间零等待）。
void main() {
  group('本地优先解析（零网络）', () {
    test('本地已有安全快照 → 立即返回，且不触发任何协调网络调用', () async {
      final coordinator = _RecordingCoordinator();
      final intents = _RecordingIntents(roomId: '!intent:test');
      var findCachedCalls = 0;
      final gateway = CoordinatedDirectChatGateway(
        coordinator: coordinator,
        intents: intents,
        businessUserIdOf: (matrixUserId) => 'peer-1',
        createOnce: (_) async => fail('offline entry must never create a room'),
        findExisting: (_) async => fail('offline entry must not search remotely'),
        openExisting: (_, __) async => fail('offline entry must not open remotely'),
        findCached: (matrixUserId) async {
          findCachedCalls++;
          return _safeRoom('!cached:test', matrixUserId);
        },
        wait: (_) async => fail('offline entry must not wait for the network'),
      );

      final local = await gateway.tryLocalDirectChat('@peer:test');

      expect(local?.roomId, '!cached:test');
      expect(findCachedCalls, 1);
      expect(coordinator.canonicalCalls, 0, reason: '本地命中不得查询业务目录');
      expect(coordinator.claimCalls, 0);
      expect(coordinator.publishCalls, 0);
      expect(intents.loads, 0, reason: '本地命中不需要读 intent');
    });

    test('本地没有会话 → 返回 null（不是错误），同样零网络', () async {
      final coordinator = _RecordingCoordinator();
      final gateway = CoordinatedDirectChatGateway(
        coordinator: coordinator,
        intents: _RecordingIntents(),
        businessUserIdOf: (matrixUserId) => 'peer-1',
        createOnce: (_) async => fail('must not create while probing locally'),
        findExisting: (_) async => fail('must not search while probing locally'),
        openExisting: (_, __) async => fail('must not open while probing locally'),
        findCached: (_) async => null,
        wait: (_) async => fail('must not wait while probing locally'),
      );

      expect(await gateway.tryLocalDirectChat('@peer:test'), isNull);
      expect(coordinator.canonicalCalls, 0);
    });

    test('本地快照不安全（未加密/成员不匹配）→ 视为本地缺失', () async {
      final gateway = CoordinatedDirectChatGateway(
        coordinator: _RecordingCoordinator(),
        intents: _RecordingIntents(),
        businessUserIdOf: (matrixUserId) => 'peer-1',
        createOnce: (_) async => fail('no create'),
        findExisting: (_) async => fail('no remote search'),
        openExisting: (_, __) async => fail('no remote open'),
        findCached: (_) async => const DirectChatRoom(
          roomId: '!unsafe:test',
          encrypted: false,
          joinedMemberCount: 2,
          participantIds: {'@me:test', '@peer:test'},
        ),
        wait: (_) async => fail('no wait'),
      );

      expect(await gateway.tryLocalDirectChat('@peer:test'), isNull);
    });

    test('本地质量失败（读取异常）也不抛错，按缺失处理', () async {
      final gateway = CoordinatedDirectChatGateway(
        coordinator: _RecordingCoordinator(),
        intents: _RecordingIntents(),
        businessUserIdOf: (matrixUserId) => 'peer-1',
        createOnce: (_) async => fail('no create'),
        findExisting: (_) async => fail('no remote search'),
        openExisting: (_, __) async => fail('no remote open'),
        findCached: (_) async => throw StateError('local db closed'),
        wait: (_) async => fail('no wait'),
      );

      expect(await gateway.tryLocalDirectChat('@peer:test'), isNull);
    });

    test('持久化 intent 的房间号作为无网提示返回', () async {
      final gateway = CoordinatedDirectChatGateway(
        coordinator: _RecordingCoordinator(),
        intents: _RecordingIntents(roomId: '!intent:test'),
        businessUserIdOf: (matrixUserId) => 'peer-1',
        createOnce: (_) async => fail('no create'),
        findExisting: (_) async => fail('no remote search'),
        openExisting: (_, __) async => fail('no remote open'),
        findCached: (_) async => null,
        wait: (_) async => fail('no wait'),
      );

      expect(await gateway.localRoomHint('@peer:test'), '!intent:test');
    });
  });

  group('RoomOpeningPolicy：本地已知即刻进入（弱网不阻塞导航）', () {
    test('本地已知但未加入 → openNow，零有界等待', () async {
      final policy = RoomOpeningPolicy(probe: _Probe(known: {'!dm:test'}));
      var waited = 0;

      await policy.open(
        const RoomOpenRequest(
            roomId: '!dm:test', roomName: 'Peer', source: RoomOpenSource.contactProfile),
        navigate: (_) async {},
        awaitLocalRoom: (_) async {
          waited++;
          return true;
        },
      );

      expect(waited, 0, reason: '弱网下不得等待网络同步');
      expect(
        policy
            .evaluate(const RoomOpenRequest(
                roomId: '!dm:test',
                roomName: 'Peer',
                source: RoomOpenSource.contactProfile))
            .reason,
        'local_known',
      );
    });

    test('本地完全未知 → 仍然允许一次有界等待（等不到就可见失败）', () async {
      final policy = RoomOpeningPolicy(probe: _Probe());
      var waited = 0;

      await policy.open(
        const RoomOpenRequest(
            roomId: '!unknown:test',
            roomName: 'Peer',
            source: RoomOpenSource.contactProfile),
        navigate: (_) async {},
        awaitLocalRoom: (_) async {
          waited++;
          return true;
        },
      );

      expect(waited, 1);
    });
  });

  group('PendingConversationPage：无网也能进入并排队消息', () {
    testWidgets('立即渲染，不等待网络；消息以“等待发送”排队；房间就绪后回传', (tester) async {
      final manager = NetworkStateManager()
        ..report(transportAvailable: false, serverReachable: false);
      final room = Completer<DirectChatRoom>();
      PendingConversationResult? result;

      await tester.pumpWidget(CupertinoApp(
        home: Builder(
          builder: (context) => CupertinoButton(
            child: const Text('enter'),
            onPressed: () async {
              result = await Navigator.of(context).push<PendingConversationResult>(
                CupertinoPageRoute(
                  builder: (_) => PendingConversationPage(
                    contact: _peer,
                    openRoom: () => room.future,
                    networkState: manager.state,
                  ),
                ),
              );
            },
          ),
        ),
      ));
      await tester.tap(find.text('enter'));
      await tester.pumpAndSettle();

      // 第一帧就已经在会话页里（网络尚未完成），并给出离线说明。
      expect(find.text('Peer 昵称'), findsOneWidget);
      expect(find.text('当前没有网络，消息将在恢复后同步。'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('composer-input')), '离线消息');
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.pump();
      expect(find.text('离线消息'), findsOneWidget);
      expect(find.text('等待发送'), findsOneWidget);

      // 后台仲裁完成 → 页面以房间号 + 排队消息返回给组合根。
      room.complete(_safeRoom('!dm:test', '@peer:test'));
      await tester.pumpAndSettle();
      expect(result?.roomId, '!dm:test');
      expect(result?.queued, ['离线消息']);
      manager.dispose();
    });

    testWidgets('后台建立失败 → 显示分类文案与重试，不显示旧口径', (tester) async {
      final room = Completer<DirectChatRoom>();
      await tester.pumpWidget(CupertinoApp(
        home: PendingConversationPage(
          contact: _peer,
          openRoom: () => room.future,
        ),
      ));
      await tester.pump();
      room.completeError(const SocketException('no route to host'));
      await tester.pumpAndSettle();

      expect(find.text('当前没有网络，消息将在恢复后同步。'), findsOneWidget);
      expect(find.text('无法打开加密会话'), findsNothing);
      expect(find.text('重试'), findsOneWidget);
    });
  });
}

const _peer = ContactDetails(
  userId: 'peer-1',
  username: 'peer',
  matrixUserId: '@peer:test',
  nickname: 'Peer 昵称',
);

DirectChatRoom _safeRoom(String roomId, String peer) => DirectChatRoom(
      roomId: roomId,
      encrypted: true,
      joinedMemberCount: 2,
      participantIds: <String>{'@me:test', '@peer:test', peer},
    );

final class _Probe implements RoomOpenLocalProbe {
  _Probe({Set<String>? known, Set<String>? joined})
      : known = known ?? <String>{},
        joined = joined ?? <String>{};

  final Set<String> known;
  final Set<String> joined;

  @override
  bool knowsRoom(String roomId) => known.contains(roomId);

  @override
  bool isJoined(String roomId) => joined.contains(roomId);

  @override
  Set<String> get controlRoomIds => const <String>{};
}

final class _RecordingCoordinator implements DirectRoomCoordinator {
  int canonicalCalls = 0;
  int claimCalls = 0;
  int publishCalls = 0;

  @override
  Future<String?> canonicalRoomId(String peer) async {
    canonicalCalls++;
    return null;
  }

  @override
  Future<DirectRoomClaim> claim(String peer, String attemptId) async {
    claimCalls++;
    return const DirectRoomClaim();
  }

  @override
  Future<String> publish(String peer, String attemptId, String roomId) async {
    publishCalls++;
    return roomId;
  }
}

final class _RecordingIntents implements DirectRoomIntentStore {
  _RecordingIntents({this.roomId});

  final String? roomId;
  int loads = 0;

  @override
  Future<DirectRoomIntent> loadOrCreate(String peer) async {
    loads++;
    return DirectRoomIntent(attemptId: 'attempt-$peer', roomId: roomId);
  }

  @override
  Future<void> saveRoom(String peer, DirectRoomIntent intent, String roomId) async {}
}
