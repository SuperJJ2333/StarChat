import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/screen_capture_protection.dart';

/// Task E：屏幕捕获保护的 Dart 侧契约。
///
/// 只测试**可验证**的能力：
/// - 原生安全窗口由 lease 引用计数驱动（第一个开启、归零才关闭）；
/// - 释放幂等，重复释放不会让计数变负；
/// - 平台通道不可用时静默降级（能力缺失不得让 UI 崩溃）；
/// - 平台事件（正在录屏 / 系统截图已完成）驱动状态与销毁信号；
/// - 原生源码必须真的设置 FLAG_SECURE，且不申请相册权限/不上传内容。
void main() {
  group('ScreenCaptureProtection 租约', () {
    test('第一个租约开启安全窗口，归零才关闭', () async {
      final calls = <String>[];
      final protection =
          ScreenCaptureProtection(invoker: (method) async => calls.add(method));
      addTearDown(protection.dispose);

      expect(protection.leaseCount, 0);
      final first = await protection.acquire();
      expect(calls, ['acquireSecure']);
      final second = await protection.acquire();
      expect(calls, ['acquireSecure'], reason: '第二个租约不重复开关');
      expect(protection.leaseCount, 2);

      await first.release();
      expect(calls, ['acquireSecure'], reason: '仍有租约 → 保持开启');
      expect(protection.leaseCount, 1);
      await second.release();
      expect(calls, ['acquireSecure', 'releaseSecure']);
      expect(protection.leaseCount, 0);
    });

    test('release 幂等：重复释放不会让计数变负或重复关闭', () async {
      final calls = <String>[];
      final protection =
          ScreenCaptureProtection(invoker: (method) async => calls.add(method));
      addTearDown(protection.dispose);

      final lease = await protection.acquire();
      await lease.release();
      await lease.release();
      await lease.release();
      expect(calls, ['acquireSecure', 'releaseSecure']);
      expect(protection.leaseCount, 0);
    });

    test('releaseAll 全量释放且可重复调用', () async {
      final calls = <String>[];
      final protection =
          ScreenCaptureProtection(invoker: (method) async => calls.add(method));
      addTearDown(protection.dispose);

      await protection.acquire();
      await protection.acquire();
      await protection.releaseAll();
      expect(calls, ['acquireSecure', 'releaseSecure']);
      await protection.releaseAll();
      expect(calls, ['acquireSecure', 'releaseSecure'],
          reason: '没有租约时不得再调用原生');
    });

    test('reassert 只在仍有租约时重申安全窗口（Activity 重建兜底）', () async {
      final calls = <String>[];
      final protection =
          ScreenCaptureProtection(invoker: (method) async => calls.add(method));
      addTearDown(protection.dispose);

      await protection.reassert();
      expect(calls, isEmpty, reason: '无租约时不必重申');
      final lease = await protection.acquire();
      await protection.reassert();
      expect(calls, ['acquireSecure', 'reassertSecure']);
      await lease.release();
    });

    test('平台通道异常时静默降级（不抛错、不影响计数）', () async {
      final protection = ScreenCaptureProtection(
          invoker: (method) async => throw StateError('MissingPlugin: $method'));
      addTearDown(protection.dispose);
      final lease = await protection.acquire();
      expect(protection.leaseCount, 1);
      await protection.reassert();
      await lease.release();
      expect(protection.leaseCount, 0);
    });

    test('dispose 后再申请不会残留租约', () async {
      final calls = <String>[];
      final protection =
          ScreenCaptureProtection(invoker: (method) async => calls.add(method));
      await protection.acquire();
      await protection.dispose();
      expect(protection.leaseCount, 0);
      expect(calls, ['acquireSecure']);
    });
  });

  group('平台事件', () {
    test('captureState 驱动 captureActive，screenshot 驱动销毁流', () async {
      final controller = StreamController<Object?>.broadcast();
      final protection = ScreenCaptureProtection(
        invoker: (method) async {},
        captureEvents: controller.stream,
      );
      addTearDown(() async {
        await protection.dispose();
        await controller.close();
      });
      final screenshots = <void>[];
      final subscription =
          protection.screenshots.listen((_) => screenshots.add(null));

      expect(protection.captureActive.value, isFalse);
      controller.add({'type': 'captureState', 'active': true});
      await Future<void>.delayed(Duration.zero);
      expect(protection.captureActive.value, isTrue);

      controller.add({'type': 'screenshot'});
      await Future<void>.delayed(Duration.zero);
      expect(screenshots, hasLength(1));

      controller.add({'type': 'captureState', 'active': false});
      await Future<void>.delayed(Duration.zero);
      expect(protection.captureActive.value, isFalse);

      // 无法识别的载荷被忽略（原生升版不得让 Dart 崩溃）。
      controller.add('unexpected');
      controller.add({'type': 'unknown'});
      await Future<void>.delayed(Duration.zero);
      expect(protection.captureActive.value, isFalse);
      await subscription.cancel();
    });
  });

  group('原生源码契约', () {
    test('Android 用 FLAG_SECURE + lease 计数（不依赖单一开关）', () {
      final source = File(
              'android/app/src/main/kotlin/com/liuhetong/mobile/MainActivity.kt')
          .readAsStringSync();
      expect(source, contains('FLAG_SECURE'));
      expect(source, contains('addFlags'));
      expect(source, contains('clearFlags'));
      expect(source, contains('secureLeaseCount'));
      // 计数归零才清除；重申只重新应用。
      expect(source, contains('releaseAllSecure'));
      expect(source, contains('reassertSecure'));
      expect(source, contains('chatflow/screen_security'));
      expect(source, contains('chatflow/screen_capture'));
      // 绝不触碰相册/存储权限。
      expect(source, isNot(contains('READ_MEDIA_IMAGES')));
      expect(source, isNot(contains('MediaStore')));
    });

    test('iOS 只上报捕获状态与截图通知，不声称阻止截图、不读取相册', () {
      final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      expect(source, contains('chatflow/screen_capture'));
      expect(source, contains('chatflow/screen_security'));
      expect(source, contains('isCaptured'));
      expect(source, contains('sceneCaptureState'));
      expect(source, contains('userDidTakeScreenshotNotification'));
      expect(source, contains('capturedDidChangeNotification'));
      // 没有官方阻止 API：不得伪造“已阻止”。
      expect(source, isNot(contains('PHPhotoLibrary')));
      expect(source, isNot(contains('UIImageWriteToSavedPhotosAlbum')));
    });
  });
}
