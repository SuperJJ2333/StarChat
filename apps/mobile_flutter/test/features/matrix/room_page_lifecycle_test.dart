import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_page.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_service.dart';
import 'package:liuhetong_mobile/features/matrix/group_room_authority.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';
import 'package:liuhetong_mobile/ui/motion/motion_page_route.dart';

import 'profile_repository_test.dart' show MemoryProfileStore;

class _LifecycleClient extends Client {
  _LifecycleClient({http.Client? httpClient})
      : super('synthetic-room-lifecycle', httpClient: httpClient);
  @override
  String? get userID => '@self:lifecycle.test';
  late final _LifecycleRoom localRoom = _LifecycleRoom(client: this);
  @override
  Room? getRoomById(String roomId) => roomId == localRoom.id ? localRoom : null;
}

class _LifecycleTimeline extends Fake implements Timeline {
  _LifecycleTimeline(this.events);
  @override
  final List<Event> events;
  @override
  bool get isFragmentedTimeline => false;
  @override
  bool get canRequestFuture => false;
  @override
  bool get canRequestHistory => false;
  @override
  Future<void> setReadMarker({String? eventId, bool? public}) async =>
      throw const SocketException('synthetic offline read receipt');
  @override
  void cancelSubscriptions() {}
}

class _LifecycleRoom extends Room {
  _LifecycleRoom({required super.client}) : super(id: '!lifecycle:test');
  late final timeline = _LifecycleTimeline(List.generate(
      1200,
      (i) => Event(
              room: this,
              eventId: 'synthetic-${1199 - i}',
              senderId: '@peer:lifecycle.test',
              type: EventTypes.Message,
              originServerTs:
                  DateTime.utc(2026, 10, 7).add(Duration(minutes: 1199 - i)),
              content: {
                'msgtype': 'm.text',
                'body':
                    'row ${1199 - i} ${List.filled(i % 6 + 1, 'height').join('\n')}'
              })));
  void Function()? update;
  Timeline? realTimeline;
  bool direct = true;
  Future<Event?>? pendingAnnouncement;
  @override
  bool get isDirectChat => direct;
  @override
  String? get directChatMatrixID => direct ? '@peer:lifecycle.test' : null;
  @override
  Future<Event?> getEventById(String eventID) =>
      eventID == r'$synthetic-announcement' && pendingAnnouncement != null
          ? pendingAnnouncement!
          : super.getEventById(eventID);
  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
  }) async {
    update = onUpdate;
    return realTimeline ?? timeline;
  }
}

Future<MatrixRoomLease> _mountLifecycleRoom(
    WidgetTester tester, _LifecycleClient client,
    {bool pushRoute = false}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  SharedPreferences.setMockInitialValues({});
  final matrix = MatrixSdkE2eeClient(client,
      homeserver: Uri.parse('https://lifecycle.test'),
      readContinuityMetadata: client.localRoom.realTimeline == null
          ? null
          : (active) async => MatrixClientContinuityMetadata(
              isLoggedIn: active.isLogged(),
              userId: active.userID,
              deviceId: active.deviceID,
              ed25519Fingerprint: 'synthetic-fingerprint',
              databaseGeneration: 'synthetic-generation'));
  final lease = await matrix.openRoomLease(client.localRoom.id);
  ConversationReadState.shared()
    ..resetForTest()
    ..bindAccount(client.userID);
  final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((_) async => http.Response('{}', 503)));
  final page = RoomPage(
      api: api,
      roomLease: lease,
      roomName: 'Synthetic lifecycle',
      initialIdentityCache: ProfileRepository.forTesting(
          accountKey: 'synthetic-lifecycle', store: MemoryProfileStore()),
      onCreateGroup: () {});
  await tester.pumpWidget(CupertinoApp(
      home: pushRoute
          ? CupertinoPageScaffold(
              child: Builder(
                  builder: (context) => Center(
                      child: CupertinoButton(
                          key: const Key('open-synthetic-room'),
                          onPressed: () => Navigator.of(context).push(
                              MotionPageRoute<void>(builder: (_) => page)),
                          child: const Text('Open')))))
          : page));
  if (pushRoute) {
    await tester.tap(find.byKey(const Key('open-synthetic-room')));
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return lease;
}

void main() {
  setUp(() => ConversationReadState.shared().resetForTest());
  tearDown(() => ConversationReadState.shared().resetForTest());

  testWidgets(
      'fast history flicks and visibility timers keep one mounted scroll view',
      (tester) async {
    final client = _LifecycleClient();
    final lease = await _mountLifecycleRoom(tester, client);
    final listFinder = find.byType(AnchoredTimelineList);
    final scroll = tester.widget<AnchoredTimelineList>(listFinder).controller;
    for (var round = 0; round < 12; round++) {
      final gesture = await tester.startGesture(tester.getCenter(listFinder));
      for (var move = 0; move < 8; move++) {
        await gesture.moveBy(const Offset(0, 470));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      for (var settle = 0;
          settle < 300 && scroll.position.isScrollingNotifier.value;
          settle++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull,
          reason: 'history round $round must not leave inactive keyed rows');
      expect(scroll.positions.length, 1);
    }
    await tester.pumpWidget(const SizedBox());
    await lease.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'return to latest after older windows preserves keyed inherited rows',
      (tester) async {
    final client = _LifecycleClient();
    final lease = await _mountLifecycleRoom(tester, client);
    final state = tester.state(find.byType(RoomPage)) as dynamic;
    final timeline = state.controller as RoomTimelineController;
    for (var round = 0; round < 8; round++) {
      expect(await timeline.openAnchor('synthetic-300'), isTrue);
      await tester.pump();
      final listFinder = find.byType(AnchoredTimelineList);
      final scroll = tester.widget<AnchoredTimelineList>(listFinder).controller;
      final gesture = await tester.startGesture(tester.getCenter(listFinder));
      for (var move = 0; move < 45; move++) {
        await gesture.moveBy(const Offset(0, 700));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await gesture.up();
      for (var settle = 0;
          settle < 300 && scroll.position.isScrollingNotifier.value;
          settle++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(timeline.hasLaterWindow, isTrue);
      await tester.tap(find.byKey(const Key('timeline-return-latest')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull,
          reason: 'return round $round must completely retire the old slivers');
      expect(scroll.positions.length, 1);
      expect(timeline.hasLaterWindow, isFalse);
    }
    await tester.pumpWidget(const SizedBox());
    await lease.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'route entry and exit during a mixed media history drag retires the list',
      (tester) async {
    final client = _LifecycleClient();
    final room = client.localRoom;
    for (var i = 0; i < room.timeline.events.length; i++) {
      final prior = room.timeline.events[i];
      if (i % 4 == 0 || i % 4 == 1) {
        room.timeline.events[i] = Event(
            room: room,
            eventId: prior.eventId,
            senderId: prior.senderId,
            type: EventTypes.Message,
            originServerTs: prior.originServerTs,
            content: {
              'msgtype': i % 4 == 0 ? 'm.image' : 'm.video',
              'body': 'synthetic unavailable media',
              'info': {
                'w': 320,
                'h': 240,
                'duration': 1000,
                'mimetype': i % 4 == 0 ? 'image/png' : 'video/mp4'
              }
            });
      }
    }
    final lease = await _mountLifecycleRoom(tester, client, pushRoute: true);
    await tester.pump(const Duration(milliseconds: 500));
    final listFinder = find.byType(AnchoredTimelineList);
    final scroll = tester.widget<AnchoredTimelineList>(listFinder).controller;
    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    for (var i = 0; i < 16; i++) {
      await gesture.moveBy(const Offset(0, 480));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.positions.length, 1);
    Navigator.of(tester.element(find.byType(RoomPage))).pop();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(RoomPage), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await lease.cancel();
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'held genuine history transport and limited sync preserve mounted slivers',
      (tester) async {
    final historyResponse = Completer<http.Response>();
    var historyRequests = 0;
    final client = _LifecycleClient(httpClient: MockClient((request) {
      expect(request.url.path, contains('/context/synthetic-0'));
      historyRequests++;
      return historyResponse.future;
    }))
      ..homeserver = Uri.parse('https://lifecycle.test')
      ..accessToken = 'synthetic-token';
    final room = client.localRoom..prev_batch = 'synthetic-cached-prev';
    client.rooms.add(room);
    room.realTimeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: List.of(room.timeline.events)),
        onUpdate: () => room.update?.call());
    final lease = await _mountLifecycleRoom(tester, client);
    final timeline = (tester.state(find.byType(RoomPage)) as dynamic).controller
        as RoomTimelineController;
    expect(await timeline.openAnchor('synthetic-0'), isTrue);
    await tester.pump();
    final listFinder = find.byType(AnchoredTimelineList);
    final scroll = tester.widget<AnchoredTimelineList>(listFinder).controller;
    scroll.jumpTo(scroll.position.maxScrollExtent - 50);
    await tester.pump();
    final oldCenterKey = tester
        .widget<CustomScrollView>(find.descendant(
            of: listFinder, matching: find.byType(CustomScrollView)))
        .center;
    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    for (var i = 0; i < 5 && historyRequests == 0; i++) {
      await gesture.moveBy(const Offset(0, 500));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(historyRequests, 1);
    await client.handleSync(SyncUpdate.fromJson({
      'next_batch': 'synthetic-limited-sync',
      'rooms': {
        'join': {
          room.id: {
            'timeline': {
              'limited': true,
              'prev_batch': 'synthetic-live-prev',
              'events': [
                {
                  'event_id': 'synthetic-live-newest',
                  'type': EventTypes.Message,
                  'sender': '@peer:lifecycle.test',
                  'origin_server_ts':
                      DateTime.utc(2026, 10, 9).millisecondsSinceEpoch,
                  'content': {'msgtype': 'm.text', 'body': 'synthetic live'}
                }
              ]
            }
          }
        }
      }
    }));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull,
        reason: 'limited sync during a held drag must not break deactivation');
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 16));
    historyResponse.complete(http.Response(
        jsonEncode({
          'start': 'synthetic-history-older',
          'end': 'synthetic-history-newer',
          'event': room.timeline.events.last.toJson(),
          'events_before': List.generate(
              80,
              (index) => {
                    'event_id': 'synthetic-older-$index',
                    'type': EventTypes.Message,
                    'sender': '@peer:lifecycle.test',
                    'origin_server_ts': DateTime.utc(2026, 10, 6)
                        .subtract(Duration(minutes: index))
                        .millisecondsSinceEpoch,
                    'content': {
                      'msgtype': 'm.text',
                      'body': 'synthetic older row $index\nheight\nheight'
                    }
                  }),
          'events_after': [],
        }),
        200));
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull,
          reason: 'history completion frame $i must preserve inherited scopes');
      expect(scroll.positions.length, 1);
      if (!timeline.historyLoading &&
          !scroll.position.isScrollingNotifier.value) {
        break;
      }
    }
    expect(timeline.historyLoading, isFalse);
    expect(timeline.hasEarlierWindow, isTrue);
    await timeline.showEarlierWindow();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
        tester
            .widget<CustomScrollView>(find.descendant(
                of: listFinder, matching: find.byType(CustomScrollView)))
            .center,
        isNot(oldCenterKey),
        reason: 'the old sliver center must actually leave the bounded window');
    expect(lease.oldestTimelineEventId, 'synthetic-older-79');
    expect(room.prev_batch, 'synthetic-live-prev');
    expect(timeline.isViewingHistoryContext, isTrue);
    await tester.tap(find.byKey(const Key('timeline-return-latest')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('synthetic live'), findsOneWidget);
    expect(scroll.positions.length, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await lease.cancel();
    room.realTimeline!.cancelSubscriptions();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  for (final initiallyDirect in [false, true]) {
    testWidgets(
        'group metadata and delayed announcement during drag, initiallyDirect=$initiallyDirect',
        (tester) async {
      final client = _LifecycleClient();
      final room = client.localRoom..direct = initiallyDirect;
      room.setState(User(client.userID!, membership: 'join', room: room));
      room.setState(
          User('@peer:lifecycle.test', membership: 'join', room: room));
      final announcement = Completer<Event?>();
      room.pendingAnnouncement = announcement.future;
      room.setState(Event(
          type: groupAnnouncementStateType,
          content: {'event_id': r'$synthetic-announcement'},
          senderId: '@peer:lifecycle.test',
          room: room,
          eventId: r'$synthetic-reference',
          stateKey: '',
          originServerTs: DateTime.utc(2026, 10, 7)));
      final lease = await _mountLifecycleRoom(tester, client);
      final listFinder = find.byType(AnchoredTimelineList);
      final scroll = tester.widget<AnchoredTimelineList>(listFinder).controller;
      final gesture = await tester.startGesture(tester.getCenter(listFinder));
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(0, 480));
        await tester.pump(const Duration(milliseconds: 16));
      }
      if (initiallyDirect) {
        room.direct = false;
        room.setState(Event(
            type: EventTypes.RoomName,
            content: {'name': 'Synthetic group'},
            senderId: '@peer:lifecycle.test',
            room: room,
            eventId: r'$synthetic-name',
            stateKey: '',
            originServerTs: DateTime.utc(2026, 10, 7)));
        room.update!();
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.byType(GroupAnnouncementBanner), findsOneWidget);
      expect(scroll.positions.length, 1);
      expect(tester.takeException(), isNull,
          reason:
              'inserting the group child before Expanded must reparent cleanly');
      announcement.complete(Event(
          type: EventTypes.Message,
          content: const GroupAnnouncement(
                  [AnnouncementBlock.text('Synthetic delayed announcement')])
              .toContent(),
          senderId: '@peer:lifecycle.test',
          room: room,
          eventId: r'$synthetic-announcement',
          originServerTs: DateTime.utc(2026, 10, 7)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
          find.byKey(const Key('group-announcement-banner')), findsOneWidget);
      expect(scroll.positions.length, 1);
      expect(tester.takeException(), isNull,
          reason:
              'delayed banner resize during drag must preserve inherited scopes');
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpWidget(const SizedBox());
      await lease.cancel();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }
}
