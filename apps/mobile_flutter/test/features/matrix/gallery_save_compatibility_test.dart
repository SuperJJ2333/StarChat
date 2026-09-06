import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';
import 'package:liuhetong_mobile/core/gallery_save_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('仅旧 Android 请求存储写权限；拒绝时不继续保存', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    var sdk = 28;
    var granted = true;
    var requests = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const gallery = MethodChannel('chatflow/gallery');
    const permissions =
        MethodChannel('flutter.baseflow.com/permissions/methods');
    messenger.setMockMethodCallHandler(gallery, (_) async => sdk);
    messenger.setMockMethodCallHandler(permissions, (call) async {
      requests++;
      return {
        for (final permission in call.arguments as List)
          permission: granted ? 1 : 0
      };
    });
    try {
      await ensureGallerySaveAccess();
      expect(requests, 1);
      sdk = 33;
      await ensureGallerySaveAccess();
      expect(requests, 1);
      sdk = 28;
      granted = false;
      await expectLater(ensureGallerySaveAccess(),
          throwsA(isA<GallerySavePermissionDenied>()));
      expect(gallerySaveErrorMessage(StateError('disk full')), '保存失败，请稍后重试');
    } finally {
      messenger.setMockMethodCallHandler(gallery, null);
      messenger.setMockMethodCallHandler(permissions, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });
  test('Android 9 相册写入权限必须声明且仅限旧系统', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final permission =
        RegExp(r'<uses-permission[^>]*WRITE_EXTERNAL_STORAGE[^>]*/>')
            .firstMatch(manifest)!
            .group(0)!;
    expect(permission, contains('android:maxSdkVersion="28"'));
    expect(permission, isNot(contains('tools:node="remove"')));
  });
  test('相册查询不排除宽高缺失的视频', () async {
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    final options = <Map>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAssetPathList') {
        options.add((call.arguments as Map)['option'] as Map);
        return {'data': []};
      }
      return 1;
    });
    GalleryAccessCache.shared.invalidate();
    await GalleryAccessCache.shared.ensurePermission(() async => true);
    await DeviceGallerySource.loadAlbums();
    expect(options, isNotEmpty);
    expect(options.first['child']['video']['size']['ignoreSize'], isTrue);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    GalleryAccessCache.shared.invalidate();
  });
}
