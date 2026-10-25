import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart'
    show changliaoCallMessageType;
import 'package:liuhetong_mobile/ui/chat/wechat_call_bubble.dart';
import 'package:liuhetong_mobile/features/finance/finance_message_entry.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_page.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_service.dart';
import 'package:liuhetong_mobile/features/matrix/group_room_authority.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/message_timeline_cache.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';
import 'package:liuhetong_mobile/ui/motion/motion_page_route.dart';

import 'profile_repository_test.dart' show MemoryProfileStore;

class _RetryMentionPreferences extends InMemorySharedPreferencesStore {
  _RetryMentionPreferences() : super.empty();
  bool failing = true;
  int attempts = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.contains('chat-mentions-v2:')) {
      attempts++;
      if (failing) throw StateError('synthetic transient preference failure');
    }
    return super.setValue(valueType, key, value);
  }
}

class _DelayedMentionPreferences extends InMemorySharedPreferencesStore {
  _DelayedMentionPreferences() : super.empty();
  final release = Completer<void>();
  bool requested = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.contains('chat-mentions-v2:')) {
      requested = true;
      await release.future;
    }
    return super.setValue(valueType, key, value);
  }
}

class _LifecycleClient extends Client {
  _LifecycleClient({http.Client? httpClient})
      : super('synthetic-room-lifecycle', httpClient: httpClient);
  @override
  String? get userID => '@self:lifecycle.test';
  late final _LifecycleRoom localRoom = _LifecycleRoom(client: this);
  @override
  Room? getRoomById(String roomId) => roomId == localRoom.id ? localRoom : null;
}

class _CachedDatabase extends Fake implements DatabaseApi {
  late List<Event> events;
  @override
  Future<User?> getUser(String userId, Room room) async => null;
  @override
  Future<List<Event>> getEventList(Room room,
          {int start = 0, bool onlySending = false, int? limit}) async =>
      events.skip(start).take(limit ?? 40).toList();
}

class _CachedClient extends _LifecycleClient {
  final store = _CachedDatabase();
  @override
  DatabaseApi get database => store;
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
  void cancelSubscriptions() {
    cancelCount++;
  }

  int cancelCount = 0;
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
  Completer<Timeline>? heldTimeline;
  bool direct = true;
  Future<Event?>? pendingAnnouncement;
  final replyEvents = <String, Event?>{};
  int replyLookups = 0;
  @override
  bool get isDirectChat => direct;
  @override
  String? get directChatMatrixID => direct ? '@peer:lifecycle.test' : null;
  @override
  Future<Event?> getEventById(String eventID) {
    if (replyEvents.containsKey(eventID)) {
      replyLookups++;
      return Future.value(replyEvents[eventID]);
    }
    return eventID == r'$synthetic-announcement' && pendingAnnouncement != null
        ? pendingAnnouncement!
        : super.getEventById(eventID);
  }

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
    return heldTimeline == null
        ? realTimeline ?? timeline
        : await heldTimeline!.future;
  }
}

class _RetryMentionClient extends _LifecycleClient {
  @override
  String? get userID => '@retry-mention:synthetic.test';
}

class _RetiredMentionClient extends _LifecycleClient {
  @override
  String? get userID => '@retired-mention:synthetic.test';
}

class _MetadataLifecycleClient extends _LifecycleClient {
  _MetadataLifecycleClient(this.initiallyDirect);
  final bool initiallyDirect;
  @override
  String? get userID => '@metadata-$initiallyDirect:lifecycle.test';
}

Future<MatrixRoomLease> _mountLifecycleRoom(
    WidgetTester tester, _LifecycleClient client,
    {bool pushRoute = false,
    ValueNotifier<bool>? dispatchReady,
    ContactDetails? initialContact,
    List<String>? businessRequests,
    SharedPreferencesStorePlatform? preferences}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  SharedPreferences.setMockInitialValues({});
  if (preferences != null) {
    SharedPreferencesStorePlatform.instance = preferences;
  }
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
      client: MockClient((request) async {
        businessRequests?.add(request.url.path);
        return http.Response('{}', 503);
      }));
  final page = RoomPage(
      api: api,
      dispatchReady: dispatchReady,
      initialContact: initialContact,
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

  for (final change in ['redaction', 'hidden', 'replacement']) {
    testWidgets('quote card drops stale resolved content after $change',
        (tester) async {
      MessageTimelineCache.shared.clear();
      final client = _LifecycleClient();
      final room = client.localRoom;
      Event target(String body) => Event(
          room: room,
          eventId: 'archived-reply',
          senderId: '@peer:lifecycle.test',
          type: EventTypes.Message,
          originServerTs: DateTime.utc(2026, 9, 1),
          content: {'msgtype': 'm.text', 'body': body});
      room.replyEvents['archived-reply'] = target('old secret');
      room.timeline.events
        ..clear()
        ..add(Event(
            room: room,
            eventId: 'reply-row',
            senderId: '@peer:lifecycle.test',
            type: EventTypes.Message,
            originServerTs: DateTime.utc(2026, 10, 1),
            content: {
              'msgtype': 'm.text',
              'body': 'visible reply',
              'm.relates_to': {
                'm.in_reply_to': {'event_id': 'archived-reply'}
              }
            }));
      final lease = await _mountLifecycleRoom(tester, client);
      try {
        await tester.pump(const Duration(milliseconds: 100));
        final page = tester.state(find.byType(RoomPage)) as dynamic;
        expect(find.textContaining('old secret'), findsOneWidget);
        expect(room.replyLookups, 1);
        await page.controller.refresh();
        await tester.pump(const Duration(milliseconds: 100));
        expect(room.replyLookups, 1,
            reason: 'unchanged refresh must reuse the reply');
        if (change == 'hidden') {
          page.controller.setHiddenFilter(
              (String id, DateTime? timestamp) => id == 'archived-reply');
        } else {
          room.replyEvents['archived-reply'] =
              change == 'replacement' ? target('new text') : null;
          client.onEvent.add(EventUpdate(
              roomID: room.id,
              type: EventUpdateType.timeline,
              content: {
                'event_id': 'change',
                'type': change == 'redaction'
                    ? EventTypes.Redaction
                    : EventTypes.Message,
                if (change == 'redaction') 'redacts': 'archived-reply',
                'content': {
                  if (change == 'replacement')
                    'm.relates_to': {
                      'rel_type': 'm.replace',
                      'event_id': 'archived-reply'
                    }
                }
              }));
          await tester.pump();
        }
        await page.controller.refresh();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.textContaining('old secret'), findsNothing);
        expect(
            change == 'replacement'
                ? find.textContaining('new text')
                : find.text('原消息不存在或已被删除'),
            findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await lease.cancel();
        await client.dispose();
      }
    });
  }

  test('prepared room transfers once and abandoned entry closes once',
      () async {
    SharedPreferences.setMockInitialValues({});
    final client = _LifecycleClient();
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://lifecycle.test'));
    final lease = await matrix.openRoomLease(client.localRoom.id);
    final entry = await PreparedRoomPageEntry.prepare(lease);
    entry.dispose();
    entry.dispose();
    expect(client.localRoom.timeline.cancelCount, 1);
    expect(() => entry.adopt(lease, () {}), throwsStateError);
    await lease.cancel();
    expect(client.localRoom.timeline.cancelCount, 1);
    await client.dispose();
  });

  test('prepared room adoption leaves disposal with the active page owner',
      () async {
    SharedPreferences.setMockInitialValues({});
    final client = _LifecycleClient();
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://lifecycle.test'));
    final lease = await matrix.openRoomLease(client.localRoom.id);
    final entry = await PreparedRoomPageEntry.prepare(lease);
    final timeline = entry.adopt(lease, () {});
    entry.dispose();
    expect(client.localRoom.timeline.cancelCount, 0);
    expect(() => entry.adopt(lease, () {}), throwsStateError);
    timeline.dispose();
    await lease.cancel();
    expect(client.localRoom.timeline.cancelCount, 1);
    await client.dispose();
  });

  testWidgets(
      'cached finance and call readiness change while optional hydration is held',
      (tester) async {
    final client = _CachedClient();
    client.store.events = [
      Event(
          room: client.localRoom,
          eventId: 'finance',
          senderId: '@peer:lifecycle.test',
          type: EventTypes.Message,
          originServerTs: DateTime.utc(2026, 10, 7),
          content: {
            'msgtype': changliaoRedPacketMessageType,
            'packet_id': 'packet-test',
            'body': 'packet'
          }),
      Event(
          room: client.localRoom,
          eventId: 'call',
          senderId: '@peer:lifecycle.test',
          type: EventTypes.Message,
          originServerTs: DateTime.utc(2026, 10, 7),
          content: {'msgtype': changliaoCallMessageType, 'body': 'call'}),
    ];
    client.localRoom.heldTimeline = Completer<Timeline>();
    final ready = ValueNotifier(false);
    final lease = await _mountLifecycleRoom(tester, client,
        dispatchReady: ready,
        initialContact: const ContactDetails(
            userId: 'peer',
            username: 'peer',
            matrixUserId: '@peer:lifecycle.test'));
    try {
      final page = tester.state(find.byType(RoomPage)) as dynamic;
      final controller = page.controller;
      final scroll = tester
          .widget<AnchoredTimelineList>(find.byType(AnchoredTimelineList))
          .controller;
      final offset = scroll.offset;
      expect(find.byType(FinanceMessageEntry), findsNothing);
      expect(
          tester
              .widget<WeChatCallBubble>(find.byType(WeChatCallBubble))
              .onRedial,
          isNull);
      ready.value = true;
      await tester.pump();
      expect(find.byType(FinanceMessageEntry), findsOneWidget);
      expect(
          tester
              .widget<WeChatCallBubble>(find.byType(WeChatCallBubble))
              .onRedial,
          isNotNull);
      ready.value = false;
      await tester.pump();
      expect(find.byType(FinanceMessageEntry), findsNothing);
      expect(find.text('状态未知'), findsOneWidget);
      expect(
          tester
              .widget<WeChatCallBubble>(find.byType(WeChatCallBubble))
              .onRedial,
          isNull);
      expect(identical(page.controller, controller), isTrue);
      expect(scroll.offset, offset);
      expect(controller.messages.map((RoomMessageViewModel m) => m.id),
          containsAll(['finance', 'call']));
    } finally {
      client.localRoom.heldTimeline!.complete(client.localRoom.timeline);
      await tester.pumpWidget(const SizedBox());
      await lease.cancel();
      ready.dispose();
    }
  });

  testWidgets('cached bubbles paint and scroll while full timeline is held',
      (tester) async {
    final client = _CachedClient();
    client.store.events = client.localRoom.timeline.events;
    client.localRoom.heldTimeline = Completer<Timeline>();
    final ready = ValueNotifier(false);
    final businessRequests = <String>[];
    final lease = await _mountLifecycleRoom(tester, client,
        dispatchReady: ready, businessRequests: businessRequests);
    expect(businessRequests, isEmpty,
        reason: 'local-only room must not call business APIs');
    expect(
        tester
            .widget<CupertinoButton>(find.byKey(const Key('chat-details')))
            .onPressed,
        isNull);
    final page = tester.state(find.byType(RoomPage)) as dynamic;
    expect(page.controller, isNotNull);
    expect(page.controller.messages.length, 40);
    expect(find.text('正在读取本机消息…'), findsNothing);
    ready.value = true;
    expect(page.controller.canDispatchNow(), isTrue,
        reason:
            'optional SDK history hydration cannot block authorized dispatch');
    ready.value = false;
    await page.hiddenEvents.hide(lease.roomId, 'synthetic-1199');
    page.controller.setHiddenFilter(page.hiddenEvents.readFilter(lease.roomId));
    await page.controller.refresh();
    await tester.pump();
    expect(
        page.controller.messages
            .any((RoomMessageViewModel m) => m.id == 'synthetic-1199'),
        isFalse);
    final list = find.byType(AnchoredTimelineList);
    expect(list, findsOneWidget);
    final scroll = tester.widget<AnchoredTimelineList>(list).controller;
    scroll.jumpTo(100);
    await tester.pump();
    final anchored = tester.widget<AnchoredTimelineList>(list);
    final bounds = tester.getRect(find.byType(CustomScrollView).first);
    final retainedId = anchored.eventIds.firstWhere((id) {
      final key = anchored.messageKeys[id];
      if (key == null || find.byKey(key).evaluate().isEmpty) {
        return false;
      }
      final rect = tester.getRect(find.byKey(key));
      return rect.top >= bounds.top && rect.bottom <= bounds.bottom;
    });
    final retainedRow = find.byKey(anchored.messageKeys[retainedId]!);
    final position = tester.getBottomLeft(retainedRow).dy;
    client.localRoom.heldTimeline!.complete(client.localRoom.timeline);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
        identical(page.controller,
            (tester.state(find.byType(RoomPage)) as dynamic).controller),
        isTrue);
    expect(tester.getBottomLeft(retainedRow).dy, closeTo(position, 1));
    expect(
        page.controller.messages
            .any((RoomMessageViewModel m) => m.id == 'synthetic-1199'),
        isFalse);
    expect(page.controller.canDispatchNow(), isFalse);
    ready.value = true;
    await tester.pump();
    expect(page.controller.canDispatchNow(), isTrue);
    await tester.pumpWidget(const SizedBox());
    await lease.cancel();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'pending local history keeps room canvas then paints bounded recent rows',
      (tester) async {
    final client = _LifecycleClient();
    client.localRoom.heldTimeline = Completer<Timeline>();
    final lease = await _mountLifecycleRoom(tester, client);
    expect(find.byKey(const Key('room-history-pending')), findsOneWidget);
    expect(find.text('正在读取本机消息…'), findsNothing);
    expect(find.text('暂无消息'), findsNothing);
    client.localRoom.heldTimeline!.complete(client.localRoom.timeline);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final page = tester.state(find.byType(RoomPage)) as dynamic;
    expect(page.controller.messages.length, 40);
    expect(find.text('正在读取本机消息…'), findsNothing);
    expect(find.textContaining('row 1199'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await lease.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('retired lease cannot publish pending local timeline',
      (tester) async {
    final client = _RetiredMentionClient();
    client.localRoom.heldTimeline = Completer<Timeline>();
    final lease = await _mountLifecycleRoom(tester, client);
    unawaited(lease.cancel());
    client.localRoom.heldTimeline!.complete(client.localRoom.timeline);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final page = tester.state(find.byType(RoomPage)) as dynamic;
    expect(page.controller, isNull);
    expect(page.errorMessage, isNull);
    expect(find.textContaining('row 1199'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await lease.cancel();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('failed initial history can retry without reopening the room',
      (tester) async {
    final client = _LifecycleClient();
    client.localRoom.heldTimeline = Completer<Timeline>();
    final lease = await _mountLifecycleRoom(tester, client);
    client.localRoom.heldTimeline!
        .completeError(StateError('local read failed'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('本机消息暂时无法读取'), findsOneWidget);
    client.localRoom.heldTimeline = null;
    await tester.tap(find.text('重试读取'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('row 1199'), findsOneWidget);
    expect(find.text('本机消息暂时无法读取'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await lease.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('deferred mention bootstrap retries after a timeline update',
      (tester) async {
    final client = _RetryMentionClient();
    client.localRoom.direct = false;
    final preferences = _RetryMentionPreferences();
    final lease =
        await _mountLifecycleRoom(tester, client, preferences: preferences);
    final page = tester.state(find.byType(RoomPage)) as dynamic;
    expect(page.controller, isNotNull);
    expect(page.unreadMentions, isNull);
    expect(preferences.attempts, greaterThan(0));
    preferences.failing = false;
    client.localRoom.timeline.events.insert(
        0,
        Event(
            room: client.localRoom,
            eventId: 'synthetic-after-preference-recovery',
            senderId: '@peer:lifecycle.test',
            type: EventTypes.Message,
            originServerTs: DateTime.utc(2026, 10, 9),
            content: {
              'msgtype': 'm.text',
              'body': 'synthetic recovered update'
            }));
    client.localRoom.update?.call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final restored = page.unreadMentions != null;
    await tester.pumpWidget(const SizedBox());
    await lease.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(restored, isTrue,
        reason: 'transient optional storage failure must not disable mentions');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'cached group bubbles render while mention persistence is pending',
      (tester) async {
    final client = _LifecycleClient();
    client.localRoom.direct = false;
    final preferences = _DelayedMentionPreferences();
    final lease =
        await _mountLifecycleRoom(tester, client, preferences: preferences);
    await tester.pump(const Duration(milliseconds: 100));
    final page = tester.state(find.byType(RoomPage)) as dynamic;
    final hasCachedController = page.controller != null;
    final hasCachedList =
        find.byType(AnchoredTimelineList).evaluate().isNotEmpty;
    // Release even on RED so teardown does not leave a live pending operation.
    preferences.release.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await lease.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(preferences.requested, isTrue);
    expect(hasCachedController, isTrue,
        reason:
            'optional mention writes must not gate cached timeline hydration');
    expect(hasCachedList, isTrue,
        reason:
            'cached bubbles must reach the rendered scroll list before writes');
    expect(tester.takeException(), isNull);
  });

  testWidgets('retired room cannot publish a held mention bootstrap',
      (tester) async {
    final client = _RetiredMentionClient();
    client.localRoom.direct = false;
    final preferences = _DelayedMentionPreferences();
    final lease =
        await _mountLifecycleRoom(tester, client, preferences: preferences);
    final page = tester.state(find.byType(RoomPage)) as dynamic;
    expect(page.controller, isNotNull);
    expect(page.unreadMentions, isNull);
    expect(preferences.requested, isTrue);
    await tester.pumpWidget(const SizedBox());
    preferences.release.complete();
    await tester.pump();
    await lease.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(page.unreadMentions, isNull,
        reason: 'late completion must not attach a retired room listener');
    expect(tester.takeException(), isNull);
  });

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
      // Each widget test owns a FakeAsync zone. Do not reuse a completed
      // singleton mention Future created in another test's retired zone.
      final client = _MetadataLifecycleClient(initiallyDirect);
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
