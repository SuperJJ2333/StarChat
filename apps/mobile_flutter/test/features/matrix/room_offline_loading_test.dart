import 'dart:io';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'profile_repository_test.dart' show MemoryProfileStore;

class _OfflineClient extends Client {
  _OfflineClient() : super('offline-room-fixture');
  @override
  String? get userID => '@self:offline.test';
  late final _OfflineRoom localRoom = _OfflineRoom(client: this);
  GetEventByTimestampResponse? timestampResult;
  @override
  Room? getRoomById(String roomId) => roomId == localRoom.id ? localRoom : null;
  @override
  Future<GetEventByTimestampResponse> getEventByTimestamp(
          String roomId, int timestamp, Direction direction) async =>
      timestampResult!;
}

class _OfflineTimeline extends Fake implements Timeline {
  _OfflineTimeline(Room room)
      : events = [
          Event(
            room: room,
            eventId: 'cached-event',
            senderId: '@peer:offline.test',
            type: EventTypes.Message,
            originServerTs: DateTime.utc(2026, 9, 10),
            content: {'msgtype': 'm.text', 'body': 'cached offline message'},
          )
        ];
  @override
  final List<Event> events;
  @override
  bool get isFragmentedTimeline => false;
  bool futureAvailable = false;
  Completer<void>? pendingFuture;
  int futureRequests = 0;
  Future<void> Function()? onFuture;
  @override
  bool get canRequestFuture => futureAvailable;
  @override
  Future<void> requestFuture(
      {int historyCount = Room.defaultHistoryCount}) async {
    futureRequests++;
    final pending = pendingFuture;
    if (pending != null) await pending.future;
    await onFuture?.call();
  }

  int readAttempts = 0;
  bool offline = true;
  Future<void> Function()? historyLoader;
  int historyRequests = 0;
  Completer<void>? pendingReceipt;
  @override
  bool get canRequestHistory => historyLoader != null;
  @override
  Future<void> requestHistory(
      {int historyCount = Room.defaultHistoryCount}) async {
    historyRequests++;
    await historyLoader?.call();
  }

  @override
  Future<void> setReadMarker({String? eventId, bool? public}) async {
    readAttempts++;
    if (pendingReceipt != null) await pendingReceipt!.future;
    if (offline) {
      throw const SocketException('synthetic offline receipt failure');
    }
  }

  @override
  void cancelSubscriptions() {}
}

class _OfflineRoom extends Room {
  _OfflineRoom({required super.client}) : super(id: '!cached:offline.test');
  late final _OfflineTimeline localTimeline = _OfflineTimeline(this);
  _OfflineTimeline? contextTimeline;
  void Function()? update;
  bool failTimeline = false;
  @override
  bool get isDirectChat => true;
  @override
  String? get directChatMatrixID => '@peer:offline.test';
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
    if (failTimeline) {
      throw const SocketException('synthetic local open failure');
    }
    if (eventContextId != null) return contextTimeline!;
    return localTimeline;
  }
}

Future<MatrixRoomLease> _mount(WidgetTester tester, _OfflineClient client,
    {bool friend = false, ScrollBehavior? scrollBehavior}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  SharedPreferences.setMockInitialValues({});
  final matrix = MatrixSdkE2eeClient(client,
      homeserver: Uri.parse('https://offline.test'));
  final lease = await matrix.openRoomLease(client.localRoom.id);
  final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((_) async => http.Response('{}', 503)));
  final roomPage = RoomPage(
      api: api,
      roomLease: lease,
      roomName: 'Offline fixture',
      initialIdentityCache: ProfileRepository.forTesting(
          accountKey: 'offline-fixture', store: MemoryProfileStore())
        ..contacts = [
          if (friend)
            const ContactSummary(
                userId: 'peer',
                username: 'peer',
                matrixUserId: '@peer:offline.test',
                nickname: 'Peer')
        ],
      onCreateGroup: () {});
  await tester
      .pumpWidget(CupertinoApp(scrollBehavior: scrollBehavior, home: roomPage));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return lease;
}

class _ClampingScrollBehavior extends CupertinoScrollBehavior {
  const _ClampingScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics();
}

void _newEvent(_OfflineRoom room) {
  room.localTimeline.events.insert(
      0,
      Event(
          room: room,
          eventId: 'new-event',
          senderId: '@peer:offline.test',
          type: EventTypes.Message,
          originServerTs: DateTime.utc(2026, 9, 11),
          content: {'msgtype': 'm.text', 'body': 'new message'}));
  room.update!();
}

void main() {
  testWidgets(
      'own local send from older window scrolls before transport completes',
      (tester) async {
    final client = _OfflineClient();
    final room = client.localRoom;
    room.localTimeline.events
      ..clear()
      ..addAll(List.generate(
          500,
          (i) => Event(
                  room: room,
                  eventId: 'event-${499 - i}',
                  senderId: '@peer:offline.test',
                  type: EventTypes.Message,
                  originServerTs:
                      DateTime.utc(2026).add(Duration(seconds: 499 - i)),
                  content: {
                    'msgtype': 'm.text',
                    'body': 'history row ${499 - i}'
                  })));
    await _mount(tester, client, friend: true);
    final list = tester.widget<ListView>(find.byType(ListView).first);
    list.controller!.jumpTo(list.controller!.position.maxScrollExtent - 50);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final state = tester.state(find.byType(RoomPage)) as dynamic;
    final timeline = state.controller as RoomTimelineController;
    await timeline.showEarlierWindow();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    list.controller!.jumpTo(list.controller!.position.maxScrollExtent / 2);
    await tester.pump();
    expect(list.controller!.offset, greaterThan(500));
    expect(timeline.hasLaterWindow, isTrue);
    final transport = Completer<String>();
    final sending =
        timeline.sendText('own pending bubble', send: (_) => transport.future);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(transport.isCompleted, isFalse);
    expect(find.text('own pending bubble').hitTestable(), findsOneWidget);
    transport.completeError(const SocketException('fixture offline send'));
    await sending;
    await tester.pump();
    expect(find.text('own pending bubble').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'held forward fragment page shifts only after the newer-edge drag ends',
      (tester) async {
    final client = _OfflineClient();
    final room = client.localRoom;
    final day = DateTime(2026, 9, 5);
    final context = _OfflineTimeline(room)
      ..events.clear()
      ..events.addAll(List.generate(
          240,
          (index) => Event(
              room: room,
              eventId: 'context-$index',
              senderId: '@peer:offline.test',
              type: EventTypes.Message,
              originServerTs: day.add(Duration(minutes: index)),
              content: {'msgtype': 'm.text', 'body': 'context $index'})))
      ..futureAvailable = true
      ..pendingFuture = Completer<void>();
    room.contextTimeline = context;
    client.timestampResult = GetEventByTimestampResponse(
      eventId: r'$context-anchor',
      originServerTs: day.millisecondsSinceEpoch,
    );
    await _mount(tester, client);
    final state = tester.state(find.byType(RoomPage)) as dynamic;
    final timeline = state.controller as RoomTimelineController;
    expect((await timeline.locateDay(day))?.eventId, 'context-0');
    while (timeline.hasLaterWindow) {
      await timeline.showLaterWindow();
    }
    await tester.pump();
    expect(timeline.hasLaterWindow, isFalse);
    final listFinder = find.byType(ListView).first;
    final scroll = tester.widget<ListView>(listFinder).controller!;
    final oldFirst = timeline.messages.first.id;
    expect(timeline.hasFutureHistory, isTrue);
    expect(scroll.position.extentBefore, lessThan(120));

    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    await gesture.moveBy(const Offset(0, -500));
    await gesture.moveBy(const Offset(0, -500));
    await tester.pump();
    expect(context.futureRequests, 1);
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    context.events.insertAll(
        0,
        List.generate(
            200,
            (index) => Event(
                room: room,
                eventId: 'future-$index',
                senderId: '@peer:offline.test',
                type: EventTypes.Message,
                originServerTs: day.add(Duration(days: 1, minutes: index)),
                content: {'msgtype': 'm.text', 'body': 'future $index'})));
    context.futureAvailable = false;
    context.pendingFuture!.complete();
    room.update!();
    await tester.pump();
    expect(timeline.hasLaterWindow, isTrue);
    expect(timeline.messages.first.id, oldFirst,
        reason: 'a held drag must not shift its window');
    await gesture.up();
    for (var i = 0; i < 300 && scroll.position.isScrollingNotifier.value; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 32));
    expect(timeline.messages.first.id, isNot(oldFirst));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('append reuses unchanged visible rows without rebuilding page',
      (tester) async {
    final client = _OfflineClient();
    await _mount(tester, client);
    final prior = tester.widget(find.text('cached offline message'));
    _newEvent(client.localRoom);
    await tester.pump();
    await tester.pump();
    expect(tester.widget(find.text('cached offline message')), same(prior));
    expect(find.text('new message'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('room mounts bounded projection and moves to older local history',
      (tester) async {
    final client = _OfflineClient();
    final room = client.localRoom;
    room.localTimeline.events.clear();
    room.localTimeline.events.addAll(List.generate(
        1000,
        (i) =>
            Event(
                room: room,
                eventId: 'event-${999 - i}',
                senderId: '@peer:offline.test',
                type: EventTypes.Message,
                originServerTs:
                    DateTime.utc(2026).add(Duration(seconds: 999 - i)),
                content: {
                  'msgtype': 'm.text',
                  'body': 'synthetic row ${999 - i}'
                })));
    await _mount(tester, client);
    final list = tester.widget<ListView>(find.byType(ListView).first);
    final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.childCount, 40);
    list.controller!.jumpTo(list.controller!.position.maxScrollExtent - 50);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final updated = tester.widget<ListView>(find.byType(ListView).first);
    expect((updated.childrenDelegate as SliverChildBuilderDelegate).childCount,
        200);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('active reverse drag is not interrupted by an older window shift',
      (tester) async {
    final client = _OfflineClient();
    final room = client.localRoom;
    room.localTimeline.events
      ..clear()
      ..addAll(List.generate(
          1000,
          (i) => Event(
              room: room,
              eventId: 'drag-event-${999 - i}',
              senderId: '@peer:offline.test',
              type: EventTypes.Message,
              originServerTs:
                  DateTime.utc(2026).add(Duration(seconds: 999 - i)),
              content: {'msgtype': 'm.text', 'body': 'row'})));
    await _mount(tester, client);
    final listFinder = find.byType(ListView).first;
    final list = tester.widget<ListView>(listFinder);
    final scroll = list.controller!;
    final timeline = (tester.state(find.byType(RoomPage)) as dynamic).controller
        as RoomTimelineController;
    final initialOldest = timeline.messages.first.id;
    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(0, 500));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.position.pixels, greaterThan(0));
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    await tester.pump(const Duration(milliseconds: 32));
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    await gesture.up();
    for (var i = 0; i < 300 && scroll.position.isScrollingNotifier.value; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.position.isScrollingNotifier.value, isFalse);
    expect(timeline.messages.first.id, isNot(initialOldest));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
      'clamped older-edge overscroll defers an earlier window shift until drag ends',
      (tester) async {
    final client = _OfflineClient();
    final room = client.localRoom;
    room.localTimeline.events
      ..clear()
      ..addAll(List.generate(
          1000,
          (i) => Event(
              room: room,
              eventId: 'clamped-event-${999 - i}',
              senderId: '@peer:offline.test',
              type: EventTypes.Message,
              originServerTs:
                  DateTime.utc(2026).add(Duration(seconds: 999 - i)),
              content: {'msgtype': 'm.text', 'body': 'row'})));
    await _mount(tester, client,
        scrollBehavior: const _ClampingScrollBehavior());
    final listFinder = find.byType(ListView).first;
    final scroll = tester.widget<ListView>(listFinder).controller!;
    final timeline = (tester.state(find.byType(RoomPage)) as dynamic).controller
        as RoomTimelineController;
    final initialOldest = timeline.messages.first.id;
    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    for (var i = 0; i < 16; i++) {
      await gesture.moveBy(const Offset(0, 500));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.position.pixels, scroll.position.maxScrollExtent);
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    final clampedPixels = scroll.position.pixels;
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump(const Duration(milliseconds: 16));
    expect(scroll.position.pixels, clampedPixels);
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    expect(timeline.messages.first.id, initialOldest);

    await gesture.up();
    for (var i = 0; i < 300 && scroll.position.isScrollingNotifier.value; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.position.isScrollingNotifier.value, isFalse);
    expect(timeline.messages.first.id, isNot(initialOldest));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'reverse drag keeps the newer loaded window when held older history completes',
      (tester) async {
    final client = _OfflineClient();
    final room = client.localRoom;
    final heldHistory = Completer<void>();
    room.localTimeline.events
      ..clear()
      ..addAll(List.generate(
          400,
          (i) => Event(
              room: room,
              eventId: 'held-event-${399 - i}',
              senderId: '@peer:offline.test',
              type: EventTypes.Message,
              originServerTs:
                  DateTime.utc(2026).add(Duration(seconds: 399 - i)),
              content: {'msgtype': 'm.text', 'body': 'row'})));
    room.localTimeline.historyLoader = () => heldHistory.future;
    await _mount(tester, client);
    final timeline = (tester.state(find.byType(RoomPage)) as dynamic).controller
        as RoomTimelineController;
    expect(await timeline.openAnchor('held-event-0'), isTrue);
    await tester.pump();

    final listFinder = find.byType(ListView).first;
    final scroll = tester.widget<ListView>(listFinder).controller!;
    final oldestLoadedAnchor = timeline.messages.first.id;
    scroll.jumpTo(scroll.position.maxScrollExtent - 50);
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    for (var i = 0; i < 4 && room.localTimeline.historyRequests == 0; i++) {
      await gesture.moveBy(const Offset(0, 500));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(room.localTimeline.historyRequests, 1);
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump(const Duration(milliseconds: 16));
    expect(scroll.position.extentAfter,
        lessThan(scroll.position.viewportDimension * 2));
    expect(scroll.position.extentBefore,
        greaterThan(scroll.position.viewportDimension * 2));
    await gesture.up();

    room.localTimeline.events.add(Event(
        room: room,
        eventId: 'held-older-event',
        senderId: '@peer:offline.test',
        type: EventTypes.Message,
        originServerTs: DateTime.utc(2025, 12, 31),
        content: {'msgtype': 'm.text', 'body': 'older row'}));
    room.update!();
    heldHistory.complete();
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(timeline.messages.first.id, oldestLoadedAnchor);
    expect(timeline.messages.length, lessThanOrEqualTo(200));
    expect(room.localTimeline.historyRequests, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('release at the newer edge applies the deferred later window',
      (tester) async {
    final client = _OfflineClient();
    final room = client.localRoom;
    room.localTimeline.events
      ..clear()
      ..addAll(List.generate(
          1000,
          (i) => Event(
              room: room,
              eventId: 'later-event-${999 - i}',
              senderId: '@peer:offline.test',
              type: EventTypes.Message,
              originServerTs:
                  DateTime.utc(2026).add(Duration(seconds: 999 - i)),
              content: {'msgtype': 'm.text', 'body': 'row'})));
    await _mount(tester, client);
    final timeline = (tester.state(find.byType(RoomPage)) as dynamic).controller
        as RoomTimelineController;
    await timeline.openAnchor('later-event-300');
    await tester.pump();
    expect(timeline.hasLaterWindow, isTrue);
    final initialOldest = timeline.messages.first.id;
    final listFinder = find.byType(ListView).first;
    final scroll = tester.widget<ListView>(listFinder).controller!;
    expect(scroll.position.extentBefore, lessThan(120));
    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    await gesture.up();
    for (var i = 0; i < 300 && scroll.position.isScrollingNotifier.value; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.position.isScrollingNotifier.value, isFalse);
    expect(timeline.messages.first.id, isNot(initialOldest));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('ordinary typing leaves existing message widgets unchanged',
      (tester) async {
    await _mount(tester, _OfflineClient());
    final field = tester
        .widget<CupertinoTextField>(find.byKey(const Key('composer-input')));
    final cachedText = tester.widget(find.text('cached offline message'));
    for (final value in ['n', 'ni', '你好', '你好🙂']) {
      field.controller!.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length));
      await tester.pump();
      expect(
          tester.widget(find.text('cached offline message')), same(cachedText));
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('canceled account lease stops pending receipt retry',
      (tester) async {
    final client = _OfflineClient();
    final timeline = client.localRoom.localTimeline;
    final lease = await _mount(tester, client);
    final canceled = lease.cancel();
    // Lease cancellation uses the existing owner-disposal drain contract.
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump();
    await canceled;
    await tester.pump(const Duration(seconds: 40));
    expect(timeline.readAttempts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'one follow-up receipt covers changes during an in-flight receipt',
      (tester) async {
    final client = _OfflineClient();
    final timeline = client.localRoom.localTimeline..offline = false;
    timeline.pendingReceipt = Completer<void>();
    await _mount(tester, client);
    _newEvent(client.localRoom);
    client.localRoom.update!();
    client.localRoom.update!();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(timeline.readAttempts, 1);
    timeline.pendingReceipt!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(timeline.readAttempts, 2);
    await tester.pump(const Duration(seconds: 40));
    expect(timeline.readAttempts, 2);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump();
  });

  testWidgets('new message receipt retries after network recovery',
      (tester) async {
    final client = _OfflineClient();
    final timeline = client.localRoom.localTimeline..offline = false;
    await _mount(tester, client);
    expect(timeline.readAttempts, 1);
    timeline.offline = true;
    _newEvent(client.localRoom);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(timeline.readAttempts, 2);
    expect(find.text('cached offline message'), findsOneWidget);
    timeline.offline = false;
    await tester.pump(const Duration(seconds: 5));
    expect(timeline.readAttempts, 3);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump(const Duration(seconds: 40));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'pending receipt coalesces newer messages and absorbs dispose failure',
      (tester) async {
    final client = _OfflineClient();
    final timeline = client.localRoom.localTimeline;
    timeline.pendingReceipt = Completer<void>();
    await _mount(tester, client);
    _newEvent(client.localRoom);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(timeline.readAttempts, 1);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    timeline.pendingReceipt!.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 40));
    expect(timeline.readAttempts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('receipt retry pauses in background and resumes', (tester) async {
    final client = _OfflineClient();
    final timeline = client.localRoom.localTimeline;
    await _mount(tester, client);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 40));
    expect(timeline.readAttempts, 1);
    timeline.offline = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1));
    expect(timeline.readAttempts, 2);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump(const Duration(seconds: 40));
  });

  testWidgets('critical local timeline failure retains retry error',
      (tester) async {
    final client = _OfflineClient();
    client.localRoom.failTimeline = true;
    await _mount(tester, client);
    expect(find.text('会话加载失败，请检查网络后重试'), findsOneWidget);
    expect(client.localRoom.localTimeline.readAttempts, 0);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump();
  });

  for (final pending in [false, true]) {
    testWidgets(
        'receipt ${pending ? 'pending' : 'offline'} recovers without blocking cached content',
        (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      SharedPreferences.setMockInitialValues({});
      final client = _OfflineClient();
      final timeline = client.localRoom.localTimeline;
      if (pending) timeline.pendingReceipt = Completer<void>();
      final matrix = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://offline.test'));
      final lease = await matrix.openRoomLease(client.localRoom.id);
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://business.test'),
          sessionStore: SecureSessionStore(),
          client: MockClient((_) async => http.Response('{}', 503)));
      await tester.pumpWidget(CupertinoApp(
          home: RoomPage(
              api: api,
              roomLease: lease,
              roomName: 'Offline fixture',
              initialIdentityCache: ProfileRepository.forTesting(
                  accountKey: 'offline-fixture', store: MemoryProfileStore()),
              onCreateGroup: () {})));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('cached offline message'), findsOneWidget);
      expect(find.text('我的表情同步失败，可稍后重试'), findsOneWidget);
      expect(timeline.readAttempts, 1);
      timeline.offline = false;
      timeline.pendingReceipt?.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(timeline.readAttempts, pending ? 1 : 2);
      await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
      await tester.pump(const Duration(seconds: 40));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cached messages survive offline read receipt failure',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    final client = _OfflineClient();
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://offline.test'));
    final lease = await matrix.openRoomLease(client.localRoom.id);
    final cache = ProfileRepository.forTesting(
        accountKey: 'offline-fixture', store: MemoryProfileStore());
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((_) async => http.Response('{}', 503)),
    );
    await tester.pumpWidget(CupertinoApp(
        home: RoomPage(
      api: api,
      roomLease: lease,
      roomName: 'Offline fixture',
      initialIdentityCache: cache,
      onCreateGroup: () {},
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    try {
      expect(client.localRoom.localTimeline.readAttempts, greaterThan(0));
      expect(find.text('会话加载失败，请检查网络后重试'), findsNothing);
      expect(find.text('cached offline message'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
      await tester.pump();
    }
  });
}
