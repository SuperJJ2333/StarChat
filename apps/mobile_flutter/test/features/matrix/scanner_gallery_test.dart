import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';
import 'package:liuhetong_mobile/features/matrix/image_picker_page.dart';
import 'package:photo_manager/photo_manager.dart';

import 'image_picker_page_test.dart' show FakePager, tinyPng;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('single selection describes its actual limit', () {
    final selection = GallerySelection(maxCount: 1);
    selection.toggle('first');
    expect(selection.toggle('second'), isFalse);
    expect(selection.overflowHint, '最多选择1张图片');
  });

  testWidgets('scanner picker uses single selection and recognition action',
      (tester) async {
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getPermissionState') {
        return PermissionState.authorized.index;
      }
      if (call.method == 'notify') return true;
      throw MissingPluginException();
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final photos = [
      for (final id in ['first', 'second'])
        GalleryPhoto(
          id: id,
          thumbnail: tinyPng,
          compressedBytes: () async => tinyPng,
          originalBytes: () async => tinyPng,
        )
    ];
    await tester.pumpWidget(CupertinoApp(
        home: ImagePickerPage(
      photosOnly: true,
      maxCount: 1,
      confirmLabel: '识别',
      showOriginalToggle: false,
      pagerBuilder: () => FakePager([photos]),
      albumsLoader: () async => [],
    )));
    await tester.pumpAndSettle();
    expect(find.text('识别'), findsOneWidget);
    expect(find.byKey(const Key('image-picker-original-switch')), findsNothing);
    await tester.tap(find.byKey(const Key('image-picker-check-first')));
    await tester.tap(find.byKey(const Key('image-picker-check-second')));
    await tester.pump();
    expect(find.text('识别(1)'), findsOneWidget);
    expect(find.text('最多选择1张图片'), findsOneWidget);
    await tester.tap(find.byKey(const Key('image-picker-item-second')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gallery-preview-select')));
    await tester.pump();
    expect(find.text('已选择'), findsNothing);
  });

  test(
      'photo-only queries, permission and resume stay image-only after chat cache',
      () async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'requestPermissionExtend' ||
          call.method == 'getPermissionState') {
        return PermissionState.authorized.index;
      }
      if (call.method == 'getAssetPathList') return {'data': <Object>[]};
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      GalleryAccessCache.invalidateAll();
    });
    GalleryAccessCache.invalidateAll();
    await DeviceGallerySource.loadAlbums();
    calls.clear();
    await DeviceGallerySource.loadAlbums(photosOnly: true);
    await DeviceGallerySource.pagerFor(null, photosOnly: true).ensureAccess();
    await DeviceGallerySource.permissionScopeChanged(photosOnly: true);
    expect(
        calls.where((c) => c.method == 'requestPermissionExtend'), isNotEmpty);
    expect(calls.where((c) => c.method == 'getAssetPathList'), isNotEmpty);
    for (final call in calls) {
      final args = call.arguments as Map;
      if (call.method == 'getAssetPathList') {
        expect(args['type'], RequestType.image.value);
      }
      if (call.method == 'requestPermissionExtend' ||
          call.method == 'getPermissionState') {
        expect((args['androidPermission'] as Map)['type'],
            RequestType.image.value);
      }
    }
    GalleryAccessCache.invalidateAll();
    await DeviceGallerySource.loadAlbums(photosOnly: true);
    calls.clear();
    await DeviceGallerySource.loadAlbums();
    expect(
        calls.where((c) => c.method == 'requestPermissionExtend'), isNotEmpty);
    expect(
        calls
            .where((c) => c.method == 'getAssetPathList')
            .map((c) => (c.arguments as Map)['type']),
        containsAll([RequestType.common.value, RequestType.video.value]));
  });
}
