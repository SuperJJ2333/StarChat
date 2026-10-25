import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/outbox/outbox_message.dart';
import 'package:liuhetong_mobile/features/matrix/message_timeline_cache.dart';
import 'package:liuhetong_mobile/features/matrix/logical_conversation_timeline.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_outgoing_work_coordinator.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'matrix_room_timeline_adapter_test.dart'
    show
        NoticeClient,
        OutgoingRetryClient,
        RetryRoom,
        RetryTimeline,
        RetryEvent,
        openAdapter;
import 'logical_conversation_timeline_test.dart'
    show Source, WindowSource, message;

class _ReplyWindowSource extends WindowSource {
  final resolved = <String, RoomMessageViewModel>{};
  @override
  void enableWindow() => window.update([0, 1]);
  @override
  Future<RoomMessageViewModel?> lookupMessage(String id) async {
    final found = await super.lookupMessage(id);
    if (found != null) resolved[id] = found;
    return found;
  }

  @override
  RoomMessageViewModel? findMessage(String id) =>
      super.findMessage(id) ?? resolved[id];
}

class _BoundaryTimeline extends RetryTimeline {
  bool moreFuture = false;
  @override
  int get presentationRevision => 1;
  @override
  bool get canRequestFuture => moreFuture;
  @override
  Future<void> enableResidentWindow({int maximumEvents = 1000}) async {}
  @override
  Future<void> requestHistory({int historyCount = 20}) async {
    moreHistory = false;
  }
}

class _LookupRoom extends RetryRoom {
  _LookupRoom() : super(client: NoticeClient());
  final requested = Completer<void>();
  final response = Completer<Event?>();
  @override
  Future<Event?> getEventById(String eventID) {
    if (!requested.isCompleted) requested.complete();
    return response.future;
  }
}

RoomMessageViewModel _message(String id) => RoomMessageViewModel(
    id: id,
    senderId: '@peer:test',
    text: 'synthetic fixture',
    isOwn: false,
    deliveryState: RoomDeliveryState.sent,
    timestamp: DateTime.utc(2026));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MessageTimelineCache.shared.clear();
  });
  tearDown(MessageTimelineCache.shared.clear);

  test('legacy lookup capability wrapper reuses an out-of-window reply',
      () async {
    final source = Source([])..remoteMessage = message('cold', -10);
    final controller = RoomTimelineController(MatrixRoomTimelineAdapter(source),
        windowed: true);
    addTearDown(controller.dispose);
    expect((await controller.lookupReplyMessage('cold'))?.id, 'cold');
    expect(controller.findMessage('cold')?.id, 'cold');
    await controller.refresh();
    expect((await controller.lookupReplyMessage('cold'))?.id, 'cold');
    expect(source.lookups, ['cold']);
    controller.setHiddenFilter((id, timestamp) => id == 'cold');
    expect(controller.findMessage('cold'), isNull);
    expect(await controller.lookupReplyMessage('cold'), isNull);
  });

  test('legacy lookup wrapper rejects a result after disposal', () async {
    final source = Source([])
      ..remoteMessage = message('cold', -10)
      ..lookupGate = Completer<void>();
    final adapter = MatrixRoomTimelineAdapter(source)..enableWindow();
    final pending = adapter.lookupMessage('cold');
    adapter.dispose();
    source.lookupGate!.complete();
    expect(await pending, isNull);
    expect(adapter.findMessage('cold'), isNull);
  });

  test('retained room reply stays queryable and respects source invalidation',
      () async {
    final primary = _ReplyWindowSource();
    final retained = _ReplyWindowSource()..remoteMessage = message('cold', -10);
    final logical = LogicalConversationTimelineCapability(
        primaryRoomId: 'primary',
        primary: primary,
        sources: {'retained': retained});
    final controller = RoomTimelineController(
        MatrixRoomTimelineAdapter(logical),
        windowed: true);
    addTearDown(controller.dispose);
    expect(await controller.lookupReplyMessage('cold'), isNotNull);
    expect(controller.findMessage('cold')?.id, 'cold');
    await controller.refresh();
    expect(controller.findMessage('cold')?.id, 'cold');
    expect((await controller.lookupReplyMessage('cold'))?.id, 'cold');
    expect(retained.lookups, ['cold']);
    retained.resolved.clear();
    retained.remoteMessage = null;
    await controller.refresh();
    expect(controller.findMessage('cold'), isNull);
    expect(await controller.lookupReplyMessage('cold'), isNull);
    expect(primary.lookups, ['cold'],
        reason: 'known retained source avoids unrelated requests');
  });

  for (final earlier in [true, false]) {
    test(
        'account pending refreshes when unchanged ${earlier ? 'older' : 'newer'} boundary closes',
        () async {
      final client = OutgoingRetryClient();
      final room = RetryRoom(client: client);
      client.room = room;
      final timeline = _BoundaryTimeline()
        ..moreHistory = earlier
        ..moreFuture = !earlier;
      room.timeline = timeline;
      timeline.events.addAll([
        RetryEvent(room, timeline,
            id: 'new', minute: 20, status: EventStatus.synced),
        RetryEvent(room, timeline,
            id: 'old', minute: 10, status: EventStatus.synced),
      ]);
      final owner = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://test'),
          readContinuityMetadata: (client) async =>
              MatrixClientContinuityMetadata(
                  isLoggedIn: client.isLogged(),
                  userId: client.userID,
                  deviceId: client.deviceID,
                  ed25519Fingerprint: 'fixture',
                  databaseGeneration: 'fixture'));
      final lease = await owner.openRoomLease(room.id);
      final controller = RoomTimelineController(
          MatrixRoomTimelineAdapter(
              await lease.openRoomTimeline(onUpdate: () {})),
          windowed: true);
      addTearDown(controller.dispose);
      addTearDown(client.dispose);
      await owner.outgoingWork.enqueue(MatrixOutgoingWorkJob(
          id: 'work',
          source: MatrixOutgoingWorkSource(
              id: 'source',
              retainedBytes: 0,
              prepare: (_) async {},
              release: () async {}),
          items: [
            MatrixOutgoingWorkItem(
                id: 'item',
                targetRoomId: room.id,
                txid: 'work',
                presentation: MatrixOutgoingWorkPresentation(
                    kind: MatrixOutgoingPresentationKind.text,
                    text: 'synthetic',
                    createdAt: DateTime.utc(2026, 9, 6, 10, earlier ? 5 : 25)),
                send: (_) async => throw StateError('fixture offline'))
          ]));
      await owner.outgoingWork.drain();
      await controller.refresh();
      expect(
          controller.messages.any((m) => m.transactionId == 'work'), isFalse);
      timeline.moreHistory = timeline.moreFuture = false;
      await controller.refresh();
      expect(
          controller.messages.map((m) => m.id),
          earlier
              ? ['outgoing:work', 'old', 'new']
              : ['old', 'new', 'outgoing:work']);
      expect(owner.outgoingWork.itemsForRoom(room.id), hasLength(1));
      timeline.moreHistory = earlier;
      timeline.moreFuture = !earlier;
      await controller.refresh();
      expect(
          controller.messages.any((m) => m.transactionId == 'work'), isFalse);
    });

    test(
        'unchanged rows refresh pending visibility when ${earlier ? 'older' : 'newer'} boundary closes',
        () async {
      final room = RetryRoom();
      final timeline = _BoundaryTimeline()
        ..moreHistory = earlier
        ..moreFuture = !earlier;
      timeline.events.addAll([
        RetryEvent(room, timeline,
            id: 'new', minute: 20, status: EventStatus.synced),
        RetryEvent(room, timeline,
            id: 'old', minute: 10, status: EventStatus.synced),
      ]);
      final controller = RoomTimelineController(
          await openAdapter(room, timeline),
          windowed: true);
      addTearDown(controller.dispose);
      addTearDown(room.client.dispose);
      final created = DateTime.utc(2026, 9, 6, 10, earlier ? 5 : 25);
      controller.restoreOutboxMessage(OutboxMessage(
          localId: 'pending',
          txid: 'pending',
          receiverId: 'fixture',
          content: 'synthetic pending',
          createdAt: created,
          updatedAt: created,
          status: OutboxStatus.failed));
      expect(controller.messages.map((m) => m.id), isNot(contains('pending')));
      timeline.moreHistory = timeline.moreFuture = false;
      await controller.refresh();
      expect(controller.messages.map((m) => m.id),
          earlier ? ['pending', 'old', 'new'] : ['old', 'new', 'pending']);
      expect(
          controller.messages.singleWhere((m) => m.id == 'pending').timestamp,
          created);
      // A changed boundary can also hide it again without changing event rows.
      timeline.moreHistory = earlier;
      timeline.moreFuture = !earlier;
      await controller.refresh();
      expect(controller.messages.map((m) => m.id), isNot(contains('pending')));
    });
  }

  test('reply invalidation rejects a late in-flight result', () async {
    final room = _LookupRoom();
    final timeline = _BoundaryTimeline();
    final adapter = await openAdapter(room, timeline);
    addTearDown(adapter.dispose);
    addTearDown(room.client.dispose);
    adapter.enableWindow();
    final lookup = adapter.lookupMessage('old-reply');
    await room.requested.future;
    room.client.onEvent.add(
        EventUpdate(roomID: room.id, type: EventUpdateType.timeline, content: {
      'event_id': 'redaction',
      'type': EventTypes.Redaction,
      'redacts': 'old-reply',
      'content': <String, dynamic>{},
    }));
    await Future<void>.delayed(Duration.zero);
    room.response.complete(RetryEvent(room, timeline,
        id: 'old-reply', minute: 5, status: EventStatus.synced));
    expect(await lookup, isNull);
    expect(adapter.findMessage('old-reply'), isNull);
    expect(MessageTimelineCache.shared.length, 0);
  });

  for (final nested in [false, true]) {
    test(
        'old reply cache is invalidated by ${nested ? 'nested' : 'legacy'} redaction without clearing other rooms',
        () async {
      final room = RetryRoom(client: NoticeClient());
      final adapter = await openAdapter(room, _BoundaryTimeline());
      addTearDown(adapter.dispose);
      addTearDown(room.client.dispose);
      adapter.enableWindow();
      final cache = MessageTimelineCache.shared;
      cache.remember('@me:test', room.id, _message('old-reply'));
      cache.remember('@me:test', '!other:test', _message('old-reply'));
      cache.remember('@other:test', room.id, _message('old-reply'));
      expect(adapter.findMessage('old-reply'), isNotNull);
      room.client.onEvent.add(EventUpdate(
          roomID: room.id,
          type: EventUpdateType.timeline,
          content: {
            'event_id': 'redaction',
            'type': EventTypes.Redaction,
            'sender': '@peer:test',
            'origin_server_ts': 1000,
            if (!nested) 'redacts': 'old-reply',
            'content': {if (nested) 'redacts': 'old-reply'},
          }));
      await Future<void>.delayed(Duration.zero);
      expect(adapter.findMessage('old-reply'), isNull);
      expect(cache.lookup('@me:test', '!other:test', 'old-reply'), isNotNull);
      expect(cache.lookup('@other:test', room.id, 'old-reply'), isNotNull);
    });
  }

  test('closed room reply cache observes account redactions before reentry',
      () async {
    final room = RetryRoom(client: NoticeClient());
    final first = await openAdapter(room, _BoundaryTimeline());
    first.enableWindow();
    MessageTimelineCache.shared
        .remember('@me:test', room.id, _message('old-reply'));
    first.dispose();
    room.client.onEvent.add(
        EventUpdate(roomID: room.id, type: EventUpdateType.timeline, content: {
      'event_id': 'redaction',
      'type': EventTypes.Redaction,
      'redacts': 'old-reply',
      'content': <String, dynamic>{}
    }));
    await Future<void>.delayed(Duration.zero);
    final reopened = await openAdapter(room, _BoundaryTimeline());
    addTearDown(reopened.dispose);
    addTearDown(room.client.dispose);
    reopened.enableWindow();
    expect(reopened.findMessage('old-reply'), isNull);
  });

  test('controller cannot revive an invalidated resolved reply', () async {
    final room = _LookupRoom();
    final timeline = _BoundaryTimeline();
    final adapter = await openAdapter(room, timeline);
    final controller = RoomTimelineController(adapter, windowed: true);
    addTearDown(controller.dispose);
    addTearDown(room.client.dispose);
    room.response.complete(RetryEvent(room, timeline,
        id: 'old-reply', minute: 5, status: EventStatus.synced));
    expect(await controller.lookupReplyMessage('old-reply'), isNotNull);
    room.client.onEvent.add(
        EventUpdate(roomID: room.id, type: EventUpdateType.timeline, content: {
      'event_id': 'redaction',
      'type': EventTypes.Redaction,
      'redacts': 'old-reply',
      'content': <String, dynamic>{}
    }));
    await Future<void>.delayed(Duration.zero);
    await controller.refresh();
    expect(controller.findMessage('old-reply'), isNull);
  });

  test('hidden history does not return a cached reply or resolved event',
      () async {
    final room = _LookupRoom();
    final timeline = _BoundaryTimeline();
    final adapter = await openAdapter(room, timeline);
    final controller = RoomTimelineController(adapter, windowed: true);
    addTearDown(controller.dispose);
    addTearDown(room.client.dispose);
    room.response.complete(RetryEvent(room, timeline,
        id: 'old-reply', minute: 5, status: EventStatus.synced));
    expect(await controller.lookupReplyMessage('old-reply'), isNotNull);
    MessageTimelineCache.shared
        .remember('@me:test', room.id, _message('other-old'));
    controller.setHiddenFilter((id, timestamp) => true);
    await controller.refresh();
    expect(controller.findMessage('old-reply'), isNull);
    expect(controller.findMessage('other-old'), isNull);
    expect(await adapter.lookupMessage('old-reply'), isNull);
  });

  test('replacement invalidates its old reply target but not other rooms',
      () async {
    final room = RetryRoom(client: NoticeClient());
    final adapter = await openAdapter(room, _BoundaryTimeline());
    addTearDown(adapter.dispose);
    addTearDown(room.client.dispose);
    adapter.enableWindow();
    MessageTimelineCache.shared
        .remember('@me:test', room.id, _message('old-reply'));
    MessageTimelineCache.shared
        .remember('@me:test', '!other:test', _message('old-reply'));
    room.client.onEvent.add(
        EventUpdate(roomID: room.id, type: EventUpdateType.timeline, content: {
      'event_id': 'edit',
      'type': EventTypes.Message,
      'content': {
        'm.relates_to': {'rel_type': 'm.replace', 'event_id': 'old-reply'}
      }
    }));
    await Future<void>.delayed(Duration.zero);
    expect(adapter.findMessage('old-reply'), isNull);
    expect(
        MessageTimelineCache.shared
            .lookup('@me:test', '!other:test', 'old-reply'),
        isNotNull);
  });

  test('hot reply reads retain their cache entry under group chat churn', () {
    final cache = MessageTimelineCache.shared;
    cache.remember('@me:test', '!group:test', _message('hot'));
    for (var i = 0; i < cache.capacity - 1; i++) {
      cache.remember('@me:test', '!group:test', _message('cold-$i'));
    }
    expect(cache.lookup('@me:test', '!group:test', 'hot'), isNotNull);
    cache.remember('@me:test', '!group:test', _message('new'));
    expect(cache.lookup('@me:test', '!group:test', 'hot'), isNotNull);
    expect(cache.lookup('@me:test', '!group:test', 'cold-0'), isNull);
    expect(cache.length, cache.capacity);
  });
}
