import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/sound_cooldown_gate.dart';

void main() {
  group('PRD §41 消息风暴保护', () {
    test('同一会话 2 秒冷却窗口内只响第一声', () {
      var clock = DateTime(2026, 9, 3, 12);
      final gate = SoundCooldownGate(
        perConversationWindow: const Duration(seconds: 2),
        globalWindow: const Duration(milliseconds: 600),
        now: () => clock,
      );
      expect(gate.shouldPlaySound(r'!room1'), isTrue);
      clock = clock.add(const Duration(milliseconds: 100));
      expect(gate.shouldPlaySound(r'!room1'), isFalse);
      clock = clock.add(const Duration(milliseconds: 900));
      expect(gate.shouldPlaySound(r'!room1'), isFalse);
      clock = clock.add(const Duration(seconds: 2));
      expect(gate.shouldPlaySound(r'!room1'), isTrue);
    });

    test('不同会话受全局冷却 600ms 约束', () {
      var clock = DateTime(2026, 9, 3, 12);
      final gate = SoundCooldownGate(
        perConversationWindow: const Duration(seconds: 2),
        globalWindow: const Duration(milliseconds: 600),
        now: () => clock,
      );
      expect(gate.shouldPlaySound(r'!room1'), isTrue);
      clock = clock.add(const Duration(milliseconds: 200));
      expect(gate.shouldPlaySound(r'!room2'), isFalse);
      clock = clock.add(const Duration(milliseconds: 500));
      expect(gate.shouldPlaySound(r'!room2'), isTrue);
    });
  });
}
