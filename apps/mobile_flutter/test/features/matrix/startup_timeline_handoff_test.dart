import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

void main() {
  test(
      'canonical bounded head updates live and reading fork, preserving newer changes',
      () async {
    final client = Client('handoff')..backgroundSync = false;
    final room = Room(id: '!room:test', client: client);
    Event event(String id, Map<String, dynamic> content) => Event(
        room: room,
        eventId: id,
        type: EventTypes.Message,
        senderId: '@user:test',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(1),
        content: content);
    final image = event('image', {'msgtype': 'm.image', 'body': 'image'});
    final custom = event(
        'custom', {'msgtype': 'com.changliao.red_packet', 'body': '[消息]'});
    final changed = event('changed', {'body': 'baseline'});
    final removed = event('removed', {'body': 'baseline'});
    final live = Timeline(
        room: room,
        chunk: TimelineChunk(events: [image, custom, changed, removed]));
    final fork = Timeline.forkHistory(source: live, room: room);
    final baseline = {for (final e in live.events) e.eventId: e};
    final newer = event('changed', {'body': 'newer local update'});
    live.events[2] = newer;
    live.events.removeLast();
    final pending = event('pending', {'body': 'durable pending'})
      ..status = EventStatus.sending;
    live.events.insert(0, pending);
    final canonicalImage = event('image', {
      'msgtype': 'm.image',
      'file': {
        'url': 'mxc://test/image',
        'key': {'k': 'synthetic'}
      }
    });
    final canonicalCustom = event('custom',
        {'msgtype': 'com.changliao.red_packet', 'packet_id': 'synthetic'});
    final head = [
      event('new', {'body': 'new canonical head'}),
      canonicalImage,
      canonicalCustom,
      event('changed', {'body': 'old canonical'}),
      removed
    ];
    live.reconcileStartupHead(head,
        projectedEvents: baseline,
        historyGeneration: room.historyGeneration,
        isActive: () => true,
        retainedFragments: () => [fork]);
    expect(live.events.first, same(pending));
    expect(live.events.map((e) => e.eventId),
        ['pending', 'new', 'image', 'custom', 'changed']);
    expect(live.events.firstWhere((e) => e.eventId == 'changed'), same(newer));
    expect(live.events.firstWhere((e) => e.eventId == 'image'),
        same(canonicalImage));
    expect(fork.events.map((e) => e.eventId),
        ['image', 'custom', 'changed', 'removed']);
    expect(fork.events.first.content['file'], canonicalImage.content['file']);
    expect(fork.events[1].content['packet_id'], 'synthetic');
    live.reconcileStartupHead(
        [event('disjoint-a', {}), event('disjoint-b', {})],
        projectedEvents: baseline, historyGeneration: 0, isActive: () => true);
    expect(live.events.take(3).map((e) => e.eventId),
        ['pending', 'disjoint-a', 'disjoint-b']);
    final before = live.presentationRevision;
    room.invalidateHistoryFragment();
    live.reconcileStartupHead([event('stale', {})],
        projectedEvents: baseline, historyGeneration: 0, isActive: () => true);
    expect(live.presentationRevision, before);
    live.reconcileStartupHead([event('revoked', {})],
        projectedEvents: baseline, historyGeneration: 1, isActive: () => false);
    expect(live.presentationRevision, before);
    live.cancelSubscriptions();
    fork.cancelSubscriptions();
    await client.dispose();
  });
}
