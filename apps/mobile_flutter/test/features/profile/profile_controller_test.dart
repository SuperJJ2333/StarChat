import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/profile/profile_page.dart';

const profile = ProfileData(
    username: 'alice',
    nickname: 'Alice',
    maskedEmail: 'al***@example.test',
    fallbackSeed: 'seed',
    signature: 'hello');

final class FakeProfileGateway implements ProfileGateway {
  int puts = 0;
  bool failPut = false;
  bool deleted = false;
  @override
  Future<ProfileData> loadProfile() async => profile;
  @override
  Future<ProfileData> updateProfile(
          {required String nickname, String? signature}) async =>
      profile.copyWith(nickname: nickname, signature: signature);
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
        bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'image/jpeg');
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
  testWidgets('me page exposes identity settings and logout actions',
      (tester) async {
    var caibiOpened = false;
    var redPacketOpened = false;
    var walletOpened = false;
    final controller = ProfileController(
        gateway: FakeProfileGateway(), avatarSource: FakeAvatarSource());
    await tester.pumpWidget(CupertinoApp(
        home: ProfileExperiencePage(
            controller: controller,
            onCaibi: () => caibiOpened = true,
            onRedPacket: () => redPacketOpened = true,
            onWallet: () => walletOpened = true,
            onSettings: () {},
            onLogout: () async {})));
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsWidgets);
    expect(find.textContaining('六合通号：alice'), findsOneWidget);
    expect(find.text('hello'), findsWidgets);
    await tester.drag(find.byType(ListView), const Offset(0, -650));
    await tester.pumpAndSettle();
    expect(find.text('红包'), findsWidgets);
    expect(find.text('钱包'), findsWidgets);
    await tester.tap(find.text('彩币').at(0));
    await tester.tap(find.text('红包').at(0));
    await tester.tap(find.text('钱包').at(0));
    expect(caibiOpened, isTrue);
    expect(redPacketOpened, isTrue);
    expect(walletOpened, isTrue);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
  });
}
