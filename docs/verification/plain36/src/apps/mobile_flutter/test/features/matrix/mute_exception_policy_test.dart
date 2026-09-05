import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/mute_exception_policy.dart';

void main() {
  test('muted ordinary messages are suppressed', () {
    expect(
      evaluateMuteNotification(
        const MuteExceptionSettings(muted: true),
        const MuteEventFacts(senderId: '@a:test'),
      ),
      MuteNotificationDecision.suppressed,
    );
  });

  test('enabled exception types and followed senders still notify', () {
    const settings = MuteExceptionSettings(
      muted: true,
      notifyMentionMe: true,
      notifyMentionAll: true,
      notifyAnnouncement: true,
      followedMemberIds: ['@a:test'],
    );
    for (final facts in [
      const MuteEventFacts(senderId: '@x:test', mentionsMe: true),
      const MuteEventFacts(senderId: '@x:test', mentionsAll: true),
      const MuteEventFacts(senderId: '@x:test', isAnnouncement: true),
      const MuteEventFacts(senderId: '@a:test'),
    ]) {
      expect(
        evaluateMuteNotification(settings, facts),
        MuteNotificationDecision.exception,
      );
    }
  });
}
