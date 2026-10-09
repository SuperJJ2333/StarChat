import 'dart:io';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';
import 'dart:async';
import 'package:liuhetong_mobile/core/outbox/persistent_outbox_manager.dart';
import 'package:liuhetong_mobile/features/matrix/room_navigation_coordinator.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'profile_repository_test.dart' show MemoryProfileStore;

class _OfflineClient extends Client {
  _OfflineClient({http.Client? httpClient})
      : super('offline-room-fixture', httpClient: httpClient);
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
  Timeline? realTimeline;
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
    return realTimeline ?? localTimeline;
  }
}

void _bindOfflineAccount(_OfflineClient client, MatrixRoomLease lease) {
  // Production binds the active account before opening a room. This fixture
  // mounts RoomPage directly, so supply the same real lease account boundary.
  expect(lease.roomInfo.currentUserId, client.userID);
  ConversationReadState.shared()
    ..resetForTest()
    ..bindAccount(client.userID);
}

Future<MatrixRoomLease> _mount(WidgetTester tester, _OfflineClient client,
    {bool friend = false,
    Future<MatrixClientContinuityMetadata> Function(Client)?
        readContinuityMetadata,
    ScrollBehavior? scrollBehavior,
    ValueNotifier<RoomOpenRequest>? navigationRequests,
    Future<String> Function(String)? resolveDirectSendTarget,
    void Function(String)? onDirectTargetChanged,
    PersistentOutboxManager? outbox}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  SharedPreferences.setMockInitialValues({});
  final matrix = MatrixSdkE2eeClient(client,
      homeserver: Uri.parse('https://offline.test'),
      readContinuityMetadata: readContinuityMetadata);
  final lease = await matrix.openRoomLease(client.localRoom.id);
  _bindOfflineAccount(client, lease);
  final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((_) async => http.Response('{}', 503)));
  final roomPage = RoomPage(
      api: api,
      roomLease: lease,
      roomName: 'Offline fixture',
      navigationRequests: navigationRequests,
      resolveDirectSendTarget: resolveDirectSendTarget,
      onDirectTargetChanged: onDirectTargetChanged,
      outbox: outbox,
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

void main() {
  setUp(() => ConversationReadState.shared().resetForTest());
  tearDown(() => ConversationReadState.shared().resetForTest());
  testWidgets('return latest waits for a screen and resets after returning',
      (tester) async {
    final client = _OfflineClient();
    final room = client.localRoom;
    room.localTimeline.events
      ..clear()
      ..addAll(List.generate(
          300,
          (i) => Event(
              room: room,
              eventId: 'threshold-$i',
              senderId: '@peer:offline.test',
              type: EventTypes.Message,
              originServerTs: DateTime.utc(2026).subtract(Duration(minutes: i)),
              content: {'msgtype': 'm.text', 'body': 'synthetic row $i'})));
    await _mount(tester, client);
    final scroll = tester
        .widget<AnchoredTimelineList>(find.byType(AnchoredTimelineList))
        .controller;
    final button = find.byKey(const Key('timeline-return-latest'));
    expect(button, findsNothing);
    final latest = scroll.position.minScrollExtent;
    scroll.jumpTo(latest + 100);
    await tester.pump();
    expect(button, findsNothing);
    scroll.jumpTo(latest + 1200);
    await tester.pump();
    expect(button, findsOneWidget,
        reason: 'crossing the threshold must work without an incoming event');
    scroll.jumpTo(latest + 100);
    await tester.pump();
    expect(button, findsNothing);
    // A newly received event behind a pinned window sets hasLaterWindow even
    // though the reader moved only a small distance away from the latest row.
    room.localTimeline.events.insert(
        0,
        Event(
            room: room,
            eventId: 'threshold-incoming',
            senderId: '@peer:offline.test',
            type: EventTypes.Message,
            originServerTs: DateTime.utc(2026).add(const Duration(minutes: 1)),
            content: {'msgtype': 'm.text', 'body': 'synthetic incoming'}));
    room.update?.call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(button, findsNothing,
        reason: 'pinning a bounded window must not expose the button');
    scroll.jumpTo(latest + 1200);
    await tester.pump();
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(button, findsNothing);
    expect(scroll.position.extentBefore, closeTo(0, 1));
    scroll.jumpTo(scroll.position.minScrollExtent + 100);
    await tester.pump();
    expect(button, findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'RoomPage overlapping fast flings admit history before motion stops',
      (tester) async {
    final client = _OfflineClient();
    final room = client.localRoom;
    room.localTimeline.events
      ..clear()
      ..addAll(List.generate(1000, (i) {
        final id = 999 - i;
        return Event(
            room: room,
            eventId: 'fast-$id',
            senderId: '@peer:offline.test',
            type: EventTypes.Message,
            originServerTs: DateTime.utc(2026).add(Duration(hours: id)),
            content: {
              'msgtype': 'm.text',
              'body':
                  List.filled(id % 100 == 0 ? 30 : 1 + id % 4, 'synthetic row')
                      .join('\n')
            });
      }));
    await _mount(tester, client,
        scrollBehavior: const _ClampingScrollBehavior());
    final listFinder = find.byType(AnchoredTimelineList).first;
    final scroll = tester.widget<AnchoredTimelineList>(listFinder).controller;
    final timeline = (tester.state(find.byType(RoomPage)) as dynamic).controller
        as RoomTimelineController;
    var shifts = 0;
    void observeShift() {
      // Native frame callbacks can run outside the current tester.pump guard.
      // Read the same mounted elements/render boxes without guarded test APIs.
      final old = listFinder.evaluate().single.widget as AnchoredTimelineList;
      if (old.eventIds.firstOrNull == timeline.messages.lastOrNull?.stableId) {
        return;
      }
      final viewport = find
          .ancestor(
              of: listFinder,
              matching: find.byWidgetPredicate(
                  (w) => w is GestureDetector && w.key is GlobalKey))
          .first;
      final viewportKey = viewport.evaluate().single.widget.key! as GlobalKey;
      final retained = TimelineScrollAnchor.visibleBoundaryEventId(
          old.messageKeys, viewportKey, old.eventIds,
          earlier: true);
      expectSync(retained, isNotNull);
      double top() =>
          (old.messageKeys[retained]!.currentContext!.findRenderObject()!
                  as RenderBox)
              .localToGlobal(Offset.zero)
              .dy;
      final before = top();
      expectSync(timeline.messages.any((m) => m.stableId == retained), isTrue,
          reason: 'the actual RoomPage must protect its visible outer row');
      shifts++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final after = top();
        if ((after - before).abs() > 1) {
          // Synthetic geometry only, never account/event IDs or message text.
          // ignore: avoid_print
          print('CONTINUOUS_ANCHOR_DELTA ${after - before} shift=$shifts');
        }
        expectSync(after, closeTo(before, 1),
            reason: 'page admission must not jump days');
      });
    }

    timeline.addListener(observeShift);
    // Reach just outside prefetch range without asking for a window shift.
    scroll.jumpTo(scroll.position.maxScrollExtent -
        scroll.position.viewportDimension * 3);
    await tester.pump();
    var activeShifts = 0;
    void observeActiveShift() {
      if (scroll.position.isScrollingNotifier.value) activeShifts++;
    }

    timeline.addListener(observeActiveShift);
    for (var burst = 0; burst < 30; burst++) {
      // Interrupt each simulation with another fling, never wait for settling.
      await tester.fling(listFinder, const Offset(0, 350), 10000);
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (!scroll.position.isScrollingNotifier.value) {
          // ignore: avoid_print
          print('CONTINUOUS_MOTION_STOP burst=$burst frame=$frame '
              'earlier=${timeline.hasEarlierWindow} shifts=$shifts');
        }
        expect(scroll.position.isScrollingNotifier.value, isTrue,
            reason: 'history must not expose an artificial hard edge');
        expect(timeline.messages.length, lessThanOrEqualTo(200));
        expect(scroll.positions.length, 1);
        final frameError = tester.takeException();
        if (frameError != null) {
          // ignore: avoid_print
          print('CONTINUOUS_FRAME_ERROR $frameError');
        }
        expect(frameError, isNull);
      }
    }
    expect(activeShifts, greaterThanOrEqualTo(2),
        reason: 'continuous ballistic movement must admit overlapping windows');
    expect(shifts, greaterThanOrEqualTo(2));
    timeline.removeListener(observeActiveShift);
    timeline.removeListener(observeShift);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
