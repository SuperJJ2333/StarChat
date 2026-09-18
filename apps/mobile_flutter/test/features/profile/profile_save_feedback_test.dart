import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/profile/profile_page.dart';

const _profile = ProfileData(
    username: 'alice',
    nickname: 'Alice',
    maskedEmail: 'al***@example.test',
    fallbackSeed: 'seed',
    signature: 'hello');

final class _SaveGateway implements ProfileGateway {
  _SaveGateway({this.fail = false});
  bool fail;
  int updates = 0;
  @override
  Future<ProfileData> loadProfile() async => _profile;
  @override
  Future<ProfileData> updateProfile(
      {required String nickname,
      String? signature,
      String? nudgeSuffix}) async {
    updates++;
    if (fail) throw Exception('offline');
    return _profile.copyWith(nickname: nickname, signature: signature);
  }

  @override
  Future<AvatarUploadSession> createAvatarUpload(
          {required String mimeType, required int byteSize}) async =>
      const AvatarUploadSession(uploadId: 'u', uploadUrl: '/u');
  @override
  Future<void> putAvatar(
          AvatarUploadSession session, AvatarCandidate candidate) async {}
  @override
  Future<ProfileData> completeAvatar(String uploadId) async => _profile;
  @override
  Future<void> cancelAvatar(String uploadId) async {}
  @override
  Future<void> deleteAvatar() async {}
}

final class _NoAvatarSource implements AvatarSource {
  @override
  Future<AvatarCandidate?> selectCropAndCompress() async => null;
}

void main() {
  test('BUG-05 save publishes ProfileSaveSuccess after a successful write',
      () async {
    final controller = ProfileController(
        gateway: _SaveGateway(), avatarSource: _NoAvatarSource());
    addTearDown(controller.dispose);
    final events = <ProfileSaveEvent>[];
    final subscription = controller.saveEvents.listen(events.add);
    addTearDown(subscription.cancel);

    await controller.save('Alice New', 'hello new');
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(1));
    expect(events.single, isA<ProfileSaveSuccess>());
    expect(controller.state.status, ProfileStatus.ready);
  });

  test('BUG-05 save publishes ProfileSaveFailure with the user-facing copy',
      () async {
    final controller = ProfileController(
        gateway: _SaveGateway(fail: true), avatarSource: _NoAvatarSource());
    addTearDown(controller.dispose);
    final events = <ProfileSaveEvent>[];
    final subscription = controller.saveEvents.listen(events.add);
    addTearDown(subscription.cancel);

    await controller.save('Alice New', 'hello new');
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(1));
    expect(events.single, isA<ProfileSaveFailure>());
    expect((events.single as ProfileSaveFailure).message, '资料保存失败，请重试');
    // 失败文案只走事件通道，避免内联 + 浮层重复提示。
    expect(controller.state.message, isNull);
  });

  testWidgets('BUG-05 profile details page shows 保存成功 after saving',
      (tester) async {
    final controller = ProfileController(
        gateway: _SaveGateway(), avatarSource: _NoAvatarSource());
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(CupertinoApp(
      home: ProfileDetailsPage(controller: controller),
    ));

    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('保存成功'), findsOneWidget);
  });

  testWidgets('BUG-05 profile details page shows the failure copy once',
      (tester) async {
    final controller = ProfileController(
        gateway: _SaveGateway(fail: true), avatarSource: _NoAvatarSource());
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(CupertinoApp(
      home: ProfileDetailsPage(controller: controller),
    ));

    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('资料保存失败，请重试'), findsOneWidget);
  });
}
