import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/local_search_event_policy.dart';

EventUpdate update(EventUpdateType type, String id,
        {String eventType = 'm.room.message',
        Map<String, dynamic> content = const {}}) =>
    EventUpdate(roomID: '!room:test', type: type, content: {
      'event_id': id,
      'type': eventType,
      'content': content,
    });

void main() {
  test(
      'ordinary new events and their near-term decryptions do not restart search',
      () {
    final policy = LocalSearchEventPolicy();
    expect(policy.classify(update(EventUpdateType.timeline, 'fresh')),
        LocalSearchEventEffect.append);
    expect(
        policy
            .classify(update(EventUpdateType.decryptedTimelineQueue, 'fresh')),
        LocalSearchEventEffect.append);
    expect(policy.classify(update(EventUpdateType.ephemeral, 'receipt')),
        LocalSearchEventEffect.none);
    expect(policy.classify(update(EventUpdateType.accountData, 'account')),
        LocalSearchEventEffect.none);
    expect(policy.classify(update(EventUpdateType.state, 'state')),
        LocalSearchEventEffect.none);
    expect(policy.classify(update(EventUpdateType.inviteState, 'invite')),
        LocalSearchEventEffect.none);
  });

  test(
      'withdrawal, replacement and unknown updates invalidate; history progresses',
      () {
    final policy = LocalSearchEventPolicy();
    expect(
        policy.classify(update(EventUpdateType.timeline, 'redaction',
            eventType: 'm.room.redaction', content: {'redacts': 'old'})),
        LocalSearchEventEffect.invalidate);
    expect(
        policy.classify(update(EventUpdateType.timeline, 'edit', content: {
          'm.relates_to': {'rel_type': 'm.replace'}
        })),
        LocalSearchEventEffect.invalidate);
    expect(policy.classify(update(EventUpdateType.history, 'older')),
        LocalSearchEventEffect.append);
    expect(
        policy.classify(update(EventUpdateType.decryptedTimelineQueue, 'old')),
        LocalSearchEventEffect.append);
    expect(policy.classify(update(EventUpdateType.timeline, '')),
        LocalSearchEventEffect.invalidate);
    expect(policy.classify(update(EventUpdateType.timeline, 'new')),
        LocalSearchEventEffect.append);
    expect(policy.classify(update(EventUpdateType.timeline, 'new')),
        LocalSearchEventEffect.invalidate);
    policy.clear();
    expect(
        policy.classify(update(EventUpdateType.decryptedTimelineQueue, 'new')),
        LocalSearchEventEffect.append);
  });

  test('historical redacted rows revoke even during pagination or decryption',
      () {
    for (final type in [
      EventUpdateType.history,
      EventUpdateType.decryptedTimelineQueue
    ]) {
      final policy = LocalSearchEventPolicy();
      expect(
          policy.classify(
              EventUpdate(roomID: '!synthetic:test', type: type, content: {
            'event_id': 'redacted',
            'type': EventTypes.Message,
            'unsigned': {
              'redacted_because': {'event_id': 'recall'}
            },
            'content': <String, dynamic>{}
          })),
          LocalSearchEventEffect.invalidate);
    }
  });
}
