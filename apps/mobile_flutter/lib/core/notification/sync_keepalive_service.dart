import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'foreground_service_arbiter.dart';
import 'notification_diagnostics.dart';

/// 后台/锁屏通知保活（BUG 2 修复）：
///
/// Android 后台进程数分钟内即被冻结/查杀（MIUI 更激进），Matrix 长连接
/// 随之停止——消息通知、来电铃声全部无法触达。本服务组合三层保活：
/// 1. dataSync 类型前台服务（低优先级无声常驻通知）提升进程优先级；
/// 2. PARTIAL WakeLock + 高性能 WifiLock（原生 `chatflow/keepalive`
///    通道）：前台服务不阻止息屏后 CPU 休眠与 WiFi 低功耗断连，长轮询
///    同步仍会停——必须显式持锁；
/// 3. 看门狗周期性重申（系统静默回收后自愈），回前台生命周期亦重申。
///
/// Android 14+ 对 dataSync 前台服务有每日时长配额（约 6 小时）；厂商
/// ROM（MIUI 等）需用户开启自启动与电池优化白名单（登录后一次性引导，
/// 见 AppHome `_primeBatteryOptimization`）。
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
  Future<void> acquire();
  Future<void> release();
}

/// `chatflow/keepalive` MethodChannel 实现；失败静默（锁不可得时保活
/// 降级为仅前台服务，绝不抛出到主流程）。
final class MethodChannelKeepAliveHooks implements KeepAliveHooks {
  const MethodChannelKeepAliveHooks();

  static const _channel = MethodChannel('chatflow/keepalive');

  @override
  Future<void> acquire() async {
    try {
      await _channel.invokeMethod<bool>('acquireWakeLocks');
    } catch (_) {
      // 原生侧不可用（非 Android/通道未注册）时静默降级。
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
    await arbiter.acquire(
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
  static const channelId = 'chatflow_sync';
  static const channelName = '消息同步';

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
    await android?.startForegroundService(
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

/// 状态机：幂等启动/停止；后端失败不抛出（保活是尽力而为，绝不阻断
/// 会话主流程），且失败后不进入运行态、可随时重试；运行期间看门狗
/// 周期性重申前台服务与唤醒锁（系统静默回收后自愈）。
final class SyncKeepAliveService {
  SyncKeepAliveService({
    SyncKeepAliveBackend? backend,
    KeepAliveHooks? hooks,
    this.watchdogInterval = const Duration(minutes: 10),
  })  : backend = backend ?? FlutterSyncKeepAliveBackend(),
        hooks = hooks ?? const MethodChannelKeepAliveHooks();

  final SyncKeepAliveBackend backend;
  final KeepAliveHooks hooks;

  /// 看门狗周期：重申周期不宜过密（耗电），10 分钟可覆盖多数回收场景。
  @visibleForTesting
  final Duration watchdogInterval;

  bool _running = false;
  bool get isRunning => _running;

  Timer? _watchdog;

  Future<void> ensureStarted() async {
    _watchdog ??= Timer.periodic(watchdogInterval, (_) => runWatchdogTick());
    if (_running) return;
    try {
      await backend.start(
        notificationId: FlutterSyncKeepAliveBackend.notificationId,
        channelTitle: FlutterSyncKeepAliveBackend.channelName,
        title: '畅聊消息服务运行中',
        body: '保持消息与来电实时到达',
      );
      _running = true;
    } catch (_) {
      // 启动失败（权限/ROM 限制）静默降级；回前台生命周期可重试。
    }
    await hooks.acquire().catchError((_) {});
  }

  /// 看门狗拍：运行中无条件重申前台服务与唤醒锁（幂等），系统静默
  /// 回收后自愈；停止后为空操作。测试可直接驱动。
  @visibleForTesting
  Future<void> runWatchdogTick() async {
    if (!_running) return;
    try {
      await backend.start(
        notificationId: FlutterSyncKeepAliveBackend.notificationId,
        channelTitle: FlutterSyncKeepAliveBackend.channelName,
        title: '畅聊消息服务运行中',
        body: '保持消息与来电实时到达',
      );
    } catch (_) {
      // 重申失败保留运行态，下一拍再试。
    }
    await hooks.acquire().catchError((_) {});
  }

  Future<void> stop() async {
    if (!_running) return;
    _watchdog?.cancel();
    _watchdog = null;
    _running = false;
    await hooks.release().catchError((_) {});
    try {
      await backend.stop();
    } catch (_) {
      // 服务本就未运行时停止失败无害。
    }
  }
}
