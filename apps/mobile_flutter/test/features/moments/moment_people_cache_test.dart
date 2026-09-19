
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/moments/moment_visibility_people_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_visibility_selection.dart';
import 'package:liuhetong_mobile/features/moments/moments_settings_page.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../wallet/manual_wallet_api_test.dart' as fixtures;

/// 微信级加载模型（2026-09-19 审计）：朋友圈「不给谁看 / 只给谁看」名单页与
/// 权限页里的排除名单，原先都只走网络 `listContacts()`，加载中与失败同形
/// （整页加载圈 / "加载失败，重试"），断网时一个好友都选不了。两页现在先用
/// 已水合的联系人投影（`ProfileRepository.contacts`）渲染，失败保留。
final class _SnapshotStore implements ProfileStore {
  _SnapshotStore(this.snapshot);
  final ProfileSnapshot? snapshot;

  @override
  Future<ProfileSnapshot?> read(String accountKey) async => snapshot;

  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {}
}

const _friend = ContactSummary(
    userId: 'u1',
    username: 'xiaohong',
    matrixUserId: '@x:example',
    nickname: '小鸿');

Future<ProfileRepository> _repository() async {
  final repository = ProfileRepository.forTesting(
      accountKey: 'matrix:@alice:example',
      store: _SnapshotStore(ProfileSnapshot(
          profile: const ProfileData(
              username: 'alice',
              nickname: 'Alice',
              maskedEmail: 'a***@example.com',
              fallbackSeed: 'alice'),
          contacts: const [_friend])));
  await repository.hydrate();
  return repository;
}

Future<BusinessApiClient> _offlineClient() async {
  final session = SecureSessionStore(fixtures.MemoryStore());
  await session.saveSession(
      accessToken: 'e30.eyJzdWIiOiJhbGljZSJ9.test',
      refreshToken: 'refresh',
      matrixUserId: '@alice:example');
  return BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: session,
      client: MockClient((request) async => throw StateError('offline')));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('可见范围名单页：断网时用本地联系人渲染「朋友」页签', (tester) async {
    final api = await _offlineClient();
    final repository = await _repository();

    await tester.pumpWidget(CupertinoApp(
        home: MomentVisibilityPeoplePage(
            api: api,
            mode: 'EXCLUDE',
            initialSelection: const MomentVisibilitySelection(
                visibility: 'EXCLUDE'),
            identityCache: repository)));
    await tester.pumpAndSettle();

    expect(find.text('标签或朋友加载失败，请检查网络后重试'), findsNothing,
        reason: '有本地联系人时不显示整页错误');
    await tester.tap(find.text('朋友'));
    await tester.pumpAndSettle();
    expect(find.text('小鸿'), findsOneWidget, reason: '断网也能从本地投影选人');
    repository.dispose();
  });

  testWidgets('权限页「不给谁看」：断网时用本地联系人渲染名单', (tester) async {
    final api = await _offlineClient();
    final repository = await _repository();

    await tester.pumpWidget(CupertinoApp(
        home: MomentsSettingsPage(api: api, identityCache: repository)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moments-excluded-people')));
    await tester.pumpAndSettle();

    expect(find.text('小鸿'), findsOneWidget);
    expect(find.text('加载失败，重试'), findsNothing,
        reason: '有本地联系人时不显示加载失败');
    repository.dispose();
  });
}
