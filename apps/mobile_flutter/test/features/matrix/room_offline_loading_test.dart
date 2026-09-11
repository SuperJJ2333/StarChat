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
  @override
  Room? getRoomById(String roomId) => roomId == localRoom.id ? localRoom : null;
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
  int readAttempts = 0;
  bool offline = true;
  Completer<void>? pendingReceipt;
  @override
  bool get canRequestHistory => false;
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
    return localTimeline;
  }
}

Future<MatrixRoomLease> _mount(WidgetTester tester, _OfflineClient client,
    {bool friend = false}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  SharedPreferences.setMockInitialValues({});
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
              accountKey: 'offline-fixture', store: MemoryProfileStore())
            ..contacts = [
              if (friend)
                const ContactSummary(
                    userId: 'peer',
                    username: 'peer',
                    matrixUserId: '@peer:offline.test',
                    nickname: 'Peer')
            ],
          onCreateGroup: () {})));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return lease;
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
