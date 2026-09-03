import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/sound_type.dart';
import 'package:liuhetong_mobile/features/matrix/call_alerts.dart';

final class RecordingDriver implements CallAlertDriver {
  final ringtones = <SoundType>[];
  int vibrations = 0;
  int stops = 0;

  @override
  Future<void> startRingtone(SoundType ringtone) async =>
      ringtones.add(ringtone);

  @override
  Future<void> stopRingtone() async => stops++;

  @override
  Future<void> vibrate() async => vibrations++;
}

void main() {
  test('alerts ring immediately then loop on the interval', () async {
    final driver = RecordingDriver();
    final alerts =
        CallAlerts(driver: driver, interval: const Duration(milliseconds: 20));

    expect(alerts.ringing, isFalse);
    alerts.start(SoundType.callVoiceIncoming);
    expect(alerts.ringing, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(driver.ringtones, [SoundType.callVoiceIncoming],
        reason: '响铃即时触发一次（铃声+震动）');
    expect(driver.vibrations, 1);

    await Future<void>.delayed(const Duration(milliseconds: 55));
    expect(driver.ringtones.length, greaterThanOrEqualTo(2), reason: '按间隔循环响铃');
    expect(driver.vibrations, driver.ringtones.length, reason: '铃声与震动成对出现');

    alerts.stop();
    final countAtStop = driver.ringtones.length;
    expect(alerts.ringing, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(driver.ringtones.length, countAtStop, reason: '停止后不再响铃');

    // 二次 start 重新开始循环；重复 start 不会叠加循环。
    alerts.start(SoundType.callVideoIncoming);
    alerts.start(SoundType.callVideoIncoming);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(driver.ringtones.length, countAtStop + 1);
    alerts.dispose();
  });

  test('driver failures never break the ringing loop', () async {
    final alerts = CallAlerts(
      driver: _ThrowingDriver(),
      interval: const Duration(milliseconds: 10),
    );
    alerts.start(SoundType.callVoiceIncoming);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(alerts.ringing, isTrue, reason: '驱动抛错不影响循环');
    alerts.dispose();
  });
}

final class _ThrowingDriver implements CallAlertDriver {
  @override
  Future<void> startRingtone(SoundType ringtone) async =>
      throw StateError('no channel');

  @override
  Future<void> stopRingtone() async => throw StateError('no channel');

  @override
  Future<void> vibrate() async => throw StateError('no vibrator');
}
