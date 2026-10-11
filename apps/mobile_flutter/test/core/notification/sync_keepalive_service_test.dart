import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/sync_keepalive_service.dart';

/// BUG 2（后台/锁屏无通知）根因修复：dataSync 前台服务保活 Matrix 同步，
/// 登录会话期间常驻、退出登录停止、幂等可重入。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const locksChannel = MethodChannel('chatflow/keepalive');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(locksChannel, (_) async => true);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(locksChannel, null);
  });
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

  test('R4：看门狗不重复后台启动服务或重取锁', () async {
    final backend = _RecordingKeepAliveBackend();
    final hooks = _RecordingKeepAliveHooks();
    final service = SyncKeepAliveService(backend: backend, hooks: hooks);
    await service.ensureStarted();
    // 模拟系统静默回收后的自愈：看门狗每拍无条件重申（FGS+唤醒锁）。
    await service.runWatchdogTick();
    expect(backend.starts, 1, reason: '只能在明确生命周期恢复时重新申请');
    expect(hooks.acquires, 1, reason: '锁由原生服务生命周期管理');
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
    expect(service.locksAcquired, isFalse);
  });

  test('R4替代C05弱保活：start被拒不持锁，stop仍清理已尝试的服务', () async {
    final hooks = _RecordingKeepAliveHooks();
    final backend = _RecordingKeepAliveBackend()..failStart = true;
    final service = SyncKeepAliveService(
      backend: backend,
      hooks: hooks,
    );
    await service.ensureStarted();
    expect(service.isRunning, isFalse);
    expect(service.locksAcquired, isFalse, reason: '没有合法FGS时禁止弱保活持锁');
    await service.stop();
    // 关键断言：清理不依赖 _running——锁必释放、看门狗必取消。
    expect(hooks.acquires, 0);
    expect(backend.stops, 1);
    expect(service.locksAcquired, isFalse);
    // 停止后看门狗不再重申任何资源。
    await service.runWatchdogTick();
    expect(hooks.acquires, 0, reason: '看门狗已取消，不再取锁');
  });

  for (final response in [false, null, 'exception']) {
    test('R4：原生锁返回$response不能虚报已获取', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(locksChannel, (_) async {
        if (response == 'exception') throw PlatformException(code: 'denied');
        return response;
      });
      final service =
          SyncKeepAliveService(backend: _RecordingKeepAliveBackend());
      await service.ensureStarted();
      expect(service.isRunning, isTrue);
      expect(service.locksAcquired, isFalse);
      await service.stop();
    });
  }

  test('R4：并发启动合并，stop后迟到start不复活或取锁', () async {
    final pending = Completer<void>();
    final backend = _RecordingKeepAliveBackend()..startGate = pending;
    final hooks = _RecordingKeepAliveHooks();
    final service = SyncKeepAliveService(backend: backend, hooks: hooks);
    final starts = [service.ensureStarted(), service.ensureStarted()];
    await Future<void>.delayed(Duration.zero);
    await service.stop();
    pending.complete();
    await Future.wait(starts);
    expect(backend.starts, 1);
    expect(service.isRunning, isFalse);
    expect(service.locksAcquired, isFalse);
    expect(hooks.acquires, 0);
    await service.runWatchdogTick();
    expect(backend.starts, 1);
  });

  test('R4：原生停止通知清除实际状态且不会由看门狗重新拉起', () async {
    final backend = _RecordingKeepAliveBackend();
    final service = SyncKeepAliveService(backend: backend);
    await service.ensureStarted();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
            'chatflow/foreground_service',
            const StandardMethodCodec()
                .encodeMethodCall(const MethodCall('stopped', 'timeout')),
            (_) {});
    expect(service.isRunning, isFalse);
    expect(service.locksAcquired, isFalse);
    await service.runWatchdogTick();
    expect(backend.starts, 1);
    await service.stop();
    await service.stop();
  });

  test('R4：旧start在stop后迟到不能吞掉下一次明确前台启动', () async {
    final gate = Completer<void>();
    final backend = _RecordingKeepAliveBackend()..startGate = gate;
    final service = SyncKeepAliveService(backend: backend);
    final oldStart = service.ensureStarted();
    await Future<void>.delayed(Duration.zero);
    await service.stop();
    final resumed = service.ensureStarted();
    backend.startGate = null;
    gate.complete();
    await Future.wait([oldStart, resumed]);
    expect(service.isRunning, isTrue);
    expect(backend.starts, 2);
    await service.stop();
  });

  test('R4：锁租约到期仅清除持锁状态，前台请求可重新取锁', () async {
    final backend = _RecordingKeepAliveBackend();
    final hooks = _RecordingKeepAliveHooks();
    final service = SyncKeepAliveService(backend: backend, hooks: hooks);
    await service.ensureStarted();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
            'chatflow/foreground_service',
            const StandardMethodCodec()
                .encodeMethodCall(const MethodCall('locksReleased')),
            (_) {});
    expect(service.isRunning, isTrue);
    expect(service.isDesired, isTrue);
    expect(service.locksAcquired, isFalse);
    await service.runWatchdogTick();
    expect(hooks.acquires, 1);
    await service.ensureStarted();
    expect(service.locksAcquired, isTrue);
    expect(hooks.acquires, 2);
    expect(backend.starts, 1);
    await service.stop();
  });

  test('R4：取锁迟到遇stop必须释放且不能恢复状态', () async {
    final gate = Completer<bool>();
    final hooks = _RecordingKeepAliveHooks()..acquireGate = gate;
    final service = SyncKeepAliveService(
        backend: _RecordingKeepAliveBackend(), hooks: hooks);
    final starting = service.ensureStarted();
    await Future<void>.delayed(Duration.zero);
    await service.stop();
    gate.complete(true);
    await starting;
    expect(service.locksAcquired, isFalse);
    expect(service.isRunning, isFalse);
    expect(hooks.releases, 1);
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
  Completer<bool>? acquireGate;

  @override
  Future<bool> acquire() async {
    if (fail) throw StateError('wakelock denied');
    acquires++;
    return await acquireGate?.future ?? true;
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
  Completer<void>? startGate;

  @override
  Future<void> start({
    required int notificationId,
    required String channelTitle,
    required String title,
    required String body,
  }) async {
    if (failStart) throw StateError('foreground service start failed');
    starts++;
    await startGate?.future;
  }

  @override
  Future<void> stop() async {
    if (failStop) throw StateError('foreground service stop failed');
    stops++;
  }
}
