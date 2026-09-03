import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_decision.dart';

/// 通知权限状态（PRD §34/§56 权限降级展示用）。
enum NotificationAuthorizationStatus { undetermined, granted, denied }

/// 系统通知抽象：可注入测试（PRD §68-3：业务页面不得直接创建系统通知）。
abstract interface class SystemNotificationPresenter {
  Future<void> initialize();
  Future<bool> requestAuthorization();
  Future<NotificationAuthorizationStatus> authorizationStatus();
  Future<void> showConversationMessage({
    required int notificationId,
    required String title,
    required String body,
    required SystemNotificationChannel channel,
    required String roomIdPayload,
  });
  Future<void> cancelConversation(int notificationId);
}

/// PRD §31 渠道定义。`calls`/`call-ongoing`/`changliao_message_reminders`/
/// `changliao_friend_requests` 为既有渠道，由各自模块继续使用。
final class _ChannelSpec {
  const _ChannelSpec(
    this.id,
    this.name,
    this.description,
    this.importance,
    this.soundResource,
  );

  final String id;
  final String name;
  final String description;
  final Importance importance;

  /// res/raw 资源名（不含扩展名）；null 表示无声。
  final String? soundResource;
}

const _channelSpecs = <_ChannelSpec>[
  _ChannelSpec(
    'chatflow_messages',
    '消息通知',
    '普通聊天消息提醒',
    Importance.defaultImportance,
    'chatflow_message',
  ),
  _ChannelSpec(
    'chatflow_mentions',
    '提及与我',
    '群聊 @我 的高优先级提醒',
    Importance.high,
    'chatflow_mention',
  ),
  _ChannelSpec(
    'chatflow_attention',
    '特别关注',
    '特别关注联系人的高优先级提醒',
    Importance.high,
    'chatflow_attention',
  ),
  _ChannelSpec(
    'chatflow_system',
    '系统通知',
    '好友申请、业务到账等系统提醒',
    Importance.defaultImportance,
    'chatflow_system',
  ),
  _ChannelSpec(
    'chatflow_silent',
    '静默同步',
    '静音会话与勿扰期间的通知中心记录（无声音无横幅）',
    Importance.low,
    null,
  ),
];

final class FlutterLocalSystemNotificationPresenter
    implements SystemNotificationPresenter {
  FlutterLocalSystemNotificationPresenter({
    FlutterLocalNotificationsPlugin? plugin,
    this.onConversationTap,
  }) : plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin plugin;

  /// 通知点击回调：payload 为会话 roomId（PRD §63 notification_opened）。
  final void Function(String roomId)? onConversationTap;

  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    await plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: (response) {
        final roomId = response.payload;
        final tap = onConversationTap;
        if (roomId != null && roomId.isNotEmpty && tap != null) {
          tap(roomId);
        }
      },
    );
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    for (final spec in _channelSpecs) {
      await android?.createNotificationChannel(
        AndroidNotificationChannel(
          spec.id,
          spec.name,
          description: spec.description,
          importance: spec.importance,
          playSound: spec.soundResource != null,
          sound: spec.soundResource == null
              ? null
              : RawResourceAndroidNotificationSound(spec.soundResource!),
        ),
      );
    }
    _initialized = true;
  }

  @override
  Future<bool> requestAuthorization() async {
    await initialize();
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? false;
    }
    final ios = plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      return await ios.requestPermissions() ?? false;
    }
    return false;
  }

  @override
  Future<NotificationAuthorizationStatus> authorizationStatus() async {
    try {
      final android = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        final enabled = await android.areNotificationsEnabled();
        return enabled == true
            ? NotificationAuthorizationStatus.granted
            : NotificationAuthorizationStatus.denied;
      }
      final ios = plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) {
        final permissions = await ios.checkPermissions();
        if (permissions == null) {
          return NotificationAuthorizationStatus.undetermined;
        }
        return permissions.isEnabled
            ? NotificationAuthorizationStatus.granted
            : NotificationAuthorizationStatus.denied;
      }
    } catch (_) {
      // 查询失败按未确定处理，不影响主流程。
    }
    return NotificationAuthorizationStatus.undetermined;
  }

  @override
  Future<void> showConversationMessage({
    required int notificationId,
    required String title,
    required String body,
    required SystemNotificationChannel channel,
    required String roomIdPayload,
  }) async {
    await initialize();
    await plugin.show(
      notificationId,
      title,
      body,
      NotificationDetails(
        android: _androidDetails(channel),
        iOS: _iosDetails(channel),
      ),
      payload: roomIdPayload,
    );
  }

  @override
  Future<void> cancelConversation(int notificationId) async {
    await initialize();
    await plugin.cancel(notificationId);
  }

  AndroidNotificationDetails _androidDetails(
    SystemNotificationChannel channel,
  ) {
    final spec = _channelSpecs.firstWhere(
      (candidate) => candidate.id == _channelIdFor(channel),
    );
    final priority = spec.importance == Importance.high
        ? Priority.high
        : spec.importance == Importance.low
            ? Priority.low
            : Priority.defaultPriority;
    return AndroidNotificationDetails(
      spec.id,
      spec.name,
      channelDescription: spec.description,
      importance: spec.importance,
      priority: priority,
      category: AndroidNotificationCategory.message,
      playSound: spec.soundResource != null,
      sound: spec.soundResource == null
          ? null
          : RawResourceAndroidNotificationSound(spec.soundResource!),
      enableVibration: spec.soundResource != null,
      styleInformation: const DefaultStyleInformation(true, true),
    );
  }

  DarwinNotificationDetails _iosDetails(SystemNotificationChannel channel) {
    // iOS 自定义通知音需要把音频文件注册进 bundle（后续阶段），
    // 本期使用系统默认提示音。
    final interruption = switch (channel) {
      SystemNotificationChannel.mentions ||
      SystemNotificationChannel.attention =>
        InterruptionLevel.timeSensitive,
      SystemNotificationChannel.silent => InterruptionLevel.passive,
      _ => InterruptionLevel.active,
    };
    return DarwinNotificationDetails(
      presentBanner: channel != SystemNotificationChannel.silent,
      presentList: true,
      interruptionLevel: interruption,
      threadIdentifier: 'chatflow-messages',
    );
  }

  String _channelIdFor(SystemNotificationChannel channel) => switch (channel) {
        SystemNotificationChannel.messages => 'chatflow_messages',
        SystemNotificationChannel.mentions => 'chatflow_mentions',
        SystemNotificationChannel.attention => 'chatflow_attention',
        SystemNotificationChannel.system => 'chatflow_system',
        SystemNotificationChannel.silent => 'chatflow_silent',
      };
}
