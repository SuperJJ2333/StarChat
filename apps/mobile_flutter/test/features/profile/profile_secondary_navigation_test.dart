import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/caibi/caibi_page.dart';
import 'package:liuhetong_mobile/features/ledger/ledger_pages.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/moments/personal_moments_page.dart';
import 'package:liuhetong_mobile/features/profile/invite_code_page.dart';
import 'package:liuhetong_mobile/features/profile/my_qr_code_page.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/profile/profile_page.dart';
import 'package:liuhetong_mobile/features/wallet/wallet_page.dart';

const _profile = ProfileData(
  username: 'alice',
  nickname: 'Alice',
  maskedEmail: 'a***@example.test',
  fallbackSeed: 'alice',
  signature: 'hello',
);

final class _MemoryKeys implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

final class _MemoryProfiles implements ProfileStore {
  @override
  Future<ProfileSnapshot?> read(String accountKey) async => null;
  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {}
}

Future<
    (
      Widget,
      CupertinoTabController,
      BusinessApiClient,
      ValueNotifier<int>,
      ValueNotifier<int>
    )> _harness({String? token, ValueNotifier<int>? unreadCalls}) async {
  final keys = SecureSessionStore(_MemoryKeys());
  await keys.saveSession(
    accessToken: token ??
        'h.${base64UrlEncode(utf8.encode(jsonEncode({'sub': 'self'})))}.s',
    refreshToken: 'refresh',
    matrixUserId: '@alice:test',
  );
  final unread = ValueNotifier<int>(3);
  final refresh = ValueNotifier<int>(0);
  final api = BusinessApiClient(
    baseUri: Uri.parse('https://api.example.test'),
    sessionStore: keys,
    client: MockClient((request) async {
      Object body = <String, Object?>{};
      if (request.url.path.endsWith('/profile/me')) {
        body = {
          'username': 'alice',
          'nickname': 'Alice',
          'masked_email': 'a***@example.test',
          'avatar_fallback_seed': 'alice',
          'signature': 'hello',
        };
      } else if (request.url.path
          .endsWith('/moments/notifications/unread-count')) {
        if (unreadCalls != null) unreadCalls.value++;
        body = {'count': unread.value};
      } else if (request.url.path.endsWith('/moments/users/self')) {
        body = {'items': <Object>[]};
      } else if (request.url.path.endsWith('/invitations/mine')) {
        body = {
          'code': 'ABC123',
          'max_uses': 10,
          'use_count': 0,
          'share_url': 'https://example.test/invite/ABC123',
        };
      } else if (request.url.path.endsWith('/invitations/history')) {
        body = {'items': <Object>[]};
      }
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }),
  );
  final cache = ProfileRepository.forTesting(
      accountKey: 'matrix:@alice:test',
      store: _MemoryProfiles(),
      loadProfile: () async => _profile)
    ..profile = _profile;
  final tabs = CupertinoTabController(initialIndex: 1);
  return (
    CupertinoApp(
      home: CupertinoTabScaffold(
        controller: tabs,
        tabBar: CupertinoTabBar(
            onTap: (index) {
              if (index == 1) refresh.value++;
            },
            items: const [
              BottomNavigationBarItem(
                  icon: Icon(CupertinoIcons.chat_bubble), label: '消息'),
              BottomNavigationBarItem(
                  icon: Icon(CupertinoIcons.person), label: '我'),
            ]),
        tabBuilder: (_, index) => CupertinoTabView(
          builder: (_) => index == 1
              ? ProfileTabPage(
                  api: api,
                  identityCache: cache,
                  refreshSignal: refresh,
                  onLogout: () async {})
              : const CupertinoPageScaffold(child: Text('消息主页')),
        ),
      ),
    ),
    tabs,
    api,
    unread,
    refresh,
  );
}

Future<void> _finishRoute(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 550));
}

void _expectCoveredChild(Finder page) {
  expect(page, findsOneWidget);
  expect(find.byType(CupertinoTabBar), findsNothing);
  expect(
      find.descendant(of: page, matching: find.byType(SafeArea)), findsWidgets);
}

void main() {
  testWidgets(
      'all Me child routes cover Tab and return to a usable primary tab',
      (tester) async {
    final (app, tabs, _, unread, refresh) = await _harness();
    addTearDown(() {
      tabs.dispose();
      unread.dispose();
      refresh.dispose();
    });
    await tester.pumpWidget(app);
    await tester.pump();

    await tester.tap(find.byKey(const Key('profile-details-entry')));
    await _finishRoute(tester);
    _expectCoveredChild(find.byType(ProfileDetailsPage));
    await tester.binding.handlePopRoute();
    await _finishRoute(tester);
    expect(find.byType(CupertinoTabBar), findsOneWidget);

    await tester.tap(find.byKey(const Key('profile-qr-entry')));
    await _finishRoute(tester);
    _expectCoveredChild(find.byType(MyQrCodePage));
    await tester.binding.handlePopRoute();
    await _finishRoute(tester);

    await tester.tap(find.text('点钻'));
    await _finishRoute(tester);
    _expectCoveredChild(find.byType(CaibiPage));
    await tester.tap(find.byKey(const Key('caibi-all-bills-entry')));
    await _finishRoute(tester);
    _expectCoveredChild(find.byType(LedgerListPage));
    await tester.binding.handlePopRoute();
    await _finishRoute(tester);
    await tester.binding.handlePopRoute();
    await _finishRoute(tester);

    await tester.tap(find.text('钱包'));
    await _finishRoute(tester);
    _expectCoveredChild(find.byType(WalletPage));
    await tester.binding.handlePopRoute();
    await _finishRoute(tester);

    await tester.tap(find.text('设置'));
    await _finishRoute(tester);
    _expectCoveredChild(find.byType(SettingsPage));
    await tester.tap(find.text('账号与隐私'));
    await _finishRoute(tester);
    _expectCoveredChild(find.byType(AccountPrivacyPage));
    await tester.binding.handlePopRoute();
    await _finishRoute(tester);
    await tester.binding.handlePopRoute();
    await _finishRoute(tester);

    tabs.index = 0;
    await tester.pump();
    expect(find.text('消息主页'), findsOneWidget);
  });

  testWidgets('nested invitation route and own Moments are root children',
      (tester) async {
    final (app, tabs, _, unread, refresh) = await _harness();
    addTearDown(() {
      tabs.dispose();
      unread.dispose();
      refresh.dispose();
    });
    await tester.pumpWidget(app);
    await tester.pump();
    await tester.tap(find.byKey(const Key('profile-details-entry')));
    await _finishRoute(tester);
    await tester.tap(find.byKey(const Key('profile-invite-entry')));
    await _finishRoute(tester);
    _expectCoveredChild(find.byType(InviteCodePage));
    await tester.binding.handlePopRoute();
    await _finishRoute(tester);
    await tester.binding.handlePopRoute();
    await _finishRoute(tester);

    await tester.tap(find.text('朋友圈'));
    await _finishRoute(tester);
    _expectCoveredChild(find.byType(PersonalMomentsPage));
    final moments =
        tester.widget<PersonalMomentsPage>(find.byType(PersonalMomentsPage));
    expect(moments.publishedOnly, isTrue);
    expect(moments.userId, 'self');
    unread.value = 0;
    moments.onNotificationsChanged?.call();
    await _finishRoute(tester);
    await tester.binding.handlePopRoute();
    await _finishRoute(tester);
    expect(find.byKey(const Key('profile-moments-unread-badge')), findsNothing);
  });

  testWidgets('Me child supports visible back button and edge swipe',
      (tester) async {
    final (app, tabs, _, unread, refresh) = await _harness();
    addTearDown(() {
      tabs.dispose();
      unread.dispose();
      refresh.dispose();
    });
    await tester.pumpWidget(app);
    await tester.pump();
    await tester.tap(find.byKey(const Key('profile-details-entry')));
    await _finishRoute(tester);
    expect(find.byType(CupertinoNavigationBarBackButton), findsOneWidget);
    await tester.tap(find.byType(CupertinoNavigationBarBackButton));
    await _finishRoute(tester);
    expect(find.byType(CupertinoTabBar), findsOneWidget);

    await tester.tap(find.byKey(const Key('profile-details-entry')));
    await _finishRoute(tester);
    final route =
        ModalRoute.of(tester.element(find.byType(ProfileDetailsPage)));
    expect(route, isA<CupertinoPageRoute>());
    expect((route! as CupertinoPageRoute).popGestureEnabled, isTrue);
    final gesture = await tester.startGesture(const Offset(2, 360));
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(400, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await _finishRoute(tester);
    expect(find.byType(ProfileDetailsPage), findsNothing);
    expect(find.byType(CupertinoTabBar), findsOneWidget);
  });

  testWidgets('interaction badge refreshes independently on Me tab entry',
      (tester) async {
    final (app, tabs, _, unread, refresh) = await _harness();
    addTearDown(() {
      tabs.dispose();
      unread.dispose();
      refresh.dispose();
    });
    await tester.pumpWidget(app);
    await _finishRoute(tester);
    await tester.pump();
    expect(
        find.byKey(const Key('profile-moments-unread-badge')), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    unread.value = 0;
    refresh.value++;
    await _finishRoute(tester);
    await tester.pump();
    expect(find.byKey(const Key('profile-moments-unread-badge')), findsNothing);
  });

  testWidgets('Me interaction badge refreshes when app resumes',
      (tester) async {
    final calls = ValueNotifier<int>(0);
    final (app, tabs, _, unread, refresh) = await _harness(unreadCalls: calls);
    addTearDown(() {
      calls.dispose();
      tabs.dispose();
      unread.dispose();
      refresh.dispose();
    });
    await tester.pumpWidget(app);
    await _finishRoute(tester);
    expect(find.text('3'), findsOneWidget);
    final before = calls.value;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    unread.value = 4;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _finishRoute(tester);
    expect(calls.value, greaterThan(before));
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('Me interaction badge polls after one minute only while visible',
      (tester) async {
    final calls = ValueNotifier<int>(0);
    final (app, tabs, _, unread, refresh) = await _harness(unreadCalls: calls);
    addTearDown(() {
      calls.dispose();
      tabs.dispose();
      unread.dispose();
      refresh.dispose();
    });
    await tester.pumpWidget(app);
    await _finishRoute(tester);
    final baseline = calls.value;
    unread.value = 5;
    await tester.pump(const Duration(seconds: 59));
    await tester.pump();
    expect(calls.value, baseline);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(calls.value, baseline + 1);
    expect(find.text('5'), findsOneWidget);

    await tester.tap(find.byKey(const Key('profile-details-entry')));
    await _finishRoute(tester);
    unread.value = 6;
    final coveredCalls = calls.value;
    await tester.pump(const Duration(minutes: 1));
    await tester.pump();
    expect(calls.value, coveredCalls);

    await tester.binding.handlePopRoute();
    await _finishRoute(tester);
    tabs.index = 0;
    await tester.pump();
    unread.value = 7;
    final otherTabCalls = calls.value;
    await tester.pump(const Duration(minutes: 1));
    await tester.pump();
    expect(calls.value, otherTabCalls);
  });

  testWidgets('bad identity lookup leaves Me visible without a stale route',
      (tester) async {
    final (app, tabs, _, unread, refresh) = await _harness(token: 'h.???.s');
    addTearDown(() {
      tabs.dispose();
      unread.dispose();
      refresh.dispose();
    });
    await tester.pumpWidget(app);
    await tester.pump();
    await tester.tap(find.text('朋友圈'));
    await tester.pump();
    expect(find.byType(PersonalMomentsPage), findsNothing);
    expect(find.byType(CupertinoTabBar), findsOneWidget);
  });
}
