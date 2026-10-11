import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'foreground_service_arbiter.dart';
import 'notification_diagnostics.dart';

/// Android 消息同步保活。运行态只在原生确认 FGS 成功后建立；
/// 系统停止/超时时由原生先释放锁，再尽力通知 Dart。恢复只由显式
/// ensureStarted（登录/前台生命周期）触发，不周期性后台重启。
abstract interface class SyncKeepAliveBackend {
  Future<void> start({
    required int notificationId,
    required String channelTitle,
    required String title,
    required String body,
  });

  Future<void> stop();
}

/// 原生保活钩子：唤醒锁/WiFi 锁的获取与释放（可注入测试）。
abstract interface class KeepAliveHooks {
  Future<bool> acquire();
  Future<void> release();
}

/// `chatflow/keepalive` MethodChannel 实现；失败静默（锁不可得时保活
/// 降级为仅前台服务，绝不抛出到主流程）。
final class MethodChannelKeepAliveHooks implements KeepAliveHooks {
  const MethodChannelKeepAliveHooks();

  static const _channel = MethodChannel('chatflow/keepalive');

  @override
  Future<bool> acquire() async {
    try {
      return await _channel.invokeMethod<bool>('acquireWakeLocks') == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> release() async {
    try {
      await _channel.invokeMethod<bool>('releaseWakeLocks');
    } catch (_) {}
  }
}

/// 电池优化白名单引导（厂商 ROM 息屏清理的必要条件）。
final class KeepAliveBatteryGateway {
  const KeepAliveBatteryGateway();

  static const _channel = MethodChannel('chatflow/keepalive');

  /// 是否已在系统电池优化白名单中；查询失败按 true（不再打扰）。
  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return await _channel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          true;
    } catch (_) {
      return true;
    }
  }

  Future<void> requestIgnoreBatteryOptimizations() async {
    try {
      await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }
}

/// 仲裁器后端：保活不再直控插件前台服务，而是持有 [ForegroundServiceOwner.keepAlive]
/// 所有权——通话结束（release ongoingCall）时仲裁器会重申保活通知而非停止服务。
///
/// 复用同一插件的渠道初始化逻辑（chatflow_sync 渠道必须先于
/// startForegroundService 存在）。
final class ArbiterSyncKeepAliveBackend implements SyncKeepAliveBackend {
  ArbiterSyncKeepAliveBackend({
    required this.arbiter,
    FlutterLocalNotificationsPlugin? plugin,
    NotificationDiagnostics? diagnostics,
  })  : plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        diagnostics = diagnostics ?? NotificationDiagnostics.shared;

  final ForegroundServiceArbiter arbiter;
  final FlutterLocalNotificationsPlugin plugin;
  final NotificationDiagnostics diagnostics;
  bool _initialized = false;

  /// 插件初始化与渠道创建是幂等尽力而为：组合根的通知系统通常已完成
  /// 初始化；此处失败（原生不可用/渠道已存在）不阻断所有权登记——
  /// 真正的服务呈现成败由仲裁器统一诊断。
  Future<void> _ensureInit() async {
    if (_initialized) return;
    try {
      // 不调用 plugin.initialize：点击回调只能有一个注册者（最后注册者
      // 胜出），统一由 FlutterLocalSystemNotificationPresenter 注册分发。
      final android = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          FlutterSyncKeepAliveBackend.channelId,
          FlutterSyncKeepAliveBackend.channelName,
          description: '保持消息与来电实时到达的后台同步服务',
          importance: Importance.low,
          playSound: false,
        ),
      );
    } catch (error) {
      diagnostics.record(NotificationDiagStage.channel,
          'sync channel init skipped: ${error.runtimeType}');
    }
    _initialized = true;
  }

  @override
  Future<void> start({
    required int notificationId,
    required String channelTitle,
    required String title,
    required String body,
  }) async {
    await _ensureInit();
    final result = await arbiter.acquire(
      ForegroundServiceOwner.keepAlive,
      ForegroundServiceRequest(
        notificationId: notificationId,
        channelId: FlutterSyncKeepAliveBackend.channelId,
        channelName: FlutterSyncKeepAliveBackend.channelName,
        channelDescription: '保持消息与来电实时到达的后台同步服务',
        title: title,
        body: body,
        importance: Importance.low,
        priority: Priority.low,
        category: AndroidNotificationCategory.service,
        playSound: false,
        enableVibration: false,
        foregroundServiceTypes: const {
          AndroidServiceForegroundType.foregroundServiceTypeDataSync,
        },
      ),
    );
    if (result != ForegroundServiceApplyResult.applied) {
      throw StateError('Foreground service was not applied');
    }
  }

  @override
  Future<void> stop() => arbiter.release(ForegroundServiceOwner.keepAlive);
}

/// flutter_local_notifications 实现：dataSync 前台服务 + 低优先级常驻通知。
///
/// 注意：该插件全局只有一个 Android ForegroundService，与其他业务
/// （通话中服务）直控同一服务会互踢——组合根应改用
/// [ArbiterSyncKeepAliveBackend] + 共享仲裁器。保留此实现供独立测试场景。
final class FlutterSyncKeepAliveBackend implements SyncKeepAliveBackend {
  FlutterSyncKeepAliveBackend({FlutterLocalNotificationsPlugin? plugin})
      : plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin plugin;
  bool _initialized = false;

  static const notificationId = 41003;
  static const channelId = 'chatflow_silent';
  static const channelName = '后台服务';

  Future<void> _ensureInit() async {
    if (_initialized) return;
    // 不调用 plugin.initialize：点击回调只能有一个注册者（最后注册者
    // 胜出），统一由 FlutterLocalSystemNotificationPresenter 注册分发；
    // 渠道创建与前台服务不依赖 initialize。
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        channelName,
        description: '保持消息与来电实时到达的后台同步服务',
        importance: Importance.low,
        playSound: false,
      ),
    );
    _initialized = true;
  }

  @override
  Future<void> start({
    required int notificationId,
    required String channelTitle,
    required String title,
    required String body,
  }) async {
    await _ensureInit();
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) {
      throw StateError('Android foreground service unavailable');
    }
    await android.startForegroundService(
      notificationId,
      title,
      body,
      notificationDetails: AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: '保持消息与来电实时到达的后台同步服务',
        importance: Importance.low,
        priority: Priority.low,
        category: AndroidNotificationCategory.service,
        ongoing: true,
        playSound: false,
        enableVibration: false,
      ),
      foregroundServiceTypes: const {
        AndroidServiceForegroundType.foregroundServiceTypeDataSync,
      },
    );
  }

  @override
  Future<void> stop() async {
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.stopForegroundService();
  }
}

/// desired 是会话意愿；running/locksAcquired 只代表已确认的原生状态。
/// stop 递增代数，让迟到的启动/取锁完成失效。原生停止后保留意愿，
/// 但不自动重启，等待下一次明确的前台恢复请求。
final class SyncKeepAliveService {
  SyncKeepAliveService({
    SyncKeepAliveBackend? backend,
    KeepAliveHooks? hooks,
    this.watchdogInterval = const Duration(minutes: 10),
  })  : backend = backend ?? FlutterSyncKeepAliveBackend(),
        hooks = hooks ?? const MethodChannelKeepAliveHooks();

  final SyncKeepAliveBackend backend;
  final KeepAliveHooks hooks;

  /// 保留调用兼容性；R4 不再创建后台重申定时器。
  @visibleForTesting
  final Duration watchdogInterval;

  bool _desired = false;
  bool _serviceRunning = false;
  bool _locksAcquired = false;
  bool _stopping = false;
  bool _startAttempted = false;
  int _startEpoch = 0;
  Future<void>? _starting;
  int? _startingEpoch;
  StreamSubscription<String>? _lifecycle;

  bool get isDesired => _desired;
  bool get isRunning => _serviceRunning;
  bool get locksAcquired => _locksAcquired;

  bool _accepts(int epoch) => epoch == _startEpoch && _desired && !_stopping;

  Future<void> ensureStarted() {
    if (_stopping) return Future.value();
    _desired = true;
    _lifecycle ??= ForegroundServiceLifecycle.events.listen((event) {
      if (event == 'locksReleased') {
        _locksAcquired = false;
        return;
      }
      _startEpoch++;
      _serviceRunning = false;
      _locksAcquired = false;
    });
    final pending = _starting;
    if (pending != null) {
      if (_startingEpoch == _startEpoch) return pending;
      // A new explicit resume waits for the old attempt's rollback first.
      return pending.then((_) async {
        if (_desired && !_stopping) await ensureStarted();
      });
    }
    _startingEpoch = _startEpoch;
    return _starting = _start(_startEpoch).whenComplete(() => _starting = null);
  }

  Future<void> _start(int epoch) async {
    if (!_serviceRunning) {
      _startAttempted = true;
      try {
        await backend.start(
          notificationId: FlutterSyncKeepAliveBackend.notificationId,
          channelTitle: FlutterSyncKeepAliveBackend.channelName,
          title: '畅聊消息服务运行中',
          body: '保持消息与来电实时到达',
        );
      } catch (_) {
        return; // 没有合法 FGS 时不取锁。
      }
      if (!_accepts(epoch)) {
        try {
          await backend.stop();
        } catch (_) {}
        return;
      }
      _serviceRunning = true;
    }
    if (_locksAcquired) return;
    var acquired = false;
    try {
      acquired = await hooks.acquire();
    } catch (_) {}
    if (!_accepts(epoch) || !acquired) {
      // 原生实现也回滚部分获取；重复释放仍幂等。
      try {
        await hooks.release();
      } catch (_) {}
      return;
    }
    _locksAcquired = true;
  }

  /// 兼容既有测试/调用入口；系统生命周期是实际状态的唯一来源。
  @visibleForTesting
  Future<void> runWatchdogTick() async {}

  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    _desired = false;
    _startEpoch++;
    _serviceRunning = false;
    try {
      await _lifecycle?.cancel();
      _lifecycle = null;
      if (_locksAcquired) {
        _locksAcquired = false;
        try {
          await hooks.release();
        } catch (_) {}
      }
      if (_startAttempted) {
        try {
          await backend.stop();
        } catch (_) {}
      }
      _startAttempted = false;
    } finally {
      _stopping = false;
    }
  }
}
