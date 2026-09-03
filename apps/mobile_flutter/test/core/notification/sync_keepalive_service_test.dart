import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/sync_keepalive_service.dart';

/// BUG 2（后台/锁屏无通知）根因修复：dataSync 前台服务保活 Matrix 同步，
/// 登录会话期间常驻、退出登录停止、幂等可重入。
void main() {
  test('start 幂等：重复启动只调一次后端', () async {
    final backend = _RecordingKeepAliveBackend();
    final service = SyncKeepAliveService(backend: backend);
    await service.ensureStarted();
    await service.ensureStarted();
    await service.ensureStarted();
    expect(backend.starts, 1, reason: '常驻服务禁止重复 startForeground');
    expect(service.isRunning, isTrue);
  });

  test('stop 后可重新启动（退出登录→再登录）', () async {
    final backend = _RecordingKeepAliveBackend();
    final service = SyncKeepAliveService(backend: backend);
    await service.ensureStarted();
    await service.stop();
    expect(service.isRunning, isFalse);
    expect(backend.stops, 1);
    await service.ensureStarted();
    expect(backend.starts, 2);
    expect(service.isRunning, isTrue);
  });

  test('未启动时 stop 不触达后端', () async {
    final backend = _RecordingKeepAliveBackend();
    final service = SyncKeepAliveService(backend: backend);
    await service.stop();
    expect(backend.stops, 0);
  });

  test('start 失败可重试且不进入运行态', () async {
    final backend = _RecordingKeepAliveBackend()..failStart = true;
    final service = SyncKeepAliveService(backend: backend);
    await service.ensureStarted();
    expect(service.isRunning, isFalse);
    backend.failStart = false;
    await service.ensureStarted();
    expect(service.isRunning, isTrue);
  });

  test('stop 失败不回滚状态语义（下次 start 仍可重入）', () async {
    final backend = _RecordingKeepAliveBackend()..failStop = true;
    final service = SyncKeepAliveService(backend: backend);
    await service.ensureStarted();
    await service.stop();
    expect(service.isRunning, isFalse);
    await service.ensureStarted();
    expect(backend.starts, 2);
  });
}

final class _RecordingKeepAliveBackend implements SyncKeepAliveBackend {
  var starts = 0;
  var stops = 0;
  var failStart = false;
  var failStop = false;

  @override
  Future<void> start({
    required int notificationId,
    required String channelTitle,
    required String title,
    required String body,
  }) async {
    if (failStart) throw StateError('foreground service start failed');
    starts++;
  }

  @override
  Future<void> stop() async {
    if (failStop) throw StateError('foreground service stop failed');
    stops++;
  }
}
