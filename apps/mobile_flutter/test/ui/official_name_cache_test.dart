import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/support_identity_repository.dart';
import 'package:liuhetong_mobile/ui/components/wechat_official_name.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_tile.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/profile/profile_page.dart';

class _Gateway implements SupportIdentityGateway {
  int calls = 0;
  @override
  Future<List<SupportIdentity>> lookupSupportIdentities(
      List<String> ids) async {
    calls++;
    return [
      for (final id in ids)
        SupportIdentity(
            queryId: id,
            userId: id,
            matrixUserId: null,
            badge: '官方客服',
            role: SupportRole.supportAgent)
    ];
  }
}

class _Profile implements ProfileGateway, AvatarSource {
  static const profile = ProfileData(
      username: 'staff',
      nickname: '客服本人',
      maskedEmail: '',
      fallbackSeed: 'staff');
  @override
  Future<ProfileData> loadProfile() async => profile;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('me page uses authoritative suffix after nickname',
      (tester) async {
    final repository = SupportIdentityRepository(_Gateway());
    final source = _Profile();
    final controller = ProfileController(
        gateway: source,
        avatarSource: source,
        initialProfile: _Profile.profile);
    await tester.pumpWidget(CupertinoApp(
        home: ProfileExperiencePage(
            controller: controller,
            supportIdentities: repository,
            matrixUserId: '@staff:test',
            onMoments: () {},
            onCaibi: () {},
            onWallet: () {},
            onInvite: () {},
            onSettings: () {})));
    await tester.pumpAndSettle();
    expect(find.text('@官方客服'), findsOneWidget);
    expect(find.text('客服本人'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    repository.dispose();
  });

  testWidgets(
      'moment author and comment author share verified suffix with long-name layout',
      (tester) async {
    final repository = SupportIdentityRepository(_Gateway());
    const author = MomentAuthor(
        userId: 'staff',
        username: 'staff',
        nickname: '超长超长超长超长客服昵称',
        displayName: '超长超长超长超长客服昵称');
    final item = MomentItem(
        id: 'post',
        author: author,
        text: '正文',
        images: const [],
        createdAt: DateTime(2026),
        comments: const [
          MomentCommentView(id: 'comment', text: '评论', author: author)
        ]);
    await tester.pumpWidget(CupertinoApp(
        home: SingleChildScrollView(
            child: SizedBox(
                width: 320,
                child: WeChatMomentTile(
                    item: item, supportIdentities: repository)))));
    await tester.pumpAndSettle();
    expect(find.text('@官方客服'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    repository.dispose();
  });

  testWidgets('shared name loads verified badge without page-specific polling',
      (tester) async {
    final gateway = _Gateway();
    final repository = SupportIdentityRepository(gateway);
    await tester.pumpWidget(CupertinoApp(
        home: Center(
            child: SizedBox(
                width: 220,
                child: WeChatOfficialName(
                    name: '客服本人',
                    userId: 'staff',
                    supportIdentities: repository)))));
    await tester.pumpAndSettle();
    expect(find.text('@官方客服'), findsOneWidget);
    expect(gateway.calls, 1);
    await tester.pump(const Duration(minutes: 2));
    expect(gateway.calls, 1);
    await tester.pumpWidget(const SizedBox());
    repository.dispose();
  });

  testWidgets('name and verified suffix fit narrow width with ellipsis',
      (tester) async {
    final repository = SupportIdentityRepository(_Gateway());
    await repository.warm(['staff']);
    await tester.pumpWidget(CupertinoApp(
        home: Center(
            child: SizedBox(
                width: 40,
                child: WeChatOfficialName(
                    name: '很长很长的备注名称',
                    userId: 'staff',
                    supportIdentities: repository)))));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    repository.dispose();
  });
}
