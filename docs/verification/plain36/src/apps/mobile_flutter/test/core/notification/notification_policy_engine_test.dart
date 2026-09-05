import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/notification_decision.dart';
import 'package:liuhetong_mobile/core/notification/notification_event.dart';
import 'package:liuhetong_mobile/core/notification/notification_policy_engine.dart';
import 'package:liuhetong_mobile/core/notification/notification_preferences.dart';
import 'package:liuhetong_mobile/core/notification/sound_type.dart';
import 'package:liuhetong_mobile/features/matrix/mute_exception_policy.dart';

/// PRD §26/§52：自己发送的消息不得产生任何通知、声音、震动、未读或角标。
NotificationPolicyContext _context({
  bool appForeground = true,
  bool isOwnMessage = false,
  bool isCurrentConversation = false,
  MuteNotificationDecision muteDecision = MuteNotificationDecision.normal,
  bool isMention = false,
  bool isAttention = false,
  bool callActive = false,
  NotificationPreferenceValues prefs = const NotificationPreferenceValues(),
  NotificationEventType eventType = NotificationEventType.chatMessage,
  NotificationMessageKind messageKind = NotificationMessageKind.text,
  bool isSystem = false,
  String conversationName = '张三',
  String messagePreview = '晚上一起吃饭吗？',
  String senderName = '张三',
  DateTime? eventDateTime,
}) {
  // 默认事件时间：正午（不在勿扰窗口内）。
  final at = eventDateTime ?? DateTime(2026, 9, 3, 12);
  return NotificationPolicyContext(
    appForeground: appForeground,
    isOwnMessage: isOwnMessage,
    isCurrentConversation: isCurrentConversation,
    muteDecision: muteDecision,
    isMention: isMention,
    isAttention: isAttention,
    callActive: callActive,
    prefs: prefs,
    event: NotificationEvent(
      eventId: r'$ev1',
      conversationId: r'!room1',
      senderId: r'@peer',
      senderName: senderName,
      conversationName: conversationName,
      eventType: eventType,
      messageKind: messageKind,
      messagePreview: messagePreview,
      isSystem: isSystem,
      timestamp: at,
    ),
    now: at,
  );
}

void main() {
  group('PRD §26/§52 自己发送的消息', () {
    test('不产生通知、声音、震动与角标', () {
      final decision = decideNotification(_context(isOwnMessage: true));
      expect(decision.showInAppBanner, isFalse);
      expect(decision.showSystemNotification, isFalse);
      expect(decision.playSound, isFalse);
      expect(decision.haptic, HapticFeedbackKind.none);
      expect(decision.updateBadge, isFalse);
    });
  });

  group('PRD §18/§53 当前正在查看的会话', () {
    test('前台当前会话收到消息：无横幅、无系统通知、无声音、无角标', () {
      final decision =
          decideNotification(_context(isCurrentConversation: true));
      expect(decision.showInAppBanner, isFalse);
      expect(decision.showSystemNotification, isFalse);
      expect(decision.playSound, isFalse);
      expect(decision.haptic, HapticFeedbackKind.none);
      expect(decision.updateBadge, isFalse);
    });

    test('后台修复（规格#1）：后台时当前会话收到消息必须出系统通知', () {
      final decision = decideNotification(_context(
        appForeground: false,
        isCurrentConversation: true,
      ));
      expect(decision.showSystemNotification, isTrue,
          reason: '退后台后聊天页仍挂载、isRoomOpen 残留 true——'
              '后台必须照常系统通知（微信语义）');
    });
  });

  group('PRD §18 前台普通消息', () {
    test('用户不在当前会话：内部横幅 + 轻声 + 轻震 + 角标，不出系统通知', () {
      final decision = decideNotification(_context(appForeground: true));
      expect(decision.showInAppBanner, isTrue);
      expect(decision.showSystemNotification, isFalse);
      expect(decision.playSound, isTrue);
      expect(decision.soundType, SoundType.messageReceived);
      expect(decision.haptic, HapticFeedbackKind.light);
      expect(decision.updateBadge, isTrue);
      expect(decision.priority, NotificationPriority.normal);
      expect(decision.previewTitle, '张三');
      expect(decision.previewBody, '晚上一起吃饭吗？');
    });
  });

  group('PRD §19 后台消息', () {
    test('后台：系统通知 + 系统渠道声音，Flutter 不再播放声音', () {
      final decision = decideNotification(_context(appForeground: false));
      expect(decision.showSystemNotification, isTrue);
      expect(decision.systemChannel, SystemNotificationChannel.messages);
      expect(decision.showInAppBanner, isFalse);
      expect(decision.playSound, isFalse);
      expect(decision.updateBadge, isTrue);
    });
  });

  group('PRD §28 群聊 @我', () {
    test('P1：mention 音效 + 双震 + mentions 渠道', () {
      final decision = decideNotification(_context(isMention: true));
      expect(decision.priority, NotificationPriority.urgent);
      expect(decision.soundType, SoundType.mention);
      expect(decision.haptic, HapticFeedbackKind.doubleLight);
      expect(decision.systemChannel, SystemNotificationChannel.mentions);
      expect(decision.showInAppBanner, isTrue);
    });

    test('mention 开关关闭后降级为普通消息', () {
      final decision = decideNotification(_context(
        isMention: true,
        prefs: const NotificationPreferenceValues(mentionEnabled: false),
      ));
      expect(decision.priority, NotificationPriority.normal);
      expect(decision.soundType, SoundType.messageReceived);
    });
  });

  group('PRD §27 特别关注', () {
    test('P1：attention 音效 + attention 渠道', () {
      final decision = decideNotification(_context(isAttention: true));
      expect(decision.priority, NotificationPriority.urgent);
      expect(decision.soundType, SoundType.messageAttention);
      expect(decision.systemChannel, SystemNotificationChannel.attention);
    });

    test('attention 开关关闭后降级为普通消息', () {
      final decision = decideNotification(_context(
        isAttention: true,
        prefs: const NotificationPreferenceValues(attentionEnabled: false),
      ));
      expect(decision.priority, NotificationPriority.normal);
      expect(decision.soundType, SoundType.messageReceived);
    });
  });

  group('PRD §29 会话静音', () {
    test('静音：无声音、无震动、无横幅，未读仍计角标', () {
      final decision = decideNotification(
        _context(muteDecision: MuteNotificationDecision.suppressed),
      );
      expect(decision.playSound, isFalse);
      expect(decision.haptic, HapticFeedbackKind.none);
      expect(decision.showInAppBanner, isFalse);
      expect(decision.updateBadge, isTrue);
      // 后台仍保留通知中心（静默渠道，无声音无 Heads-up）。
      expect(decision.systemChannel, SystemNotificationChannel.silent);
    });

    test('静音会话不计入角标的设置生效', () {
      final decision = decideNotification(
        _context(
          muteDecision: MuteNotificationDecision.suppressed,
          prefs: const NotificationPreferenceValues(
              mutedConversationsInBadge: false),
        ),
      );
      expect(decision.updateBadge, isFalse);
    });

    test('静音 + @我例外：按 @我 提醒', () {
      final decision = decideNotification(_context(
        muteDecision: MuteNotificationDecision.exception,
        isMention: true,
      ));
      expect(decision.priority, NotificationPriority.urgent);
      expect(decision.soundType, SoundType.mention);
    });
  });

  group('PRD §30 勿扰时间', () {
    final dndPrefs = const NotificationPreferenceValues(
      dndEnabled: true,
      dndStartMinutes: 23 * 60,
      dndEndMinutes: 8 * 60,
    );

    test('勿扰期间普通消息静默（保留静默系统通知与角标）', () {
      final decision = decideNotification(_context(
        prefs: dndPrefs,
        // 2026-09-03 23:30 处于 23:00-08:00 窗口内。
        eventDateTime: DateTime(2026, 9, 3, 23, 30),
      ));
      expect(decision.playSound, isFalse);
      expect(decision.haptic, HapticFeedbackKind.none);
      expect(decision.showInAppBanner, isFalse);
      expect(decision.systemChannel, SystemNotificationChannel.silent);
      expect(decision.updateBadge, isTrue);
    });

    test('勿扰 + 特别关注（允许）：仍按特别关注提醒', () {
      final decision = decideNotification(_context(
        isAttention: true,
        prefs: dndPrefs.copyWith(dndAllowAttention: true),
        eventDateTime: DateTime(2026, 9, 3, 23, 30),
      ));
      expect(decision.playSound, isTrue);
      expect(decision.soundType, SoundType.messageAttention);
    });

    test('勿扰 + 特别关注（不允许）：静默', () {
      final decision = decideNotification(_context(
        isAttention: true,
        prefs: dndPrefs,
        eventDateTime: DateTime(2026, 9, 3, 23, 30),
      ));
      expect(decision.playSound, isFalse);
      expect(decision.showInAppBanner, isFalse);
    });

    test('勿扰 + @我：仅在允许重要提醒时提醒', () {
      final decision = decideNotification(_context(
        isMention: true,
        prefs: dndPrefs.copyWith(dndAllowAttention: true),
        eventDateTime: DateTime(2026, 9, 3, 23, 30),
      ));
      expect(decision.soundType, SoundType.mention);

      final suppressed = decideNotification(_context(
        isMention: true,
        prefs: dndPrefs,
        eventDateTime: DateTime(2026, 9, 3, 23, 30),
      ));
      expect(suppressed.playSound, isFalse);
    });
  });

  group('PRD §40 通话期间消息', () {
    test('普通消息完全静默，仅保留角标', () {
      final decision = decideNotification(_context(callActive: true));
      expect(decision.playSound, isFalse);
      expect(decision.haptic, HapticFeedbackKind.none);
      expect(decision.showInAppBanner, isFalse);
      expect(decision.updateBadge, isTrue);
    });

    test('特别关注允许极轻提示音', () {
      final decision =
          decideNotification(_context(callActive: true, isAttention: true));
      expect(decision.playSound, isTrue);
      expect(decision.soundType, SoundType.messageAttention);
    });
  });

  group('PRD §20/§45 通知隐私', () {
    test('只显示姓名：正文替换为通用文案', () {
      final decision = decideNotification(_context(
        prefs: const NotificationPreferenceValues(
          previewPrivacy: NotificationPrivacyLevel.nameOnly,
        ),
      ));
      expect(decision.previewTitle, '张三');
      expect(decision.previewBody, '你收到了一条新消息');
    });

    test('隐藏全部详情：标题与正文都通用化', () {
      final decision = decideNotification(_context(
        prefs: const NotificationPreferenceValues(
          previewPrivacy: NotificationPrivacyLevel.hideAll,
        ),
      ));
      expect(decision.previewTitle, '畅聊');
      expect(decision.previewBody, '新消息');
    });
  });

  group('PRD §38 声音与震动独立开关', () {
    test('声音关闭、震动开启：不播音仍震动', () {
      final decision = decideNotification(_context(
        prefs: const NotificationPreferenceValues(soundEnabled: false),
      ));
      expect(decision.playSound, isFalse);
      expect(decision.haptic, HapticFeedbackKind.light);
    });

    test('声音开启、震动关闭：播音不震动', () {
      final decision = decideNotification(_context(
        prefs: const NotificationPreferenceValues(vibrationEnabled: false),
      ));
      expect(decision.playSound, isTrue);
      expect(decision.haptic, HapticFeedbackKind.none);
    });
  });

  group('PRD §43 消息通知总开关', () {
    test('总开关关闭：无横幅、无系统通知、无声音', () {
      final decision = decideNotification(_context(
        prefs: const NotificationPreferenceValues(
            messageNotificationEnabled: false),
      ));
      expect(decision.showInAppBanner, isFalse);
      expect(decision.showSystemNotification, isFalse);
      expect(decision.playSound, isFalse);
      expect(decision.haptic, HapticFeedbackKind.none);
    });
  });

  group('业务消息音效映射（PRD §4/§8）', () {
    test('红包到达播放 redpacketReceived', () {
      final decision = decideNotification(
        _context(messageKind: NotificationMessageKind.redPacket),
      );
      expect(decision.soundType, SoundType.redpacketReceived);
    });

    test('点钻转账到账播放 diamondReceived', () {
      final decision = decideNotification(
        _context(messageKind: NotificationMessageKind.transfer),
      );
      expect(decision.soundType, SoundType.diamondReceived);
    });
  });

  group('PRD §3 P3 业务通知', () {
    test('系统业务事件：notification 音效 + system 渠道 + business 优先级', () {
      final decision = decideNotification(_context(
        eventType: NotificationEventType.businessEvent,
        isSystem: true,
      ));
      expect(decision.priority, NotificationPriority.business);
      expect(decision.soundType, SoundType.notification);
      expect(decision.systemChannel, SystemNotificationChannel.system);
    });
  });

  group('PRD §5 通话音效不经过消息策略（由通话状态机驱动）', () {
    test('消息事件永不产生来电铃声', () {
      final decision = decideNotification(_context());
      expect(decision.soundType, isNot(SoundType.callVoiceIncoming));
      expect(decision.soundType, isNot(SoundType.callVideoIncoming));
    });
  });
}
