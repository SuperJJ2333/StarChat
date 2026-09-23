import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_image_editor.dart';
import 'package:liuhetong_mobile/features/profile/avatar_source.dart';
import 'package:liuhetong_mobile/features/matrix/image_picker_page.dart';

void main() {
  testWidgets(
      'avatar source uses app gallery and cancellation leaves no candidate',
      (tester) async {
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel, (call) async => call.method == 'notify' ? true : 0);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    BuildContext? owner;
    await tester.pumpWidget(CupertinoApp(home: Builder(builder: (context) {
      owner = context;
      return const SizedBox();
    })));
    final operation = GalleryAvatarSource(contextProvider: () => owner)
        .selectCropAndCompress();
    await tester.pumpAndSettle();
    final picker = tester.widget<ImagePickerPage>(find.byType(ImagePickerPage));
    expect(picker.photosOnly, isTrue);
    expect(picker.staticImagesOnly, isTrue);
    expect(picker.maxCount, 1);
    Navigator.of(tester.element(find.byType(ImagePickerPage))).pop();
    await tester.pumpAndSettle();
    expect(await operation, isNull);
  });
  testWidgets('shared album crop upload persists the new canonical avatar',
      (tester) async {
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel, (call) async => call.method == 'notify' ? true : 0);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final bytes = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 64, 48),
          Paint()..color = CupertinoColors.systemBlue);
      final picture = recorder.endRecording();
      final image = await picture.toImage(64, 48);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      picture.dispose();
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;
    BuildContext? owner;
    await tester.pumpWidget(CupertinoApp(home: Builder(builder: (context) {
      owner = context;
      return const SizedBox();
    })));
    final gateway = _AvatarGateway();
    final persisted = <ProfileData>[];
    final invalidated = <String>[];
    final controller = ProfileController(
      gateway: gateway,
      avatarSource: GalleryAvatarSource(contextProvider: () => owner),
      avatarCacheIdentity: (_) => 'identity:account:alice',
      persistProfile: (profile) async => persisted.add(profile),
      invalidateAvatarCache: (key) async => invalidated.add(key),
    );
    await controller.load();
    final selecting = controller.chooseAvatar();
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(ImagePickerPage))).pop((
      photos: [
        GalleryPhoto(
            id: 'still',
            thumbnail: bytes,
            compressedBytes: () async => bytes,
            originalBytes: () async => bytes)
      ],
      original: false,
      flash: false,
    ));
    for (var i = 0;
        i < 30 && find.byKey(const Key('image-editor-done')).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    expect(
        tester
            .widget<WeChatImageEditorPage>(find.byType(WeChatImageEditorPage))
            .avatarMode,
        isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('image-editor-done')));
    for (var i = 0; i < 30 && controller.state.candidate == null; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await selecting;
    expect(controller.state.status, ProfileStatus.previewing);
    expect(controller.state.candidate!.mimeType, 'image/png');
    await controller.uploadAvatar();
    expect(gateway.uploaded, isNotNull);
    expect(controller.state.status, ProfileStatus.ready);
    expect(controller.state.candidate, isNull);
    expect(persisted.last.avatarUrl, 'https://safe/avatar?v=2');
    expect(invalidated, ['identity:account:alice']);
    await tester.pumpAndSettle();
    controller.dispose();
  });

  test('disposed owner does not open album', () async {
    expect(
        await GalleryAvatarSource(contextProvider: () => null)
            .selectCropAndCompress(),
        isNull);
  });
}

class _AvatarGateway implements ProfileGateway {
  static const profile = ProfileData(
      username: 'alice',
      nickname: 'Alice',
      maskedEmail: '',
      fallbackSeed: 'seed');
  AvatarCandidate? uploaded;
  @override
  Future<ProfileData> loadProfile() async => profile;
  @override
  Future<ProfileData> updateProfile(
          {required String nickname,
          String? signature,
          String? nudgeSuffix}) async =>
      profile;
  @override
  Future<AvatarUploadSession> createAvatarUpload(
          {required String mimeType, required int byteSize}) async =>
      const AvatarUploadSession(
          uploadId: 'upload', uploadUrl: 'https://safe/upload');
  @override
  Future<void> putAvatar(
      AvatarUploadSession session, AvatarCandidate candidate) async {
    uploaded = candidate;
  }

  @override
  Future<ProfileData> completeAvatar(String uploadId) async =>
      profile.copyWith(avatarUrl: 'https://safe/avatar?v=2');
  @override
  Future<void> cancelAvatar(String uploadId) async {}
  @override
  Future<void> deleteAvatar() async {}
}
