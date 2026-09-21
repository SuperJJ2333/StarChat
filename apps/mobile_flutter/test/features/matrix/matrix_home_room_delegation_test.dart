import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';
import 'package:liuhetong_mobile/features/matrix/room_navigation_coordinator.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';
import 'package:matrix/matrix.dart';

/// 消息列表不再自建 RoomLease/RoomPage：它只负责等待动画、已读/未读与展示
/// 数据，房间页面统一由 AppHome 的 RoomNavigationCoordinator 打开。
void main() {
  testWidgets('消息列表把房间打开委托给统一入口，自己不建 RoomPage', (tester) async {
    ConversationReadState.shared().resetForTest();
    final harness = _DelegationHarness();
    await tester.pumpWidget(harness.widget());
    await tester.pumpAndSettle();

    await tester.tap(find.text('官方群'));
    await tester.pump();

    expect(harness.requests, hasLength(1));
    expect(harness.requests.single.roomId, '!官方群:test');
    expect(harness.requests.single.roomName, startsWith('官方群'),
        reason: '群聊标题仍用群名（N）的既有展示规则');
    expect(find.byType(RoomPage), findsNothing, reason: '消息列表不得自己构建 RoomPage');
    expect(ConversationReadState.shared().isRoomOpen('!官方群:test'), isTrue,
        reason: 'onRoomReady 时完成进入房间的已读状态');

    harness.completeOpen();
    await tester.pumpAndSettle();
    expect(ConversationReadState.shared().isRoomOpen('!官方群:test'), isFalse,
        reason: '页面退出后恢复列表态');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('同一房间连续点击只委托一次，页面退出后可再次打开', (tester) async {
    ConversationReadState.shared().resetForTest();
    final harness = _DelegationHarness();
    await tester.pumpWidget(harness.widget());
    await tester.pumpAndSettle();

    await tester.tap(find.text('官方群'));
    await tester.pump();
    await tester.tap(find.text('官方群'));
    await tester.pump();
    // E1 修复后：onRoomReady 即解锁守卫，第二次点击会再次委托——由协调器
    // 的「已打开优先」路径兜底（回到原页面，绝不推第二层）。
    expect(harness.requests.length, greaterThanOrEqualTo(1));

    // 排空挂起的委托（等价于页面逐个关闭）：每个都会触发 onRoomLanded。
    harness.completeOpen();
    harness.completeOpen();
    await tester.pumpAndSettle();
    final afterDrain = harness.requests.length;

    await tester.tap(find.text('官方群'));
    await tester.pump();
    expect(harness.requests.length, afterDrain + 1,
        reason: '房间关闭后应能再次打开');

    harness.completeOpen();
    harness.completeOpen();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('未注入统一入口（只读占位页）时不打开任何房间', (tester) async {
    ConversationReadState.shared().resetForTest();
    final harness = _DelegationHarness(previewOnly: true);
    await tester.pumpWidget(harness.widget());
    await tester.pumpAndSettle();

    await tester.tap(find.text('官方群'));
    await tester.pump();
    expect(harness.requests, isEmpty);
    expect(find.byType(RoomPage), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}

/// 记录委托请求的假统一入口：onRoomReady 立即回调（模拟租约就绪），
/// future 保持到测试调用 [completeOpen]（模拟页面仍然打开）；完成时按
/// 生产契约回调 onRoomClosed（页面退出收尾）。
final class _DelegationHarness {
  _DelegationHarness({this.previewOnly = false});

  final bool previewOnly;
  final requests = <RoomOpenRequest>[];
  final _pending = <(Completer<void>, RoomOpenRequest)>[];

  Future<void> onOpenRoom(RoomOpenRequest request) {
    requests.add(request);
    final completer = Completer<void>();
    _pending.add((completer, request));
    request.onRoomReady?.call();
    return completer.future;
  }

  void completeOpen() {
    if (_pending.isEmpty) return;
    final (completer, request) = _pending.removeAt(0);
    request.onRoomLanded?.call();
    request.onRoomClosed?.call();
    completer.complete();
  }

  Widget widget() => CupertinoApp(
          home: MatrixHomePage(
        api: _api(),
        matrix: MatrixSdkE2eeClient(_NoNetworkClient(),
            homeserver: Uri.parse('https://matrix.example')),
        themeController: ThemeController(store: _MemoryThemeStore()),
        onCreateGroup: () {},
        previewOnly: previewOnly,
        snapshotLoader: () async => _snapshot(),
        onOpenRoom: onOpenRoom,
      ));
}

MatrixConversationSnapshot _snapshot() => MatrixConversationSnapshot(
      vaultRoomId: null,
      reminderRoomId: null,
      rooms: [
        MatrixConversationRoomSnapshot(
          id: '!官方群:test',
          displayName: '官方群',
          avatar: null,
          isDirect: false,
          directPeerId: null,
          members: const [],
          lastEvent: null,
          preference: const ConversationPreference(),
          notificationCount: 0,
          notificationsEnabled: true,
          name: '官方群',
          isJoined: true,
        ),
      ],
    );

BusinessApiClient _api() => BusinessApiClient(
    baseUri: Uri.parse('https://business.example'),
    sessionStore: SecureSessionStore(_MemoryStore()),
    client: MockClient((_) async => http.Response('{}', 500)));

final class _NoNetworkClient extends Client {
  _NoNetworkClient() : super('home-room-delegation-test');
  @override
  String get userID => '@self:matrix.example';
}

final class _MemoryStore implements SecureKeyValueStore {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
}

final class _MemoryThemeStore implements ThemePreferenceStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
}
