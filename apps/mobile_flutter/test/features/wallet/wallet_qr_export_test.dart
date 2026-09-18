import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/gallery_save_access.dart';
import 'package:liuhetong_mobile/features/wallet/wallet_display.dart';
import 'package:liuhetong_mobile/features/wallet/wallet_qr_exporter.dart';

/// 需求 2/3（2026-09-18）的生产路径证据：
/// - 地址/订单码压缩只影响展示，长度不足时不做无意义截断；
/// - 「保存到本地」真实可用：Android 9- 申请存储写权限 → 真实渲染 PNG（白底静区）
///   → 写入系统相册；被拒时抛可读异常，绝不静默。
void main() {
  test('地址压缩：首 8 位 + … + 末 6 位；短值原样返回', () {
    const address = 'TA4Y62o6YC2Zsck9rZVGTvqW1AQ7X9zTnj';
    expect(compactWalletAddress(address), 'TA4Y62o6…X9zTnj');
    expect(compactWalletAddress('TQ5dK9fK2'), 'TQ5dK9fK2');
    expect(compactWalletAddress(''), '');
    expect(compactWalletCode('a' * 64), '${'a' * 10}…${'a' * 8}');
    expect(() => compactWalletAddress('x', head: 0), throwsArgumentError);
  });

  test('导出错误消息：权限被拒 → 引导系统设置；其它 → 通用可读原因', () {
    expect(walletQrExportErrorMessage(GallerySavePermissionDenied()),
        '未获得相册写入权限，请在系统设置中允许后重试');
    expect(walletQrExportErrorMessage(StateError('disk full')),
        '保存失败，请稍后重试');
    expect(walletQrExportErrorMessage(const WalletQrExportException('二维码生成失败，请稍后重试')),
        '二维码生成失败，请稍后重试');
  });

  testWidgets('生产导出器：申请相册写入权限 → 真实渲染 PNG → 写入系统相册',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    var sdk = 28;
    var granted = true;
    var permissionRequests = 0;
    Uint8List? savedImage;
    String? savedFilename;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const gallery = MethodChannel('chatflow/gallery');
    const permissions =
        MethodChannel('flutter.baseflow.com/permissions/methods');
    const photoManager = MethodChannel('com.fluttercandies/photo_manager');
    messenger.setMockMethodCallHandler(gallery, (_) async => sdk);
    messenger.setMockMethodCallHandler(permissions, (call) async {
      permissionRequests++;
      return {
        for (final permission in call.arguments as List)
          permission: granted ? 1 : 0
      };
    });
    messenger.setMockMethodCallHandler(photoManager, (call) async {
      if (call.method == 'saveImage') {
        final arguments = call.arguments as Map;
        savedImage = arguments['image'] as Uint8List?;
        savedFilename = arguments['filename'] as String?;
        return {'id': 'asset-1', 'type': 1, 'width': 720, 'height': 720};
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(gallery, null);
      messenger.setMockMethodCallHandler(permissions, null);
      messenger.setMockMethodCallHandler(photoManager, null);
      debugDefaultTargetPlatformOverride = null;
    });
    const address = 'TA4Y62o6YC2Zsck9rZVGTvqW1AQ7X9zTnj';
    try {
      await tester.runAsync(() async {
        await const GalleryQrExporter().saveQrCode(address);
      });
      expect(permissionRequests, 1, reason: 'Android 9- 必须真实申请存储写权限');
      expect(savedFilename, startsWith('changliao-wallet-qr-'));
      final bytes = savedImage!;
      // PNG 魔数：真实渲染出的图片，不是空字节/占位。
      expect(bytes.sublist(0, 8),
          [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(bytes.length, greaterThan(1000));

      // Android 10+ 不再申请旧存储权限，但依然写相册。
      sdk = 33;
      permissionRequests = 0;
      await tester.runAsync(() async {
        await const GalleryQrExporter().saveQrCode(address);
      });
      expect(permissionRequests, 0);

      // 权限被拒：绝不静默，抛可读异常且不写相册。
      granted = false;
      sdk = 28;
      savedImage = null;
      await tester.runAsync(() async {
        await expectLater(const GalleryQrExporter().saveQrCode(address),
            throwsA(isA<GallerySavePermissionDenied>()));
      });
      expect(savedImage, isNull);
    } finally {
      // flutter_test 的收尾不变量要求测试体结束时平台覆写已复位。
      messenger.setMockMethodCallHandler(gallery, null);
      messenger.setMockMethodCallHandler(permissions, null);
      messenger.setMockMethodCallHandler(photoManager, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('空地址拒绝导出（不生成无效二维码）', (tester) async {
    await tester.runAsync(() async {
      await expectLater(
          GalleryQrExporter.renderQrPng(''),
          throwsA(isA<WalletQrExportException>()));
    });
  });
}
