import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/profile/profile_page.dart';

const _family = '👨‍👩‍👧‍👦';
const _profile = ProfileData(
    username: 'alice',
    nickname: 'Alice',
    maskedEmail: 'a***@example.test',
    fallbackSeed: 'alice',
    signature: 'hello');

final class _Gateway implements ProfileGateway {
  _Gateway({this.profile = _profile});
  ProfileData profile;
  int updates = 0;
  String? submittedNickname;
  String? submittedSignature;

  @override
  Future<ProfileData> loadProfile() async => profile;

  @override
  Future<ProfileData> updateProfile(
      {String? nickname, String? signature, String? nudgeSuffix}) async {
    updates++;
    submittedNickname = nickname;
    submittedSignature = signature;
    return profile = profile.copyWith(nickname: nickname, signature: signature);
  }

  @override
  Future<AvatarUploadSession> createAvatarUpload(
          {required String mimeType, required int byteSize}) async =>
      const AvatarUploadSession(uploadId: 'upload', uploadUrl: '/upload');
  @override
  Future<void> putAvatar(
      AvatarUploadSession session, AvatarCandidate candidate) async {}
  @override
  Future<ProfileData> completeAvatar(String uploadId) async => profile;
  @override
  Future<void> cancelAvatar(String uploadId) async {}
  @override
  Future<void> deleteAvatar() async {}
}

final class _NoAvatar implements AvatarSource {
  @override
  Future<AvatarCandidate?> selectCropAndCompress() async => null;
}

void main() {
  test('controller rejects nickname and signature beyond grapheme limits',
      () async {
    final gateway = _Gateway();
    final controller =
        ProfileController(gateway: gateway, avatarSource: _NoAvatar());
    addTearDown(controller.dispose);
    await controller.load();
    final events = <ProfileSaveEvent>[];
    final subscription = controller.saveEvents.listen(events.add);
    addTearDown(subscription.cancel);

    await controller.save(_family * 13, 'hello');
    await Future<void>.delayed(Duration.zero);
    expect(gateway.updates, 0);
    expect((events.last as ProfileSaveFailure).message, '昵称最多支持12个字符');

    await controller.save('合法昵称', _family * 21);
    await Future<void>.delayed(Duration.zero);
    expect(gateway.updates, 0);
    expect((events.last as ProfileSaveFailure).message, '个性签名最多支持20个字符');

    await controller.save('中文A1!${_family * 6}', 'A1!中文${_family * 15}');
    expect(gateway.updates, 1);
    expect(controller.state.profile?.nickname, '中文A1!${_family * 6}');
  });

  testWidgets(
      'profile editor shows live limits and one closeable overflow alert',
      (tester) async {
    final gateway = _Gateway();
    final controller =
        ProfileController(gateway: gateway, avatarSource: _NoAvatar());
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(
        CupertinoApp(home: ProfileDetailsPage(controller: controller)));

    final fields = find.byType(CupertinoTextField);
    expect(find.text('5/12'), findsOneWidget);
    expect(find.text('5/20'), findsOneWidget);

    await tester.enterText(fields.first, _family * 12);
    await tester.pump();
    expect(find.text('12/12'), findsOneWidget);
    await tester.enterText(fields.first, _family * 13);
    await tester.pumpAndSettle();
    expect(find.text('昵称最多支持12个字符'), findsOneWidget);
    expect(tester.widget<CupertinoTextField>(fields.first).controller!.text,
        _family * 12);
    await tester.enterText(fields.first, _family * 14);
    await tester.pump();
    expect(find.text('昵称最多支持12个字符'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    await tester.enterText(fields.last, '中文A1!${_family * 15}');
    await tester.pump();
    expect(find.text('20/20'), findsOneWidget);
    await tester.enterText(fields.last, '中文A1!${_family * 16}');
    await tester.pumpAndSettle();
    expect(find.text('个性签名最多支持20个字符'), findsOneWidget);
    expect(tester.widget<CupertinoTextField>(fields.last).controller!.text,
        '中文A1!${_family * 15}');
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(gateway.updates, 1);
  });

  testWidgets('over-limit preloaded draft refuses save without losing text',
      (tester) async {
    final gateway =
        _Gateway(profile: _profile.copyWith(nickname: _family * 13));
    final controller =
        ProfileController(gateway: gateway, avatarSource: _NoAvatar());
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(
        CupertinoApp(home: ProfileDetailsPage(controller: controller)));

    // A legacy value may remain visible and unchanged. Editing it to another
    // invalid value is the attempted write that must be refused.
    final field = tester
        .widget<CupertinoTextField>(find.byType(CupertinoTextField).first);
    field.controller!.text = _family * 14;
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('昵称最多支持12个字符'), findsOneWidget);
    expect(gateway.updates, 0);
    expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField).first)
            .controller!
            .text,
        _family * 14);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('昵称最多支持12个字符'), findsNothing);
  });

  testWidgets(
      'IME composition keeps its draft then rejects an over-limit commit',
      (tester) async {
    final controller = ProfileController(
        gateway: _Gateway(),
        avatarSource: _NoAvatar(),
        initialProfile: _profile);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
        CupertinoApp(home: ProfileDetailsPage(controller: controller)));
    final field = find.byType(CupertinoTextField).first;
    await tester.tap(field);
    await tester.pump();
    final composing = _family * 13;
    tester.testTextInput.updateEditingValue(TextEditingValue(
      text: composing,
      selection: TextSelection.collapsed(offset: composing.length),
      composing: TextRange(start: 0, end: composing.length),
    ));
    await tester.pump();
    expect(
        tester.widget<CupertinoTextField>(field).controller!.text, composing);
    expect(find.text('昵称最多支持12个字符'), findsNothing);

    tester.testTextInput.updateEditingValue(TextEditingValue(
      text: composing,
      selection: TextSelection.collapsed(offset: composing.length),
    ));
    await tester.pumpAndSettle();
    expect(tester.widget<CupertinoTextField>(field).controller!.text, 'Alice');
    expect(find.text('昵称最多支持12个字符'), findsOneWidget);
  });

  test('historical long fields are preserved when only the other field changes',
      () async {
    final longName = _family * 13;
    final longSignature = _family * 21;
    final gateway = _Gateway(profile: _profile.copyWith(nickname: longName));
    final controller = ProfileController(
        gateway: gateway,
        avatarSource: _NoAvatar(),
        initialProfile: gateway.profile);
    addTearDown(controller.dispose);

    await controller.save(longName, '新签名');
    expect(gateway.updates, 1);
    expect(gateway.submittedNickname, isNull);
    expect(gateway.submittedSignature, '新签名');
    expect(controller.state.profile?.nickname, longName);

    final otherGateway =
        _Gateway(profile: _profile.copyWith(signature: longSignature));
    final otherController = ProfileController(
        gateway: otherGateway,
        avatarSource: _NoAvatar(),
        initialProfile: otherGateway.profile);
    addTearDown(otherController.dispose);
    await otherController.save('新昵称', longSignature);
    expect(otherGateway.updates, 1);
    expect(otherGateway.submittedNickname, '新昵称');
    expect(otherGateway.submittedSignature, isNull);
    expect(otherController.state.profile?.signature, longSignature);
  });
}
