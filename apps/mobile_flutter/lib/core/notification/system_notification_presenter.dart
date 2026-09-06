import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../ui/foundation/avatar_cache.dart';
import 'notification_decision.dart';
import 'notification_diagnostics.dart';

/// 通知权限状态（PRD §34/§56 权限降级展示用）。
enum NotificationAuthorizationStatus { undetermined, granted, denied }

/// 系统通知点击统一分发（纯函数，可测）。
///
/// flutter_local_notifications 的点击回调是"最后 initialize 者胜出"——
/// 此前多个组件（好友申请/定时提醒/保活/通话）各自 initialize（多数无
/// 回调，好友申请的回调会劫持所有点击），消息通知点击被覆盖或误路由。
/// 现在**只有 presenter 注册一次回调**，所有通知的 payload 在此集中分发。
void routeSystemNotificationPayload(
  String payload, {
  required void Function(String roomId) openConversation,
  required void Function() openFriendRequests,
  void Function()? openCall,
}) {
  if (payload.isEmpty) return;
  switch (payload) {
    case 'friend-requests':
      openFriendRequests();
      break;
    case 'incoming-call':
    case 'ongoing-call':
      openCall?.call();
      break;
    default:
      // 消息通知 payload 为 roomId；进入会话后由本地同步+解密呈现内容。
      openConversation(payload);
  }
}

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
    String? avatarUrl,
    int? unreadCount,
  });
  Future<void> cancelConversation(int notificationId);
}

/// PRD §31 渠道定义。`calls`/`call-ongoing`/`changliao_message_reminders`/
/// `changliao_friend_requests` 为既有渠道，由各自模块继续使用。
final class ChannelSpec {
  const ChannelSpec(
    this.id,
    this.name,
    this.description,
    this.importance,
    this.soundResource, {
    this.legacy = false,
    this.vibrationEnabled = false,
  });

  final String id;
  final String name;
  final String description;
  final Importance importance;

  /// res/raw 资源名（不含扩展名）；null 表示无声。
  final String? soundResource;

  /// legacy 渠道：老安装已创建（Android 渠道重要性/声音创建后不可修改），
  /// 保留不删除、不再承载任何通知；新安装也不再创建。
  final bool legacy;

  /// 渠道级震动（heads-up 渠道需锁屏可感知）。
  final bool vibrationEnabled;
}

/// 消息渠道 v2（heads-up）：渠道创建后重要性/声音不可修改，老安装的
/// v1（IMPORTANCE_DEFAULT，无顶部弹窗）无法原地升级，必须换新渠道 ID。
const String messagesChannelIdV2 = 'chatflow_messages_v2';

const _channelSpecs = <ChannelSpec>[
  ChannelSpec('calls_ring', '通话提醒', '语音和视频来电铃声与锁屏提醒', Importance.max,
      'chatflow_ringtone',
      vibrationEnabled: true),
  ChannelSpec(messagesChannelIdV2, '消息通知', '聊天、提及、特别关注与系统消息', Importance.high,
      'chatflow_message',
      vibrationEnabled: true),
  ChannelSpec(
      'chatflow_silent', '后台服务', '消息同步、通话保活与静默通知', Importance.low, null),
];

/// 全部渠道规格（含 legacy：老安装保留、新安装不创建）。
const List<ChannelSpec> allChannelSpecs = _channelSpecs;

/// 在新安装上创建并承载通知的渠道（不含 legacy）。
final List<ChannelSpec> activeChannelSpecs = [
  for (final spec in _channelSpecs)
    if (!spec.legacy) spec,
];

/// 枚举渠道 → 渠道 ID。
String _channelIdFor(SystemNotificationChannel channel) =>
    channel == SystemNotificationChannel.silent
        ? 'chatflow_silent'
        : messagesChannelIdV2;

ChannelSpec channelSpecFor(SystemNotificationChannel channel) =>
    activeChannelSpecs.firstWhere(
      (spec) => spec.id == _channelIdFor(channel),
    );

final class FlutterLocalSystemNotificationPresenter
    implements SystemNotificationPresenter {
  FlutterLocalSystemNotificationPresenter({
    FlutterLocalNotificationsPlugin? plugin,
    this.onConversationTap,
    NotificationDiagnostics? diagnostics,
  })  : plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        diagnostics = diagnostics ?? NotificationDiagnostics.shared;

  final FlutterLocalNotificationsPlugin plugin;

  /// 通知点击回调：payload 为会话 roomId（PRD §63 notification_opened）。
  final void Function(String roomId)? onConversationTap;

  final NotificationDiagnostics diagnostics;

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
    // 用户要求合并渠道；保留现有消息/铃声/静默设置，仅删除已迁移的旧 ID。
    for (final id in const [
      'chatflow_messages',
      'chatflow_mentions',
      'chatflow_attention',
      'chatflow_system',
      'chatflow_sync',
      'calls',
      'call-ongoing',
      'changliao_message_reminders',
      'changliao_friend_requests'
    ]) {
      await android?.deleteNotificationChannel(id);
    }
    for (final spec in activeChannelSpecs) {
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
          enableVibration: spec.vibrationEnabled,
          vibrationPattern: spec.vibrationEnabled
              ? Int64List.fromList(const [0, 400, 200, 400])
              : null,
        ),
      );
    }
    _initialized = true;
    diagnostics.record(NotificationDiagStage.channel,
        'initialized ${activeChannelSpecs.length} channels');
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
    } catch (error) {
      // 查询失败按未确定处理，不影响主流程；留下诊断以便定位层级。
      diagnostics.record(NotificationDiagStage.permission,
          'status query failed: ${error.runtimeType}');
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
    String? avatarUrl,
    int? unreadCount,
  }) async {
    await initialize();
    debugPrint('[PUSH] show notification id=$notificationId '
        'channel=${channel.name} unread=${unreadCount ?? '-'}');
    try {
      // 头像：只用已缓存字节（通知路径不发起网络下载，避免延迟）。
      Uint8List? avatarBytes;
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        try {
          final file = await AvatarCache.manager.getFileFromCache(avatarUrl);
          if (file != null) avatarBytes = await file.file.readAsBytes();
        } catch (_) {
          // 无缓存头像按默认图标。
        }
      }
      await plugin.show(
        notificationId,
        title,
        body,
        NotificationDetails(
          android: _androidDetails(
            channel,
            avatarBytes: avatarBytes,
            unreadCount: unreadCount,
          ),
          iOS: _iosDetails(channel),
        ),
        payload: roomIdPayload,
      );
      diagnostics.record(NotificationDiagStage.systemShow,
          'ok id=$notificationId channel=${channelSpecFor(channel).id}',
          roomId: roomIdPayload);
    } catch (error) {
      // 系统通知失败（权限/渠道异常）不抛出到通知链路，但必须可诊断。
      diagnostics.record(NotificationDiagStage.systemShow,
          'failed id=$notificationId: ${error.runtimeType}',
          roomId: roomIdPayload);
    }
  }

  @override
  Future<void> cancelConversation(int notificationId) async {
    await initialize();
    await plugin.cancel(notificationId);
  }

  AndroidNotificationDetails _androidDetails(
    SystemNotificationChannel channel, {
    Uint8List? avatarBytes,
    int? unreadCount,
  }) {
    final spec = channelSpecFor(channel);
    final avatarIcon = avatarBytes == null
        ? null
        : ByteArrayAndroidIcon(avatarBytes) as AndroidBitmap<Object>;
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
      // BUG 2 锁屏可见性：内容已按 previewPrivacy 分级裁剪，public
      // 确保锁屏/息屏时通知与摘要可见（系统级隐私设置仍可进一步隐藏）。
      visibility: NotificationVisibility.public,
      playSound: spec.soundResource != null,
      sound: spec.soundResource == null
          ? null
          : RawResourceAndroidNotificationSound(spec.soundResource!),
      enableVibration: spec.soundResource != null,
      // 规格#1：好友头像大图标 + 未读数角标（有缓存才带，不发起下载）。
      largeIcon: avatarIcon,
      number: unreadCount,
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
}
