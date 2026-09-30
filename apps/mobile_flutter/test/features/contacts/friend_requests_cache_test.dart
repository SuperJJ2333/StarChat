import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/features/friendship/friend_request_snapshot_store.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/foundation/avatar_cache.dart';
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
    Future<http.Response> Function(http.Request) handler,
    {String matrixUserId = '@alice:example',
    SecureKeyValueStore? storage}) async {
  final session = SecureSessionStore(storage ?? fixtures.MemoryStore());
  await session.saveSession(
      accessToken: 'e30.eyJzdWIiOiJhbGljZSJ9.test',
      refreshToken: 'refresh',
      matrixUserId: matrixUserId);
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

  testWidgets('断网 + 本地快照：仍展示上次的申请列表，不谎报「暂无新的朋友」', (tester) async {
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
    expect(find.text('新的朋友加载失败'), findsNothing, reason: '有本地数据时的刷新失败不显示错误页');
  });

  testWidgets('无本地快照且加载失败：显示加载失败与重试，而不是「暂无新的朋友」', (tester) async {
    final api = await _client((request) async => throw StateError('offline'));
    FriendRequestSnapshotStores.shared = InMemoryFriendRequestSnapshotStore();

    await tester.pumpWidget(CupertinoApp(home: FriendRequestsPage(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('暂无新的朋友'), findsNothing, reason: '加载失败不能伪装成"没有新朋友"');
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

  testWidgets(
      'friend request avatar stays scoped across two real account pages',
      (tester) async {
    Map<String, dynamic> accountPayload(String account) => {
          'items': [
            {
              ...(_payload()['items'] as List).single as Map,
              'avatar_url':
                  'https://media.example.test/avatar?token=$account&v=1',
            }
          ]
        };
    final profileStore =
        SharedPreferencesProfileStore(await SharedPreferences.getInstance());
    final accountA = ProfileRepository.forTesting(
        accountKey: 'matrix:@alice:example', store: profileStore);
    final accountB = ProfileRepository.forTesting(
        accountKey: 'matrix:@bea:example', store: profileStore);
    var aliceToken = 'alice';
    final apiA = await _client((_) async => _json(accountPayload(aliceToken)));
    final apiB = await _client((_) async => _json(accountPayload('bea')),
        matrixUserId: '@bea:example');

    await tester.pumpWidget(CupertinoApp(
        home: FriendRequestsPage(
            key: const ValueKey('account-a'),
            api: apiA,
            identityCache: accountA)));
    await tester.pumpAndSettle();
    final firstAvatar = tester.widget<UserAvatar>(find.byType(UserAvatar));
    final firstImage = tester.widget<Image>(find.byType(Image).first);
    firstImage.frameBuilder!(
        tester.element(find.byType(Image).first), const SizedBox(), 0, true);
    expect(firstAvatar.avatarCacheKey,
        accountA.resolveIdentity(userId: 'u1', username: 'xiaohong').cacheKey);
    final retainedA = AvatarCache.lastSuccessful(firstAvatar.avatarCacheKey!);
    expect(retainedA, isNotNull);

    aliceToken = 'alice-renewed';
    await tester.pumpWidget(CupertinoApp(
        home: FriendRequestsPage(
            key: const ValueKey('account-a-renewed'),
            api: apiA,
            identityCache: accountA)));
    await tester.pumpAndSettle();
    final renewedAvatar = tester.widget<UserAvatar>(find.byType(UserAvatar));
    expect(renewedAvatar.avatarCacheKey, firstAvatar.avatarCacheKey);
    final renewedImage = tester.widget<Image>(find.byType(Image).first);
    expect(
        renewedImage.frameBuilder!(tester.element(find.byType(Image).first),
            const SizedBox(), null, false),
        isA<Stack>(),
        reason: 'same-account URL renewal retains the last painted avatar');

    await tester.pumpWidget(CupertinoApp(
        home: FriendRequestsPage(
            key: const ValueKey('account-b-stale-profile'),
            api: apiB,
            identityCache: accountA)));
    await tester.pumpAndSettle();
    final staleProfileAvatar =
        tester.widget<UserAvatar>(find.byType(UserAvatar));
    expect(staleProfileAvatar.avatarCacheKey, isNot(firstAvatar.avatarCacheKey),
        reason: 'B session must not reuse an injected A profile cache key');
    final staleProfileImage = tester.widget<Image>(find.byType(Image).first);
    expect(
        staleProfileImage.frameBuilder!(
            tester.element(find.byType(Image).first),
            const SizedBox(),
            null,
            false),
        isNot(isA<Stack>()),
        reason:
            'B first paint must not show A retained avatar during transition');

    await tester.pumpWidget(CupertinoApp(
        home: FriendRequestsPage(
            key: const ValueKey('account-b'),
            api: apiB,
            identityCache: accountB)));
    await tester.pumpAndSettle();
    final secondAvatar = tester.widget<UserAvatar>(find.byType(UserAvatar));
    expect(secondAvatar.avatarCacheKey,
        accountB.resolveIdentity(userId: 'u1', username: 'xiaohong').cacheKey);
    expect(secondAvatar.avatarCacheKey, isNot(firstAvatar.avatarCacheKey));
    expect(AvatarCache.lastSuccessful(firstAvatar.avatarCacheKey!),
        same(retainedA));
    final secondImage = tester.widget<Image>(find.byType(Image).first);
    final pending = secondImage.frameBuilder!(
        tester.element(find.byType(Image).first),
        const SizedBox(),
        null,
        false);
    expect(pending, isNot(isA<Stack>()),
        reason: 'account B must not paint account A retained provider');

    await tester.tap(find.text('小鸿').first);
    await tester.pumpAndSettle();
    final reviewAvatar = tester.widget<UserAvatar>(find.byType(UserAvatar));
    expect(reviewAvatar.avatarCacheKey, secondAvatar.avatarCacheKey);
    await tester.pumpWidget(const SizedBox());
    accountA.dispose();
    accountB.dispose();
  });

  testWidgets('a previous account snapshot cannot paint before scope resolves',
      (tester) async {
    final delayedStorage = _DelayedSessionReadStore();
    final response = Completer<http.Response>();
    final api = await _client((_) => response.future,
        matrixUserId: '@bea:example', storage: delayedStorage);
    FriendRequestSnapshotStores.shared = InMemoryFriendRequestSnapshotStore(
        FriendRequestSnapshot(
            scope: 'matrix:@alice:example',
            payload: _payload(),
            savedAt: DateTime(2026, 9, 29)));

    await tester.pumpWidget(CupertinoApp(home: FriendRequestsPage(api: api)));
    expect(find.text('小鸿'), findsNothing,
        reason:
            'account B must not paint account A saved request on first frame');
    expect(find.byType(UserAvatar), findsNothing);

    delayedStorage.release.complete();
    await tester.pump();
    expect(find.text('小鸿'), findsNothing);
    response.complete(_json({
      'items': [
        {
          ...(_payload()['items'] as List).single as Map,
          'nickname': '小贝',
          'avatar_url': 'https://media.example.test/avatar?v=bea',
        }
      ]
    }));
    await tester.pumpAndSettle();
    expect(find.text('小贝'), findsOneWidget);
    expect(find.text('小鸿'), findsNothing);
  });

  testWidgets('an old review route cannot accept through the next account API',
      (tester) async {
    var writesA = 0;
    var writesB = 0;
    final apiA = await _client((request) async {
      if (request.method != 'GET') writesA++;
      return _json(request.method == 'GET' ? _payload() : <String, Object>{});
    });
    final apiB = await _client((request) async {
      if (request.method != 'GET') writesB++;
      return _json(request.method == 'GET'
          ? {
              'items': [
                {
                  ...(_payload()['items'] as List).single as Map,
                  'nickname': '小贝'
                }
              ]
            }
          : <String, Object>{});
    }, matrixUserId: '@bea:example');
    final profile = ProfileRepository.forTesting(
        accountKey: 'matrix:@alice:example',
        store: SharedPreferencesProfileStore(
            await SharedPreferences.getInstance()));
    var activeApi = apiA;
    late StateSetter setHostState;
    await tester.pumpWidget(
        CupertinoApp(home: StatefulBuilder(builder: (context, setState) {
      setHostState = setState;
      return FriendRequestsPage(api: activeApi, identityCache: profile);
    })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小鸿').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('friend-request-accept')), findsOneWidget);

    setHostState(() => activeApi = apiB);
    await tester.pumpAndSettle();
    expect(find.text('小鸿'), findsNothing,
        reason: 'A review content must disappear once the B frame settles');
    expect(writesA, 0);
    expect(writesB, 0,
        reason: 'A review must never use the newly active B API');
    expect(find.byKey(const Key('friend-request-accept')), findsNothing,
        reason: 'stale review should close after the account switch');
    await tester.pumpWidget(const SizedBox());
    profile.dispose();
  });
}

final class _DelayedSessionReadStore extends fixtures.MemoryStore {
  final release = Completer<void>();

  @override
  Future<String?> read(String key) async {
    await release.future;
    return super.read(key);
  }
}
