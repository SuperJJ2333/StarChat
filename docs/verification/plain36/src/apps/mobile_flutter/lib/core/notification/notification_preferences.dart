import 'package:shared_preferences/shared_preferences.dart';

/// 锁屏通知隐私等级（PRD §20/§45）。
enum NotificationPrivacyLevel { showAll, nameOnly, hideAll }

/// 通知与声音设置（PRD §43/§67 设置页的数据模型）。
final class NotificationPreferenceValues {
  const NotificationPreferenceValues({
    this.messageNotificationEnabled = true,
    this.previewPrivacy = NotificationPrivacyLevel.showAll,
    this.soundEnabled = true,
    this.vibrationEnabled = true,
    this.badgeEnabled = true,
    this.attentionEnabled = true,
    this.mentionEnabled = true,
    this.callNotificationEnabled = true,
    this.dndEnabled = false,
    this.dndStartMinutes = 23 * 60,
    this.dndEndMinutes = 8 * 60,
    this.dndAllowAttention = false,
    this.mutedConversationsInBadge = true,
  });

  final bool messageNotificationEnabled;
  final NotificationPrivacyLevel previewPrivacy;
  final bool soundEnabled;
  final bool vibrationEnabled;
  final bool badgeEnabled;
  final bool attentionEnabled;
  final bool mentionEnabled;
  final bool callNotificationEnabled;

  /// 勿扰时间窗（PRD §30），本地分钟数，支持跨午夜。
  final bool dndEnabled;
  final int dndStartMinutes;
  final int dndEndMinutes;
  final bool dndAllowAttention;

  /// 静音会话是否计入桌面角标（PRD §35，默认开启）。
  final bool mutedConversationsInBadge;

  NotificationPreferenceValues copyWith({
    bool? messageNotificationEnabled,
    NotificationPrivacyLevel? previewPrivacy,
    bool? soundEnabled,
    bool? vibrationEnabled,
    bool? badgeEnabled,
    bool? attentionEnabled,
    bool? mentionEnabled,
    bool? callNotificationEnabled,
    bool? dndEnabled,
    int? dndStartMinutes,
    int? dndEndMinutes,
    bool? dndAllowAttention,
    bool? mutedConversationsInBadge,
  }) =>
      NotificationPreferenceValues(
        messageNotificationEnabled:
            messageNotificationEnabled ?? this.messageNotificationEnabled,
        previewPrivacy: previewPrivacy ?? this.previewPrivacy,
        soundEnabled: soundEnabled ?? this.soundEnabled,
        vibrationEnabled: vibrationEnabled ?? this.vibrationEnabled,
        badgeEnabled: badgeEnabled ?? this.badgeEnabled,
        attentionEnabled: attentionEnabled ?? this.attentionEnabled,
        mentionEnabled: mentionEnabled ?? this.mentionEnabled,
        callNotificationEnabled:
            callNotificationEnabled ?? this.callNotificationEnabled,
        dndEnabled: dndEnabled ?? this.dndEnabled,
        dndStartMinutes: dndStartMinutes ?? this.dndStartMinutes,
        dndEndMinutes: dndEndMinutes ?? this.dndEndMinutes,
        dndAllowAttention: dndAllowAttention ?? this.dndAllowAttention,
        mutedConversationsInBadge:
            mutedConversationsInBadge ?? this.mutedConversationsInBadge,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotificationPreferenceValues &&
          other.messageNotificationEnabled == messageNotificationEnabled &&
          other.previewPrivacy == previewPrivacy &&
          other.soundEnabled == soundEnabled &&
          other.vibrationEnabled == vibrationEnabled &&
          other.badgeEnabled == badgeEnabled &&
          other.attentionEnabled == attentionEnabled &&
          other.mentionEnabled == mentionEnabled &&
          other.callNotificationEnabled == callNotificationEnabled &&
          other.dndEnabled == dndEnabled &&
          other.dndStartMinutes == dndStartMinutes &&
          other.dndEndMinutes == dndEndMinutes &&
          other.dndAllowAttention == dndAllowAttention &&
          other.mutedConversationsInBadge == mutedConversationsInBadge;

  @override
  int get hashCode => Object.hash(
        messageNotificationEnabled,
        previewPrivacy,
        soundEnabled,
        vibrationEnabled,
        badgeEnabled,
        attentionEnabled,
        mentionEnabled,
        callNotificationEnabled,
        dndEnabled,
        dndStartMinutes,
        dndEndMinutes,
        dndAllowAttention,
        mutedConversationsInBadge,
      );
}

/// 勿扰窗口判定（PRD §30）。窗口含起点、不含终点；支持跨午夜；
/// 起止相同视为永不触发。
bool isWithinDndWindow(NotificationPreferenceValues prefs, DateTime now) {
  if (!prefs.dndEnabled) return false;
  final start = prefs.dndStartMinutes;
  final end = prefs.dndEndMinutes;
  if (start == end) return false;
  final minuteOfDay = now.hour * 60 + now.minute;
  if (start < end) {
    return minuteOfDay >= start && minuteOfDay < end;
  }
  return minuteOfDay >= start || minuteOfDay < end;
}

abstract interface class NotificationPreferenceStore {
  Future<NotificationPreferenceValues> load();
  Future<void> save(NotificationPreferenceValues values);
}

final class SharedPreferencesNotificationPreferenceStore
    implements NotificationPreferenceStore {
  const SharedPreferencesNotificationPreferenceStore();

  static const _prefix = 'notification.';

  @override
  Future<NotificationPreferenceValues> load() async {
    final prefs = await SharedPreferences.getInstance();
    final privacyName = prefs.getString('${_prefix}preview_privacy');
    return NotificationPreferenceValues(
      messageNotificationEnabled:
          prefs.getBool('${_prefix}message_enabled') ?? true,
      previewPrivacy: NotificationPrivacyLevel.values
              .where((level) => level.name == privacyName)
              .firstOrNull ??
          NotificationPrivacyLevel.showAll,
      soundEnabled: prefs.getBool('${_prefix}sound_enabled') ?? true,
      vibrationEnabled: prefs.getBool('${_prefix}vibration_enabled') ?? true,
      badgeEnabled: prefs.getBool('${_prefix}badge_enabled') ?? true,
      attentionEnabled: prefs.getBool('${_prefix}attention_enabled') ?? true,
      mentionEnabled: prefs.getBool('${_prefix}mention_enabled') ?? true,
      callNotificationEnabled: prefs.getBool('${_prefix}call_enabled') ?? true,
      dndEnabled: prefs.getBool('${_prefix}dnd_enabled') ?? false,
      dndStartMinutes: prefs.getInt('${_prefix}dnd_start_minutes') ?? 23 * 60,
      dndEndMinutes: prefs.getInt('${_prefix}dnd_end_minutes') ?? 8 * 60,
      dndAllowAttention:
          prefs.getBool('${_prefix}dnd_allow_attention') ?? false,
      mutedConversationsInBadge:
          prefs.getBool('${_prefix}muted_in_badge') ?? true,
    );
  }

  @override
  Future<void> save(NotificationPreferenceValues values) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
        '${_prefix}message_enabled', values.messageNotificationEnabled);
    await prefs.setString(
        '${_prefix}preview_privacy', values.previewPrivacy.name);
    await prefs.setBool('${_prefix}sound_enabled', values.soundEnabled);
    await prefs.setBool('${_prefix}vibration_enabled', values.vibrationEnabled);
    await prefs.setBool('${_prefix}badge_enabled', values.badgeEnabled);
    await prefs.setBool('${_prefix}attention_enabled', values.attentionEnabled);
    await prefs.setBool('${_prefix}mention_enabled', values.mentionEnabled);
    await prefs.setBool(
        '${_prefix}call_enabled', values.callNotificationEnabled);
    await prefs.setBool('${_prefix}dnd_enabled', values.dndEnabled);
    await prefs.setInt('${_prefix}dnd_start_minutes', values.dndStartMinutes);
    await prefs.setInt('${_prefix}dnd_end_minutes', values.dndEndMinutes);
    await prefs.setBool(
        '${_prefix}dnd_allow_attention', values.dndAllowAttention);
    await prefs.setBool(
        '${_prefix}muted_in_badge', values.mutedConversationsInBadge);
  }
}
