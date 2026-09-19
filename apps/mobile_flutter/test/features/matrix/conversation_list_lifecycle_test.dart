import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';
import 'package:matrix/matrix.dart';

/// 可重复完成的 sync fake：每次 `sync()` 挂起，`completeSync()` 释放一次并
/// 触发真实的 syncEvents 广播（生产中前后台切换的刷新入口就是这条链路）。
final class LifecycleStormClient extends Client {
  LifecycleStormClient() : super('lifecycle-storm');
  Completer<SyncUpdate>? _held;
  @override
  String get userID => '@me:matrix.example';
  @override
  Future<SyncUpdate> sync(
          {String? filter,
          String? since,
          bool? fullState,
          PresenceType? setPresence,
          int? timeout}) =>
      (_held = Completer<SyncUpdate>()).future;
  void completeSync() =>
      _held?.complete(SyncUpdate.fromJson(const {}));
}

final class _MemoryThemeStore implements ThemePreferenceStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
}

MatrixConversationRoomSnapshot _direct(String id, String peer) =>
    MatrixConversationRoomSnapshot(
      id: id,
      displayName: id,
      avatar: null,
      isDirect: true,
      directPeerId: peer,
      members: const [],
      lastEvent: null,
      preference: const ConversationPreference(),
      notificationCount: 0,
      notificationsEnabled: true,
      name: id,
      isJoined: true,
    );

MatrixConversationRoomSnapshot _group(String id) =>
    MatrixConversationRoomSnapshot(
      id: id,
      displayName: id,
      avatar: null,
      isDirect: false,
      directPeerId: null,
      members: const [],
      lastEvent: null,
      preference: const ConversationPreference(),
      notificationCount: 0,
      notificationsEnabled: true,
      name: id,
      isJoined: true,
    );

/// 同一好友（@peer）两个房间的重复快照——重复会话缺陷的实际形态。
final _duplicateSnapshot = MatrixConversationSnapshot(
  vaultRoomId: null,
  reminderRoomId: null,
  rooms: [
    _direct('!old:storm', '@peer:matrix.example'),
    _direct('!new:storm', '@peer:matrix.example'),
    _group('!group:storm'),
  ],
);

/// 收敛后形态：只剩一个房间，列表必须保持唯一。
final _convergedSnapshot = MatrixConversationSnapshot(
  vaultRoomId: null,
  reminderRoomId: null,
  rooms: [
    _direct('!new:storm', '@peer:matrix.example'),
    _group('!group:storm'),
  ],
);

void main() {
  testWidgets('测试4：生命周期切换 + sync 风暴下重复会话列表保持唯一',
      (tester) async {
    var calls = 0;
    Future<MatrixConversationSnapshot> load() async =>
        calls++ % 2 == 0 ? _duplicateSnapshot : _convergedSnapshot;
    final client = LifecycleStormClient();
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'));
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: SecureSessionStore(_MemoryStore()),
        client: MockClient((_) async => http.Response('{}', 500)));

    await tester.pumpWidget(CupertinoApp(
        home: MatrixHomePage(
            api: api,
            matrix: matrix,
            themeController: ThemeController(store: _MemoryThemeStore()),
            onCreateGroup: () {},
            previewOnly: false,
            snapshotLoader: load)));
    await tester.pumpAndSettle();

    // 重复形态下也只渲染一行：胜者（最近活跃 roomId 兜序）出现、落选者不出现。
    expect(find.byKey(const ValueKey<String>('conversation-!new:storm')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('conversation-!old:storm')),
        findsNothing);

    // iOS/Android 生命周期模拟：退后台→恢复。生产中恢复触发的 sync 完成后
    // 经 syncEvents 驱动下面的刷新风暴。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    // sync 风暴：连续 3 次 sync 完成，各自触发一整轮快照刷新。
    for (var round = 0; round < 3; round++) {
      unawaited(matrix.syncIfActive().catchError((_) {}));
      await tester.pump();
      client.completeSync();
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('conversation-!new:storm')),
        findsOneWidget, reason: '风暴过后该好友仍只有一行');
    expect(find.byKey(const ValueKey<String>('conversation-!old:storm')),
        findsNothing);
    expect(find.byKey(const ValueKey<String>('conversation-!group:storm')),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

class _MemoryStore implements SecureKeyValueStore {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
}
