import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/features/friendship/friend_request_snapshot_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../wallet/manual_wallet_api_test.dart' as fixtures;

/// 微信级加载模型（2026-09-19 审计）：「新的朋友」原先只有一个
/// `Future<Map>` 数据源 —— 加载中与加载失败时 `snapshot.data` 都是 null，
/// 于是两种情形都渲染「暂无新的朋友」，断网时还会把上次的申请列表丢掉。
/// 新契约：本地快照先展示；失败但有数据时不报错；只有"从未成功过且无数据"
/// 才显示加载失败与重试。
http.Response _json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

Future<BusinessApiClient> _client(
    Future<http.Response> Function(http.Request) handler) async {
  final session = SecureSessionStore(fixtures.MemoryStore());
  await session.saveSession(
      accessToken: 'e30.eyJzdWIiOiJhbGljZSJ9.test',
      refreshToken: 'refresh',
      matrixUserId: '@alice:example');
  return BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: session,
      client: MockClient(handler));
}

Map<String, dynamic> _payload() => {
      'items': [
        {
          'id': 'req-1',
          'nickname': '小鸿',
          'username': 'xiaohong',
          'message': '我是小鸿',
          'status': 'PENDING',
          'direction': 'INCOMING',
          'user_id': 'u1',
          'matrix_user_id': '@x:example',
        },
      ],
    };

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FriendRequestSnapshotStores.reset();
  });
  tearDown(FriendRequestSnapshotStores.reset);

  testWidgets('断网 + 本地快照：仍展示上次的申请列表，不谎报「暂无新的朋友」',
      (tester) async {
    final api = await _client((request) async => throw StateError('offline'));
    FriendRequestSnapshotStores.shared = InMemoryFriendRequestSnapshotStore(
        FriendRequestSnapshot(
            scope: 'matrix:@alice:example',
            payload: _payload(),
            savedAt: DateTime(2026, 9, 19, 8)));

    await tester.pumpWidget(CupertinoApp(home: FriendRequestsPage(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('小鸿'), findsOneWidget, reason: '断网时必须展示上次的申请列表');
    expect(find.text('暂无新的朋友'), findsNothing);
    expect(find.text('新的朋友加载失败'), findsNothing,
        reason: '有本地数据时的刷新失败不显示错误页');
  });

  testWidgets('无本地快照且加载失败：显示加载失败与重试，而不是「暂无新的朋友」',
      (tester) async {
    final api = await _client((request) async => throw StateError('offline'));
    FriendRequestSnapshotStores.shared = InMemoryFriendRequestSnapshotStore();

    await tester.pumpWidget(CupertinoApp(home: FriendRequestsPage(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('暂无新的朋友'), findsNothing,
        reason: '加载失败不能伪装成"没有新朋友"');
    expect(find.text('新的朋友加载失败'), findsOneWidget);
    expect(find.byKey(const Key('friend-requests-retry')), findsOneWidget);
  });

  testWidgets('加载成功：写入本地快照，供下次进入/断网使用', (tester) async {
    final api = await _client((request) async => _json(_payload()));
    final snapshots = InMemoryFriendRequestSnapshotStore();
    FriendRequestSnapshotStores.shared = snapshots;

    await tester.pumpWidget(CupertinoApp(home: FriendRequestsPage(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('小鸿'), findsOneWidget);
    expect(snapshots.read()?.scope, 'matrix:@alice:example');
    expect((snapshots.read()?.payload['items'] as List?)?.length, 1);
  });
}
