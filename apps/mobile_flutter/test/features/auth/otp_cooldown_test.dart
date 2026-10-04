import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/auth/otp_cooldown.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';

class Owner implements BusinessSessionMonitor {
  @override
  int sessionEpoch = 0;
  @override
  Stream<BusinessSessionInvalidation> get sessionInvalidations =>
      const Stream.empty();
  @override
  Future<void> checkSessionValidity() async {}
}

void main() {
  test('elapsed deadline uses ceil and expires at exactly sixty seconds', () {
    final owner = Object();
    var now = DateTime.utc(2026, 10, 5);
    final cooldown = OtpCooldown(owner, now: () => now)
      ..bind(purpose: 'login', channel: 'phone', target: '13800000001');
    expect(cooldown.reserve(), isTrue);
    now = now.add(const Duration(milliseconds: 59001));
    final restored = OtpCooldown(owner, now: () => now)
      ..bind(purpose: 'login', channel: 'phone', target: '+86 138 0000 0001');
    expect(restored.remaining, 1);
    expect(restored.reserve(), isFalse);
    now = now.add(const Duration(milliseconds: 999));
    expect(restored.remaining, 0);
    expect(restored.reserve(), isTrue);
  });
  test('channel destination purpose and authenticated epoch are isolated', () {
    final owner = Owner();
    final a = OtpCooldown(owner)
      ..bind(purpose: 'login', channel: 'phone', target: '13800000001');
    expect(a.reserve(), isTrue);
    for (final args in [
      ['login', 'phone', '13800000002'],
      ['registration', 'phone', '13800000001'],
      ['login', 'email', '13800000001']
    ]) {
      expect(
          (OtpCooldown(owner)
                ..bind(purpose: args[0], channel: args[1], target: args[2]))
              .remaining,
          0);
    }
    final authenticated = OtpCooldown(owner)
      ..bind(
          purpose: 'login',
          channel: 'phone',
          target: '13800000001',
          authenticated: true);
    expect(authenticated.remaining, 0);
    expect(authenticated.reserve(), isTrue);
    owner.sessionEpoch++;
    authenticated.bind(
        purpose: 'login',
        channel: 'phone',
        target: '13800000001',
        authenticated: true);
    expect(authenticated.remaining, 0);
  });
  test('late receipt cannot extend a newer reservation after original expiry',
      () {
    final owner = Object();
    var now = DateTime.utc(2026, 10, 5);
    final first = OtpCooldown(owner, now: () => now)
      ..bind(purpose: 'login', channel: 'phone', target: '13800000001');
    first.reserve();
    final late = first.snapshot();
    now = now.add(const Duration(seconds: 61));
    final newer = OtpCooldown(owner, now: () => now)
      ..bind(purpose: 'login', channel: 'phone', target: '13800000001');
    newer.reserve();
    late.extend(120);
    expect(newer.remaining, 60);
  });
  test('rejection cannot release another target reserved at the same instant',
      () {
    final owner = Object();
    final now = DateTime.utc(2026, 10, 5);
    final first = OtpCooldown(owner, now: () => now)
      ..bind(purpose: 'login', channel: 'phone', target: '13800000001');
    first.reserve();
    final second = OtpCooldown(owner, now: () => now)
      ..bind(purpose: 'login', channel: 'phone', target: '13800000002');
    second.reserve();
    first.bind(purpose: 'login', channel: 'phone', target: '13800000002');
    first.reject();
    expect(second.remaining, 60);
  });
}
