import 'notification_decision.dart';
import 'notification_event.dart';
import 'notification_preferences.dart';
import 'sound_type.dart';

import '../../features/matrix/mute_exception_policy.dart';

/// 策略引擎输入：Matrix 同步侧预计算的事实 + 运行时上下文。
final class NotificationPolicyContext {
  const NotificationPolicyContext({
    required this.appForeground,
    required this.isOwnMessage,
    required this.isCurrentConversation,
    required this.muteDecision,
    required this.isMention,
    required this.isAttention,
    required this.callActive,
    required this.prefs,
    required this.event,
    required this.now,
  });

  final bool appForeground;

  /// PRD §26：event.senderId == currentUserId。
  final bool isOwnMessage;

  /// 正在查看的会话（ConversationReadState.isRoomOpen，PRD §18/§53）。
  final bool isCurrentConversation;

  /// 会话静音决策（含 @我/特别关注例外，PRD §29）。
  final MuteNotificationDecision muteDecision;

  final bool isMention;

  /// 会话被标记为特别关注（PRD §27）。
  final bool isAttention;

  /// 正在通话（PRD §40）。
  final bool callActive;

  final NotificationPreferenceValues prefs;
  final NotificationEvent event;

  /// 决策时刻（勿扰窗口判定）。
  final DateTime now;
}

SoundType _soundForKind(NotificationMessageKind kind) {
  switch (kind) {
    case NotificationMessageKind.redPacket:
      return SoundType.redpacketReceived;
    case NotificationMessageKind.transfer:
      return SoundType.diamondReceived;
    case NotificationMessageKind.nudge:
    case NotificationMessageKind.text:
    case NotificationMessageKind.image:
    case NotificationMessageKind.video:
    case NotificationMessageKind.voice:
    case NotificationMessageKind.file:
    case NotificationMessageKind.callSummary:
    case NotificationMessageKind.other:
      return SoundType.messageReceived;
  }
}

/// 通知策略引擎（PRD §22 决策链）。纯函数，无平台依赖。
NotificationDecision decideNotification(NotificationPolicyContext context) {
  // PRD §26/§52：自己发送的消息不产生任何通知、声音、震动与未读。
  if (context.isOwnMessage) return const NotificationDecision();

  // PRD §18/§53：当前正在查看的会话不产生提醒（已读回执由聊天页推进）。
  if (context.isCurrentConversation) return const NotificationDecision();

  final prefs = context.prefs;
  final event = context.event;
  final isBusiness =
      event.eventType == NotificationEventType.businessEvent || event.isSystem;

  // PRD §43：消息通知总开关（业务通知不受其约束）。
  if (!isBusiness && !prefs.messageNotificationEnabled) {
    return NotificationDecision(updateBadge: prefs.badgeEnabled);
  }

  final mutedSuppressed =
      context.muteDecision == MuteNotificationDecision.suppressed;
  final muteException =
      context.muteDecision == MuteNotificationDecision.exception;
  final mention = !isBusiness && context.isMention && prefs.mentionEnabled;
  final attention =
      !isBusiness && context.isAttention && prefs.attentionEnabled;

  // 分级（PRD §3）。
  final NotificationPriority priority;
  final SoundType sound;
  final HapticFeedbackKind haptic;
  final SystemNotificationChannel channel;
  if (mutedSuppressed) {
    priority = NotificationPriority.weak;
    sound = SoundType.messageReceived; // 不播放，仅作默认值。
    haptic = HapticFeedbackKind.none;
    channel = SystemNotificationChannel.silent;
  } else if (attention) {
    priority = NotificationPriority.urgent;
    sound = SoundType.messageAttention;
    haptic = HapticFeedbackKind.doubleLight;
    channel = SystemNotificationChannel.attention;
  } else if (mention || muteException) {
    priority = NotificationPriority.urgent;
    sound = SoundType.mention;
    haptic = HapticFeedbackKind.doubleLight;
    channel = SystemNotificationChannel.mentions;
  } else if (isBusiness) {
    priority = NotificationPriority.business;
    sound = SoundType.notification;
    haptic = HapticFeedbackKind.none;
    channel = SystemNotificationChannel.system;
  } else {
    priority = NotificationPriority.normal;
    sound = _soundForKind(event.messageKind);
    haptic = HapticFeedbackKind.light;
    channel = SystemNotificationChannel.messages;
  }

  // PRD §30：勿扰期间普通消息静默；特别关注/@我仅在用户允许时提醒。
  final dndSilenced = isWithinDndWindow(prefs, context.now) &&
      !isBusiness &&
      (!prefs.dndAllowAttention || priority != NotificationPriority.urgent);

  // 是否允许打扰性反馈（横幅/声音/震动）。
  final bool disruptiveAllowed;
  if (mutedSuppressed || dndSilenced) {
    disruptiveAllowed = false;
  } else if (context.callActive) {
    // PRD §40：通话期间普通消息静默，仅特别提醒允许极轻提示音。
    disruptiveAllowed = priority == NotificationPriority.urgent;
  } else {
    disruptiveAllowed = true;
  }

  // PRD §19：后台由系统通知发声，Flutter 不再播放；前台不出系统通知。
  final showBanner = disruptiveAllowed &&
      context.appForeground &&
      !isBusiness &&
      !context.callActive;
  final playSound =
      disruptiveAllowed && prefs.soundEnabled && context.appForeground;
  final hapticAllowed = disruptiveAllowed &&
      prefs.vibrationEnabled &&
      context.appForeground &&
      !context.callActive;
  final showSystemNotification = !context.appForeground && !context.callActive;

  // PRD §29/§30：静音与勿扰在后台仍保留通知中心（静默渠道）。
  final effectiveChannel = (mutedSuppressed || dndSilenced)
      ? SystemNotificationChannel.silent
      : channel;

  // PRD §35：静音会话是否计入角标由设置控制。
  final updateBadge = prefs.badgeEnabled &&
      (!mutedSuppressed || prefs.mutedConversationsInBadge);

  // PRD §20/§45：按隐私等级裁剪通知内容。
  final String previewTitle;
  final String previewBody;
  switch (prefs.previewPrivacy) {
    case NotificationPrivacyLevel.showAll:
      previewTitle = event.conversationName.isEmpty
          ? event.senderName
          : event.conversationName;
      previewBody = event.messagePreview;
    case NotificationPrivacyLevel.nameOnly:
      previewTitle = event.conversationName.isEmpty
          ? event.senderName
          : event.conversationName;
      previewBody = '你收到了一条新消息';
    case NotificationPrivacyLevel.hideAll:
      previewTitle = '畅聊';
      previewBody = '新消息';
  }

  return NotificationDecision(
    showInAppBanner: showBanner,
    showSystemNotification: showSystemNotification,
    playSound: playSound,
    soundType: playSound ? sound : null,
    haptic: hapticAllowed ? haptic : HapticFeedbackKind.none,
    updateBadge: updateBadge,
    priority: priority,
    systemChannel: effectiveChannel,
    previewTitle: previewTitle,
    previewBody: previewBody,
  );
}
