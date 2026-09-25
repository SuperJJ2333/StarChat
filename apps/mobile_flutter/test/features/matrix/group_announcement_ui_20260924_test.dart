import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_page.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_service.dart';
import 'package:liuhetong_mobile/features/matrix/image_picker_page.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
      'announcement editor has one continuous text field and album icon',
      (tester) async {
    final service = _AnnouncementService()
      ..announcement = const GroupAnnouncement([
        AnnouncementBlock.text('第一段'),
        AnnouncementBlock.text('第二段'),
      ]);
    await tester.pumpWidget(
        CupertinoApp(home: GroupAnnouncementPage(service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pump();

    final fields = find.byType(CupertinoTextField);
    expect(fields, findsOneWidget);
    expect(tester.widget<CupertinoTextField>(fields).controller!.text,
        '第一段\n\n第二段');
    expect(tester.widget<CupertinoTextField>(fields).minLines,
        greaterThanOrEqualTo(8));
    expect(find.text('添加文字'), findsNothing);
    expect(
        tester
            .widget<CupertinoButton>(
                find.byKey(const Key('group-announcement-add-image')))
            .onPressed,
        isNotNull);
    await tester.tap(find.byKey(const Key('group-announcement-add-image')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('图片读取失败，请重试'), findsNothing);
    final album = tester.widget<ImagePickerPage>(find.byType(ImagePickerPage));
    expect(album.photosOnly, isTrue);
    expect(album.staticImagesOnly, isFalse);
    expect(album.maxCount, 1);
  });

  testWidgets('announcement album keeps GIF bytes and GIF filename',
      (tester) async {
    final gif = base64Decode(
        'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');
    final service = _AnnouncementService();
    await tester.pumpWidget(
        CupertinoApp(home: GroupAnnouncementPage(service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('group-announcement-add-image')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final album = find.byType(ImagePickerPage);
    expect(tester.widget<ImagePickerPage>(album).photosOnly, isTrue);
    expect(tester.widget<ImagePickerPage>(album).staticImagesOnly, isFalse);
    Navigator.of(tester.element(album)).pop((
      photos: [
        GalleryPhoto(
            id: 'gif',
            thumbnail: gif,
            mimeType: 'image/gif',
            compressedBytes: () async => gif,
            originalBytes: () async => gif)
      ],
      original: false,
      flash: false
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();
    expect(service.announcement.blocks.single.fileName, '公告图片.gif');
    expect(service.announcement.blocks.single.localBytes, gif);
  });

  testWidgets(
      'announcement banner is pale yellow and dismisses until next post',
      (tester) async {
    final service = _AnnouncementService()
      ..announcement = GroupAnnouncement(const [AnnouncementBlock.text('本次公告')],
          publishedAt: DateTime(2026, 9, 24, 8));
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementBanner(
            service: service, dismissalScope: 'account:room')));
    await tester.pumpAndSettle();
    expect(find.text('本次公告'), findsOneWidget);
    final banner = tester
        .widget<Container>(find.byKey(const Key('group-announcement-banner')));
    expect((banner.decoration as BoxDecoration).color, const Color(0xFFFFF8E5));
    await tester.tap(find.byTooltip('不再提醒'));
    await tester.pumpAndSettle();
    expect(find.text('本次公告'), findsNothing);

    // A page replacement simulates leaving and reopening the room.
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementBanner(
            service: service, dismissalScope: 'account:room')));
    await tester.pumpAndSettle();
    expect(find.text('本次公告'), findsNothing);

    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementBanner(
            service: service, dismissalScope: 'other-account:room')));
    await tester.pumpAndSettle();
    expect(find.text('本次公告'), findsOneWidget);
    await tester.pumpWidget(CupertinoApp(
        home: GroupAnnouncementBanner(
            service: service, dismissalScope: 'account:room')));
    await tester.pumpAndSettle();
    expect(find.text('本次公告'), findsNothing);

    service.announcement = GroupAnnouncement(
        const [AnnouncementBlock.text('下次公告')],
        publishedAt: DateTime(2026, 9, 24, 9));
    service.updates.add(null);
    await tester.pumpAndSettle();
    expect(find.text('下次公告'), findsOneWidget);
  });

  testWidgets('empty announcement has no notice or dismiss action',
      (tester) async {
    final service = _AnnouncementService();
    await tester.pumpWidget(
        CupertinoApp(home: GroupAnnouncementBanner(service: service)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('group-announcement-banner')), findsNothing);
    expect(find.byTooltip('不再提醒'), findsNothing);
  });
}

final class _AnnouncementService implements GroupAnnouncementService {
  final updates = StreamController<void>.broadcast();
  GroupAnnouncement announcement = const GroupAnnouncement([]);

  @override
  bool get canEdit => true;

  @override
  Stream<void> get changes => updates.stream;

  @override
  Future<GroupAnnouncement> load() async => announcement;

  @override
  Future<void> save(GroupAnnouncement value) async {
    announcement = value;
    updates.add(null);
  }

  @override
  Future<Uint8List> loadImage(String eventId) async => Uint8List(0);

  @override
  Future<String> uploadImage(Uint8List bytes, String name) async => 'image';
}
