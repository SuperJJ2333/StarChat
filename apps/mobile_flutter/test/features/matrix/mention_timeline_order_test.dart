import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/unread_mention_tracker.dart';

void main() {
  test(
      'boundary identity, backfill and later sync preserve Matrix order across restore',
      () {
    var state = UnreadMentionTracker(accountId: 'me', roomId: 'room')
      ..initializeEventBoundary('read');
    state.registerTimeline(['new', 'middle']);
    void ingest(String id) => state.onMessageArrived(
        eventId: id,
        order: state.orderFor(id),
        senderIsSelf: false,
        mentionedUserIds: {'me'});
    ingest('new');
    expect(state.hasPending, false,
        reason: 'unknown read boundary must first be resolved');
    state.registerTimeline(['new', 'middle', 'read', 'old']);
    for (final id in ['new', 'middle', 'read', 'old']) {
      ingest(id);
    }
    expect(state.pendingEventIdsNewestFirst(), ['new', 'middle']);
    state.markViewed('new');
    state = UnreadMentionTracker.decode(state.encode())!;
    state.registerTimeline(['latest', 'new', 'middle']);
    for (final id in ['latest', 'new', 'middle']) {
      ingest(id);
    }
    expect(state.pendingEventIdsNewestFirst(), ['latest', 'middle']);
    expect(state.boundaryEventId, 'read');
  });
}
