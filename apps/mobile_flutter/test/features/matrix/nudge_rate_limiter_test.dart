import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/nudge_rate_limiter.dart';

void main() {
  test(
      'allows exactly three nudges for one sender and room then rejects fourth',
      () {
    final limiter = NudgeRateLimiter(now: () => DateTime.utc(2026, 9, 13));

    final first = limiter.reserve(senderId: '@alice:test', roomId: '!one:test');
    final second =
        limiter.reserve(senderId: '@alice:test', roomId: '!one:test');
    final third = limiter.reserve(senderId: '@alice:test', roomId: '!one:test');

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(third, isNotNull);
    expect(
        limiter.reserve(senderId: '@alice:test', roomId: '!one:test'), isNull);
  });

  test('keeps quotas separate by sender and room', () {
    final limiter = NudgeRateLimiter(now: () => DateTime.utc(2026, 9, 13));
    for (var i = 0; i < 3; i++) {
      expect(limiter.reserve(senderId: '@alice:test', roomId: '!one:test'),
          isNotNull);
    }

    expect(limiter.reserve(senderId: '@alice:test', roomId: '!two:test'),
        isNotNull);
    expect(
        limiter.reserve(senderId: '@bob:test', roomId: '!one:test'), isNotNull);
  });

  test('recovers a slot at the rolling sixty-second boundary', () {
    var now = DateTime.utc(2026, 9, 13);
    final limiter = NudgeRateLimiter(now: () => now);
    for (var i = 0; i < 3; i++) {
      expect(limiter.reserve(senderId: '@alice:test', roomId: '!one:test'),
          isNotNull);
    }

    now = now.add(const Duration(seconds: 59, milliseconds: 999));
    expect(
        limiter.reserve(senderId: '@alice:test', roomId: '!one:test'), isNull);
    now = now.add(const Duration(milliseconds: 1));
    expect(limiter.reserve(senderId: '@alice:test', roomId: '!one:test'),
        isNotNull);
  });

  test('releasing a failed reservation preserves concurrent reservations', () {
    final limiter = NudgeRateLimiter(now: () => DateTime.utc(2026, 9, 13));
    final failed =
        limiter.reserve(senderId: '@alice:test', roomId: '!one:test')!;
    final successful =
        limiter.reserve(senderId: '@alice:test', roomId: '!one:test')!;
    final third =
        limiter.reserve(senderId: '@alice:test', roomId: '!one:test')!;

    limiter.release(failed);

    expect(limiter.reserve(senderId: '@alice:test', roomId: '!one:test'),
        isNotNull);
    expect(
        limiter.reserve(senderId: '@alice:test', roomId: '!one:test'), isNull);
    expect(successful, isNotNull);
    expect(third, isNotNull);
  });
}
