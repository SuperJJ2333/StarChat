import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/profile/profile_avatar_page.dart';
import 'package:liuhetong_mobile/features/profile/profile_page.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';

const profile = ProfileData(
    username: 'alice',
    nickname: 'Alice',
    maskedEmail: 'al***@example.test',
    fallbackSeed: 'seed',
    signature: 'hello',
    nudgeSuffix: '拍了拍我');

final class FakeProfileGateway implements ProfileGateway {
  ProfileData loadedProfile = profile;
  int puts = 0;
  bool failPut = false;
  bool deleted = false;
  @override
  Future<ProfileData> loadProfile() async => loadedProfile;
  @override
  Future<ProfileData> updateProfile(
          {required String nickname,
          String? signature,
          String? nudgeSuffix}) async =>
      profile.copyWith(
          nickname: nickname, signature: signature, nudgeSuffix: nudgeSuffix);
  @override
  Future<AvatarUploadSession> createAvatarUpload(
          {required String mimeType, required int byteSize}) async =>
      const AvatarUploadSession(uploadId: 'upload-1', uploadUrl: '/upload');
  @override
  Future<void> putAvatar(
      AvatarUploadSession session, AvatarCandidate candidate) async {
    puts++;
    if (failPut) throw Exception('network');
  }

  @override
  Future<ProfileData> completeAvatar(String uploadId) async =>
      profile.copyWith(avatarUrl: 'https://signed/avatar');
  @override
  Future<void> cancelAvatar(String uploadId) async {}
  @override
  Future<void> deleteAvatar() async {
    deleted = true;
  }
}

final class FakeAvatarSource implements AvatarSource {
  FakeAvatarSource({this.error});
  final Object? error;
  int calls = 0;
  @override
  Future<AvatarCandidate?> selectCropAndCompress() async {
    calls++;
    if (error != null) throw error!;
    return AvatarCandidate(
        bytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
        mimeType: 'image/png');
  }
}

void main() {
  test('loads caches and modifies authoritative profile', () async {
    final c = ProfileController(
        gateway: FakeProfileGateway(), avatarSource: FakeAvatarSource());
    await c.load();
    expect(c.state.profile, profile);
    await c.save('Alice Chen', 'new');
    expect(c.state.profile!.nickname, 'Alice Chen');
    expect(c.state.profile!.signature, 'new');
  });
  test('permission denial becomes an inline settings hint', () async {
    final c = ProfileController(
        gateway: FakeProfileGateway(),
        avatarSource: FakeAvatarSource(error: Exception('permission')));
    await c.load();
    await c.chooseAvatar();
    expect(c.state.status, ProfileStatus.failed);
    expect(c.state.message, contains('系统设置'));
  });
  test(
      'select crop compress preview upload progress failure retry and default restoration',
      () async {
    final gateway = FakeProfileGateway()..failPut = true;
    final source = FakeAvatarSource();
    final c = ProfileController(gateway: gateway, avatarSource: source);
    await c.load();
    await c.chooseAvatar();
    expect(source.calls, 1);
    expect(c.state.status, ProfileStatus.previewing);
    await c.uploadAvatar();
    expect(c.state.status, ProfileStatus.failed);
    gateway.failPut = false;
    await c.retryAvatar();
    expect(gateway.puts, 2);
    expect(c.state.profile!.avatarUrl, 'https://signed/avatar');
    await c.restoreDefaultAvatar();
    expect(gateway.deleted, isTrue);
    expect(c.state.profile!.avatarUrl, isNull);
  });
  test('successful avatar changes precisely invalidate that user cache',
      () async {
    final invalidated = <String>[];
    final c = ProfileController(
      gateway: FakeProfileGateway(),
      avatarSource: FakeAvatarSource(),
      invalidateAvatarCache: (userId) async => invalidated.add(userId),
    );
    await c.load();
    await c.chooseAvatar();
    await c.uploadAvatar();
    await c.restoreDefaultAvatar();

    expect(invalidated, ['seed', 'seed']);
  });

  test('cancelled preview never creates a remote upload', () async {
    final gateway = FakeProfileGateway();
    final c =
        ProfileController(gateway: gateway, avatarSource: FakeAvatarSource());
    await c.load();
    await c.chooseAvatar();
    c.cancelPreview();
    await c.uploadAvatar();
    expect(gateway.puts, 0);
    expect(c.state.status, ProfileStatus.ready);
  });
  testWidgets('me page exposes identity and five menu rows with personal information',
      (tester) async {
    var momentsOpened = false;
    var caibiOpened = false;
    var walletOpened = false;
    final controller = ProfileController(
        gateway: FakeProfileGateway(), avatarSource: FakeAvatarSource());
    await tester.pumpWidget(CupertinoApp(
        home: ProfileExperiencePage(
            onInvite: () {},
            onQrCode: () {},
            controller: controller,
            onMoments: () => momentsOpened = true,
            onCaibi: () => caibiOpened = true,
            onWallet: () => walletOpened = true,
            onSettings: () {})));
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsWidgets);
    final identityName = tester.widgetList<Text>(find.text('Alice')).first;
    expect(identityName.style?.color, isNot(WeChatColors.brandPrimary));
    expect(find.textContaining('畅聊号：alice'), findsOneWidget);
    expect(find.text('hello'), findsWidgets);
    expect(find.text('朋友圈'), findsOneWidget);
    expect(find.text('钱包'), findsWidgets);
    expect(find.text('红包'), findsNothing, reason: '“我”页不再提供红包入口');
    // “二维码”入口：身份卡右上角（微信“我的二维码”样式）。
    expect(find.byKey(const Key('profile-qr-entry')), findsOneWidget);
    expect(find.byKey(const Key('profile-invite-entry')), findsNothing);
    expect(find.byKey(const Key('profile-details-entry')), findsOneWidget);
    await tester.tap(find.text('朋友圈'));
    await tester.tap(find.text('点钻'));
    await tester.tap(find.text('钱包'));
    expect(momentsOpened, isTrue);
    expect(caibiOpened, isTrue);
    expect(walletOpened, isTrue);
    expect(find.text('设置'), findsOneWidget);
    final settingsLabel = tester.widget<Text>(find.text('设置'));
    expect(settingsLabel.style?.color, isNot(WeChatColors.brandPrimary));
    expect(find.text('退出登录'), findsNothing);
    expect(find.byType(CupertinoTextField), findsNothing);
  });

  testWidgets(
      'both personal information entries retain invitation and profile saving',
      (tester) async {
    var invites = 0;
    final controller = ProfileController(
        gateway: FakeProfileGateway(), avatarSource: FakeAvatarSource());
    await tester.pumpWidget(CupertinoApp(
        home: ProfileExperiencePage(
      controller: controller,
      onInvite: () => invites++,
      onMoments: () {},
      onCaibi: () {},
      onWallet: () {},
      onSettings: () {},
    )));
    await tester.pumpAndSettle();
    for (final entry in ['profile-identity-card', 'profile-details-entry']) {
      await tester.tap(find.byKey(Key(entry)));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileDetailsPage), findsOneWidget);
      final invitation = find.byKey(const Key('profile-invite-entry'));
      final fields = find.byType(CupertinoTextField);
      expect(invitation, findsOneWidget);
      expect(tester.getTopLeft(invitation).dy,
          lessThan(tester.getTopLeft(fields.first).dy));
      await tester.tap(invitation);
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(ProfileDetailsPage))).pop();
      await tester.pumpAndSettle();
    }
    expect(invites, 2);
    await tester.tap(find.byKey(const Key('profile-details-entry')));
    await tester.pumpAndSettle();
    final fields = find.byType(CupertinoTextField);
    await tester.enterText(fields.first, 'Alice Updated');
    await tester.enterText(fields.last, 'Updated signature');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(controller.state.profile!.nickname, 'Alice Updated');
    expect(controller.state.profile!.signature, 'Updated signature');
  });

  testWidgets(
      'profile fields align entered values right and empty placeholders left',
      (tester) async {
    final controller = ProfileController(
        gateway: FakeProfileGateway(), avatarSource: FakeAvatarSource());
    await controller.load();
    await tester.pumpWidget(
        CupertinoApp(home: ProfileDetailsPage(controller: controller)));
    final fields = find.byType(CupertinoTextField);
    for (final field in [fields.first, fields.last]) {
      expect(
          tester.widget<CupertinoTextField>(field).textAlign, TextAlign.right);
      await tester.enterText(field, '');
      await tester.pump();
      expect(
          tester.widget<CupertinoTextField>(field).textAlign, TextAlign.left);
      await tester.enterText(field, 'new');
      await tester.pump();
      expect(
          tester.widget<CupertinoTextField>(field).textAlign, TextAlign.right);
    }
  });

  testWidgets('profile avatar opens a dedicated preview and upload flow',
      (tester) async {
    final controller = ProfileController(
      gateway: FakeProfileGateway(),
      avatarSource: FakeAvatarSource(),
    );
    await controller.load();

    await tester.pumpWidget(
      CupertinoApp(home: ProfileDetailsPage(controller: controller)),
    );
    await tester.tap(find.text('头像'));
    await tester.pumpAndSettle();

    expect(find.byType(ProfileAvatarPage), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-avatar-choose')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-avatar-preview')), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-avatar-upload')));
    await tester.pumpAndSettle();

    expect(controller.state.profile!.avatarUrl, 'https://signed/avatar');
  });
  test('persists an explicit empty nudge suffix as a clear operation',
      () async {
    final c = ProfileController(
        gateway: FakeProfileGateway(), avatarSource: FakeAvatarSource());
    await c.load();
    await c.save('Alice', 'hello', nudgeSuffix: '');
    expect(c.state.profile!.nudgeSuffix, isNull);
  });

  testWidgets('personal information exposes a saved nudge setting',
      (tester) async {
    final gateway = FakeProfileGateway();
    final controller = ProfileController(
      gateway: gateway,
      avatarSource: FakeAvatarSource(),
    );
    await controller.load();
    await tester.pumpWidget(
      CupertinoApp(home: ProfileDetailsPage(controller: controller)),
    );
    expect(find.byKey(const Key('profile-nudge-row')), findsOneWidget);
    expect(find.text('拍了拍我'), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-nudge-row')));
    await tester.pumpAndSettle();
    expect(find.text('设置拍一拍'), findsOneWidget);
    final field = find.byKey(const Key('profile-nudge-field'));
    await tester.enterText(field, '拍了拍我一下');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(controller.state.profile!.nudgeSuffix, '拍了拍我一下');
    expect(find.text('拍了拍我一下'), findsOneWidget);
  });

  testWidgets(
      'me page identity card uses the shared avatar renderer for an uploaded avatar',
      (tester) async {
    const uploadedAvatarUrl = 'https://media.example.test/avatar.png?v=2';
    final gateway = FakeProfileGateway()
      ..loadedProfile = profile.copyWith(avatarUrl: uploadedAvatarUrl);
    final controller = ProfileController(
      gateway: gateway,
      avatarSource: FakeAvatarSource(),
    );

    await tester.pumpWidget(CupertinoApp(
      home: ProfileExperiencePage(
        onInvite: () {},
        controller: controller,
        onMoments: () {},
        onCaibi: () {},
        onWallet: () {},
        onSettings: () {},
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final avatar = tester.widget<UserAvatar>(
      find.byKey(const Key('profile-identity-avatar')),
    );
    expect(avatar.avatarUrl, uploadedAvatarUrl);
    expect(avatar.size, 72);
  });
}
