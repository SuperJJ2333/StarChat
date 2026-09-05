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

  test('启动/停止联动原生唤醒锁 hooks（息屏防 CPU/WiFi 休眠）', () async {
    final hooks = _RecordingKeepAliveHooks();
    final service = SyncKeepAliveService(
        backend: _RecordingKeepAliveBackend(), hooks: hooks);
    await service.ensureStarted();
    expect(hooks.acquires, 1);
    await service.stop();
    expect(hooks.releases, 1);
  });

  test('看门狗：运行中周期性重申前台服务与唤醒锁（系统回收后自愈）', () async {
    final backend = _RecordingKeepAliveBackend();
    final hooks = _RecordingKeepAliveHooks();
    final service = SyncKeepAliveService(backend: backend, hooks: hooks);
    await service.ensureStarted();
    // 模拟系统静默回收后的自愈：看门狗每拍无条件重申（FGS+唤醒锁）。
    await service.runWatchdogTick();
    expect(backend.starts, 2, reason: '前台服务被回收后必须重申');
    expect(hooks.acquires, 2, reason: '唤醒锁幂等重取');
    expect(service.isRunning, isTrue);
  });

  test('看门狗在停止后不再重申', () async {
    final backend = _RecordingKeepAliveBackend();
    final hooks = _RecordingKeepAliveHooks();
    final service = SyncKeepAliveService(backend: backend, hooks: hooks);
    await service.ensureStarted();
    await service.stop();
    await service.runWatchdogTick();
    expect(backend.starts, 1);
    expect(hooks.acquires, 1);
  });

  test('hook 失败不阻断保活主流程', () async {
    final hooks = _RecordingKeepAliveHooks()..fail = true;
    final service = SyncKeepAliveService(
      backend: _RecordingKeepAliveBackend(),
      hooks: hooks,
    );
    await service.ensureStarted();
    expect(service.isRunning, isTrue);
  });

  test('C05：start 失败后 stop 仍释放锁并停止看门狗（资源计数归零）', () async {
    final hooks = _RecordingKeepAliveHooks();
    final service = SyncKeepAliveService(
      backend: _RecordingKeepAliveBackend()..failStart = true,
      hooks: hooks,
    );
    await service.ensureStarted();
    expect(service.isRunning, isFalse);
    expect(service.locksAcquired, isTrue, reason: '降级弱保活仍持锁（被跟踪）');
    await service.stop();
    // 关键断言：清理不依赖 _running——锁必释放、看门狗必取消。
    expect(hooks.releases, 1, reason: 'start 失败后 stop 必须释放已持有锁');
    expect(service.locksAcquired, isFalse);
    // 停止后看门狗不再重申任何资源。
    await service.runWatchdogTick();
    expect(hooks.acquires, 1, reason: '看门狗已取消，不再取锁');
  });

  test('C05：反复 start/stop 交错后锁计数平衡（无泄漏）', () async {
    final hooks = _RecordingKeepAliveHooks();
    final backend = _RecordingKeepAliveBackend();
    final service = SyncKeepAliveService(backend: backend, hooks: hooks);
    for (var i = 0; i < 3; i++) {
      await service.ensureStarted();
      await service.stop();
      if (i == 0) backend.failStart = true; // 中途注入失败路径交错。
      if (i == 1) backend.failStart = false;
    }
    expect(hooks.acquires, greaterThanOrEqualTo(hooks.releases));
    expect(service.locksAcquired, isFalse, reason: '交错后无残留持有');
    expect(service.isRunning, isFalse);
  });

  test('C05：从未启动时 stop 不取锁不触达后端（兼容既有契约）', () async {
    final hooks = _RecordingKeepAliveHooks();
    final backend = _RecordingKeepAliveBackend();
    final service = SyncKeepAliveService(backend: backend, hooks: hooks);
    await service.stop();
    expect(hooks.acquires, 0);
    expect(hooks.releases, 0);
    expect(backend.stops, 0);
  });
}

final class _RecordingKeepAliveHooks implements KeepAliveHooks {
  var acquires = 0;
  var releases = 0;
  var fail = false;

  @override
  Future<void> acquire() async {
    if (fail) throw StateError('wakelock denied');
    acquires++;
  }

  @override
  Future<void> release() async {
    if (fail) throw StateError('wakelock release denied');
    releases++;
  }
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
