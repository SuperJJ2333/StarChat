import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/notification_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('PRD §43 默认设置', () {
    test('默认值与 PRD 设置页一致', () {
      const values = NotificationPreferenceValues();
      expect(values.messageNotificationEnabled, isTrue);
      expect(values.previewPrivacy, NotificationPrivacyLevel.showAll);
      expect(values.soundEnabled, isTrue);
      expect(values.vibrationEnabled, isTrue);
      expect(values.badgeEnabled, isTrue);
      expect(values.attentionEnabled, isTrue);
      expect(values.mentionEnabled, isTrue);
      expect(values.callNotificationEnabled, isTrue);
      expect(values.dndEnabled, isFalse);
      expect(values.dndStartMinutes, 23 * 60);
      expect(values.dndEndMinutes, 8 * 60);
      expect(values.dndAllowAttention, isFalse);
      expect(values.mutedConversationsInBadge, isTrue);
    });
  });

  group('PRD §30 勿扰窗口判定', () {
    test('跨午夜窗口 23:00-08:00', () {
      const prefs = NotificationPreferenceValues(
        dndEnabled: true,
        dndStartMinutes: 23 * 60,
        dndEndMinutes: 8 * 60,
      );
      expect(
        isWithinDndWindow(prefs, DateTime(2026, 9, 3, 23, 30)),
        isTrue,
      );
      expect(isWithinDndWindow(prefs, DateTime(2026, 9, 4, 2, 0)), isTrue);
      expect(isWithinDndWindow(prefs, DateTime(2026, 9, 4, 7, 59)), isTrue);
      expect(isWithinDndWindow(prefs, DateTime(2026, 9, 4, 8, 0)), isFalse);
      expect(isWithinDndWindow(prefs, DateTime(2026, 9, 3, 12, 0)), isFalse);
      expect(isWithinDndWindow(prefs, DateTime(2026, 9, 3, 22, 59)), isFalse);
    });

    test('同日窗口 13:00-14:00', () {
      const prefs = NotificationPreferenceValues(
        dndEnabled: true,
        dndStartMinutes: 13 * 60,
        dndEndMinutes: 14 * 60,
      );
      expect(isWithinDndWindow(prefs, DateTime(2026, 9, 3, 13, 30)), isTrue);
      expect(isWithinDndWindow(prefs, DateTime(2026, 9, 3, 12, 59)), isFalse);
      expect(isWithinDndWindow(prefs, DateTime(2026, 9, 3, 14, 0)), isFalse);
    });

    test('起止相同视为永不触发；总开关关闭时不触发', () {
      const always = NotificationPreferenceValues(
        dndEnabled: true,
        dndStartMinutes: 9 * 60,
        dndEndMinutes: 9 * 60,
      );
      expect(isWithinDndWindow(always, DateTime(2026, 9, 3, 9, 0)), isFalse);

      const disabled = NotificationPreferenceValues(
        dndEnabled: false,
        dndStartMinutes: 0,
        dndEndMinutes: 24 * 60 - 1,
      );
      expect(isWithinDndWindow(disabled, DateTime(2026, 9, 3, 9, 0)), isFalse);
    });
  });

  group('偏好持久化 round-trip', () {
    test('保存后能完整读回', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = SharedPreferencesNotificationPreferenceStore();
      const values = NotificationPreferenceValues(
        messageNotificationEnabled: false,
        previewPrivacy: NotificationPrivacyLevel.hideAll,
        soundEnabled: false,
        vibrationEnabled: false,
        badgeEnabled: false,
        attentionEnabled: false,
        mentionEnabled: false,
        callNotificationEnabled: false,
        dndEnabled: true,
        dndStartMinutes: 22 * 60 + 30,
        dndEndMinutes: 6 * 60 + 15,
        dndAllowAttention: true,
        mutedConversationsInBadge: false,
      );
      await store.save(values);
      expect(await store.load(), values);
    });

    test('无历史数据时返回默认值', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = SharedPreferencesNotificationPreferenceStore();
      expect(await store.load(), const NotificationPreferenceValues());
    });
  });
}
