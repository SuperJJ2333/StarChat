import 'sound_type.dart';

/// 通知优先级（PRD §3）。P0（实时呼叫）由通话状态机独立处理，
/// 此处从 P1 开始。
enum NotificationPriority {
  /// P1 紧急：特别关注、@我。
  urgent,

  /// P2 普通消息：私聊、普通群聊。
  normal,

  /// P3 业务通知：好友申请、官方客服等。
  business,

  /// P4 弱提醒：静默同步。
  weak,
}

/// 震动反馈类型（PRD §37）。
enum HapticFeedbackKind {
  none,

  /// 普通消息单次轻震。
  light,

  /// @我 / 特别关注双轻震。
  doubleLight,

  /// 来电等中等强度。
  medium,
}

/// Android 通知渠道（PRD §31）。`calls`/`call-ongoing` 等既有渠道
/// 由通话模块继续使用，不在本枚举内。
enum SystemNotificationChannel {
  /// 普通消息，IMPORTANCE_DEFAULT。
  messages,

  /// @我，IMPORTANCE_HIGH（Heads-up）。
  mentions,

  /// 特别关注，IMPORTANCE_HIGH（Heads-up）。
  attention,

  /// 系统业务通知，IMPORTANCE_DEFAULT。
  system,

  /// 静默同步（静音会话/勿扰期间保留通知中心），IMPORTANCE_LOW。
  silent,
}

/// 策略引擎输出（PRD §50）。
final class NotificationDecision {
  const NotificationDecision({
    this.showInAppBanner = false,
    this.showSystemNotification = false,
    this.playSound = false,
    this.soundType,
    this.haptic = HapticFeedbackKind.none,
    this.updateBadge = false,
    this.priority = NotificationPriority.weak,
    this.systemChannel = SystemNotificationChannel.silent,
    this.previewTitle = '',
    this.previewBody = '',
  });

  /// 前台应用内顶部横幅（PRD §7）。
  final bool showInAppBanner;

  /// 系统（后台）通知（PRD §19）。
  final bool showSystemNotification;

  /// 前台 Flutter 声音；后台一律由系统渠道播放（PRD §19 防"叮叮两次"）。
  final bool playSound;

  final SoundType? soundType;
  final HapticFeedbackKind haptic;

  /// 是否触发桌面角标刷新（PRD §35）。
  final bool updateBadge;

  final NotificationPriority priority;

  /// 系统通知使用的渠道；仅 [showSystemNotification] 为真时有意义。
  final SystemNotificationChannel systemChannel;

  /// 按隐私设置裁剪后的通知标题/正文（PRD §20/§45）。
  final String previewTitle;
  final String previewBody;
}
