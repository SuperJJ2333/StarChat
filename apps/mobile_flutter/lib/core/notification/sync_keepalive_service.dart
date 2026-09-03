import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 后台/锁屏通知保活（BUG 2 修复）：
///
/// Android 后台进程数分钟内即被冻结/查杀（MIUI 更激进），Matrix 长连接
/// 随之停止——消息通知、来电铃声全部无法触达。本服务以 dataSync 类型
/// 前台服务常驻（低优先级无声通知"消息服务运行中"），登录会话期间维持
/// 同步长连接存活：
/// - 消息 → 既有系统通知管线（渠道声音）正常触发；
/// - 来电 → 应用内铃声循环（media 用途）+ 全屏意图通知正常触发。
///
/// Android 14+ 对 dataSync 前台服务有每日时长配额（约 6 小时），超时后
/// 系统停止服务并退回"进程存活期"内通知；厂商 ROM 需用户开启自启动与
/// 省电无限制（见 docs/NOTIFICATION_QA_MATRIX.md）。
abstract interface class SyncKeepAliveBackend {
  Future<void> start({
    required int notificationId,
    required String channelTitle,
    required String title,
    required String body,
  });

  Future<void> stop();
}

/// flutter_local_notifications 实现：dataSync 前台服务 + 低优先级常驻通知。
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
    await plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );
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
/// 会话主流程），且失败后不进入运行态、可随时重试。
final class SyncKeepAliveService {
  SyncKeepAliveService({SyncKeepAliveBackend? backend})
      : backend = backend ?? FlutterSyncKeepAliveBackend();

  final SyncKeepAliveBackend backend;

  bool _running = false;
  bool get isRunning => _running;

  Future<void> ensureStarted() async {
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
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    try {
      await backend.stop();
    } catch (_) {
      // 服务本就未运行时停止失败无害。
    }
  }
}
