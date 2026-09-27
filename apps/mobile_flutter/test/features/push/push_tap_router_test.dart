import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/notification_deduplicator.dart';
import 'package:liuhetong_mobile/core/notification/notification_diagnostics.dart';
import 'package:liuhetong_mobile/features/push/push_tap_router.dart';

void main() {
  late NotificationDeduplicator deduplicator;
  late NotificationDiagnostics diagnostics;

  setUp(() {
    deduplicator = NotificationDeduplicator(
      store: MemoryNotificationDedupStore(),
      ttl: const Duration(hours: 24),
    );
    diagnostics = NotificationDiagnostics(store: _MemoryDiagStore());
  });

  PushTapRouter router(List<String> opened) => PushTapRouter(
        openConversation: (roomId) async => opened.add(roomId),
        deduplicator: deduplicator,
        diagnostics: diagnostics,
      )..setForeground(true);

  test('session ready alone cannot navigate while foreground is unknown',
      () async {
    final opened = <String>[];
    final tapRouter = PushTapRouter(
      openConversation: (roomId) async => opened.add(roomId),
      deduplicator: deduplicator,
      diagnostics: diagnostics,
    );
    tapRouter.markReady();
    tapRouter.handleTap(
        const PushNotificationPayload(roomId: '!locked:matrix.example'));
    await Future<void>.delayed(Duration.zero);
    expect(opened, isEmpty);
    expect(tapRouter.hasPending, isTrue);
  });

  test('inactive notification waits for resumed and opens only once', () async {
    final opened = <String>[];
    final tapRouter = router(opened)..markReady();
    tapRouter.setForeground(false);
    tapRouter.handleTap(const PushNotificationPayload(
      eventId: '\$inactive-event',
      roomId: '!inactive:matrix.example',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(opened, isEmpty);
    expect(deduplicator.hasProcessed('\$inactive-event'), isTrue);
    tapRouter.markReady();
    expect(opened, isEmpty);
    tapRouter.setForeground(true);
    tapRouter.setForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(opened, ['!inactive:matrix.example']);
    expect(tapRouter.hasPending, isFalse);
  });

  test('resumed before session ready leaves notification pending', () async {
    final opened = <String>[];
    final tapRouter = router(opened)..setForeground(false);
    tapRouter.handleTap(
        const PushNotificationPayload(roomId: '!cold:matrix.example'));
    tapRouter.setForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(opened, isEmpty);
    tapRouter.markReady();
    await Future<void>.delayed(Duration.zero);
    expect(opened, ['!cold:matrix.example']);
  });

  test('logout while inactive discards old account notification', () async {
    final opened = <String>[];
    final tapRouter = router(opened)..markReady();
    tapRouter.setForeground(false);
    tapRouter.handleTap(
        const PushNotificationPayload(roomId: '!old-account:matrix.example'));
    tapRouter.reset();
    tapRouter.setForeground(true);
    tapRouter.markReady();
    await Future<void>.delayed(Duration.zero);
    expect(opened, isEmpty);
  });

  test('resumed pending tap waits for an existing navigation to finish',
      () async {
    final opened = <String>[];
    final firstOpen = Completer<void>();
    final tapRouter = PushTapRouter(
      openConversation: (roomId) async {
        opened.add(roomId);
        if (opened.length == 1) await firstOpen.future;
      },
      deduplicator: deduplicator,
      diagnostics: diagnostics,
    )..setForeground(true);
    tapRouter.markReady();
    tapRouter.handleTap(
        const PushNotificationPayload(roomId: '!first:matrix.example'));
    tapRouter.setForeground(false);
    tapRouter.handleTap(
        const PushNotificationPayload(roomId: '!second:matrix.example'));
    tapRouter.setForeground(true);
    expect(tapRouter.hasPending, isTrue);
    firstOpen.complete();
    await Future<void>.delayed(Duration.zero);
    expect(opened, ['!first:matrix.example', '!second:matrix.example']);
    expect(tapRouter.hasPending, isFalse);
  });

  test('冷启动：就绪前点击挂起，就绪后进入对应会话', () async {
    final opened = <String>[];
    final tapRouter = router(opened);
    tapRouter.handleTap(const PushNotificationPayload(
      eventId: '\$evt-cold-start',
      roomId: '!room-1:matrix.example',
      type: 'm.room.message',
    ));
    expect(opened, isEmpty, reason: '主页面未就绪不得导航');
    expect(tapRouter.hasPending, isTrue);

    // 系统推送已展示：eventId 进入去重，同步到达同一事件时不再提醒。
    expect(deduplicator.hasProcessed('\$evt-cold-start'), isTrue,
        reason: '推送点击必须先标记去重，防止同步二次提醒');

    tapRouter.markReady();
    await Future<void>.delayed(Duration.zero);
    expect(opened, ['!room-1:matrix.example']);
    expect(tapRouter.hasPending, isFalse);
  });

  test('就绪后点击：立即进入会话', () async {
    final opened = <String>[];
    final tapRouter = router(opened);
    tapRouter.markReady();
    tapRouter.handleTap(
        const PushNotificationPayload(roomId: '!room-2:matrix.example'));
    await Future<void>.delayed(Duration.zero);
    expect(opened, ['!room-2:matrix.example']);
  });

  test('无 roomId 的点击被丢弃', () async {
    final opened = <String>[];
    final tapRouter = router(opened);
    tapRouter.markReady();
    tapRouter.handleTap(const PushNotificationPayload(eventId: '\$evt-x'));
    await Future<void>.delayed(Duration.zero);
    expect(opened, isEmpty);
  });

  test('登出/账号切换 reset：挂起的路由不跨账号串会话', () async {
    final opened = <String>[];
    final tapRouter = router(opened);
    tapRouter.handleTap(
        const PushNotificationPayload(roomId: '!room-3:matrix.example'));
    tapRouter.reset();
    tapRouter.markReady();
    await Future<void>.delayed(Duration.zero);
    expect(opened, isEmpty);
  });

  test('并发点击只打开一次（防双击双推页）', () async {
    var openCalls = 0;
    final completer = Completer<void>();
    final tapRouter = PushTapRouter(
      openConversation: (roomId) async {
        openCalls++;
        await completer.future;
      },
      deduplicator: deduplicator,
      diagnostics: diagnostics,
    )..setForeground(true);
    tapRouter.markReady();
    tapRouter.handleTap(
        const PushNotificationPayload(roomId: '!room-4:matrix.example'));
    tapRouter.handleTap(
        const PushNotificationPayload(roomId: '!room-4:matrix.example'));
    completer.complete();
    await Future<void>.delayed(Duration.zero);
    expect(openCalls, 1);
  });

  group('推送载荷白名单（E2EE 边界）', () {
    test('只提取 event_id/room_id/type/unread 四个不透明字段', () {
      final payload = PushNotificationPayload.parse({
        'event_id': '\$opaque-event',
        'room_id': '!opaque-room:matrix.example',
        'type': 'm.room.message',
        'unread': 3,
        // 即使服务端误发正文/密钥类字段，客户端也不读取：
        'content': '{"body":"秘密明文"}',
        'body': '秘密明文',
        'file': 'attack.pdf',
        'room_key': 'SAIDKEY==',
      });
      expect(payload.eventId, '\$opaque-event');
      expect(payload.roomId, '!opaque-room:matrix.example');
      expect(payload.type, 'm.room.message');
      expect(payload.unreadCount, 3);
    });

    test('m.call.* 判定为来电信令推送', () {
      expect(
        PushNotificationPayload.parse({'type': 'm.call.invite'}).isCall,
        isTrue,
      );
      expect(
        PushNotificationPayload.parse({'type': 'm.room.message'}).isCall,
        isFalse,
      );
    });

    test('空载荷与缺失字段安全降级', () {
      const empty = PushNotificationPayload();
      expect(empty.eventId, isNull);
      expect(empty.roomId, isNull);
      expect(empty.isCall, isFalse);
      expect(PushNotificationPayload.parse(null).roomId, isNull);
      expect(
        PushNotificationPayload.parse({'unread': 'not-a-number'}).unreadCount,
        isNull,
      );
    });
  });
}

final class _MemoryDiagStore implements NotificationDiagStore {
  String? _encoded;

  @override
  Future<String?> read() async => _encoded;

  @override
  Future<void> write(String encoded) async => _encoded = encoded;
}
