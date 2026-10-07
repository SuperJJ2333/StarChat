import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart' show RenderPadding;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';
import 'package:liuhetong_mobile/features/search/local_message_search_repository.dart';

import 'profile_repository_test.dart' show MemoryProfileStore;

// Transparent observation of the real SDK source. It does not implement any
// windowing, projection, paging or mutation policy of its own.
class _CountedEvents extends ListBase<Event> {
  _CountedEvents(this.raw);
  final List<Event> raw;
  int reads = 0;
  @override
  int get length => raw.length;
  @override
  set length(int value) => raw.length = value;
  @override
  Event operator [](int index) {
    reads++;
    return raw[index];
  }

  @override
  void operator []=(int index, Event value) => raw[index] = value;
  @override
  void add(Event value) => raw.add(value);
  @override
  void addAll(Iterable<Event> values) => raw.addAll(values);
  @override
  void insert(int index, Event value) => raw.insert(index, value);
  @override
  void insertAll(int index, Iterable<Event> values) =>
      raw.insertAll(index, values);
  @override
  Event removeAt(int index) => raw.removeAt(index);
}

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();
  Future<void> wait() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }

  void complete() {
    if (!release.isCompleted) release.complete();
  }
}

class _ObservedStore extends MatrixSdkDatabase {
  _ObservedStore(super.path,
      {required super.database, required super.sqfliteFactory});
  int pageRows = 0;
  int individualReads = 0;
  _Gate? nextPage;
  _Gate? pendingSync;
  @override
  Future<void> storeEventUpdate(EventUpdate update, Client client) async {
    await super.storeEventUpdate(update, client);
    if (update.content['event_id'] == 'A-sync-pending') {
      final gate = pendingSync;
      pendingSync = null;
      if (gate != null) await gate.wait();
    }
  }

  @override
  Future<List<Event>> getEventList(Room room,
      {int start = 0, bool onlySending = false, int? limit}) async {
    final rows = await super.getEventList(room,
        start: start, onlySending: onlySending, limit: limit);
    pageRows += rows.length;
    return rows;
  }

  @override
  Future<Event?> getEventById(String eventId, Room room) async {
    individualReads++;
    final row = await super.getEventById(eventId, room);
    // Resident keyset pagination reads payloads by ID, rather than using the
    // old offset-list path. Hold the real payload read without altering it.
    final gate = nextPage;
    nextPage = null;
    if (gate != null) await gate.wait();
    return row;
  }

  void resetCounts() {
    pageRows = 0;
    individualReads = 0;
  }
}

class _InteractionClient extends Client {
  _InteractionClient(this.store, this.receipts, this.requests, this.readMarkers)
      : super('history-interaction-synthetic',
            httpClient: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          if (request.url.path.contains('/read_markers') ||
              request.url.path.contains('/receipt/')) {
            receipts.add(request.url.path);
            if (request.url.path.contains('/read_markers')) {
              final content = jsonDecode(request.body) as Map<String, dynamic>;
              final eventId = content['m.read'] ?? content['m.read.private'];
              if (eventId is String) readMarkers.add(eventId);
            }
            return http.Response('{}', 200);
          }
          return http.Response('{}', 503);
        }));
  final _ObservedStore store;
  final List<String> receipts;
  final List<String> requests;
  final List<String> readMarkers;
  @override
  DatabaseApi get database => store;
  @override
  String get userID => '@self:interaction.test';
}

class _InteractionRoom extends Room {
  _InteractionRoom(Client client, String name)
      : super(id: '!$name:interaction.test', client: client);
  final observed = <_CountedEvents>[];
  final timelines = <Timeline>[];
  String timelinePhase = 'not started';
  _Gate? nextMetadata;
  @override
  bool get isDirectChat => true;
  @override
  String get directChatMatrixID => '@peer:interaction.test';
  @override
  Future<List<User>> requestParticipants([
    List<Membership> membershipFilter = const [
      Membership.join,
      Membership.invite,
      Membership.knock
    ],
    bool suppressWarning = false,
    bool cache = true,
  ]) async {
    final gate = nextMetadata;
    nextMetadata = null;
    if (gate != null) await gate.wait();
    return super.requestParticipants(membershipFilter, suppressWarning, cache);
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
    timelinePhase = 'await SDK getTimeline';
    final timeline = await super.getTimeline(
        onChange: onChange,
        onRemove: onRemove,
        onInsert: onInsert,
        onNewEvent: onNewEvent,
        onUpdate: onUpdate,
        eventContextId: eventContextId);
    // These rows were persisted through the public database API, so eviction
    // remains reloadable. N is independently asserted at the database boundary.
    if (eventContextId == null) {
      while (timeline.events.length < 1000 && timeline.canRequestHistory) {
        final before = timeline.events.length;
        timelinePhase = 'await refill from $before';
        await timeline.requestHistory(
            historyCount: (1000 - before).clamp(1, 256));
        if (timeline.events.length == before) break;
      }
    }
    timelinePhase = 'observing source';
    final counted = _CountedEvents(timeline.chunk.events);
    timeline.chunk.events = counted;
    observed.add(counted);
    timelines.add(timeline);
    return timeline;
  }

  int get sourceReads => observed.fold(0, (n, list) => n + list.reads);
  void resetReads() {
    for (final list in observed) {
      list.reads = 0;
    }
  }
}

Map<String, dynamic> _row(String room, int sequence,
        {String? id, String? body}) =>
    {
      'event_id': id ?? '$room-$sequence',
      'type': EventTypes.Message,
      'sender': '@peer:interaction.test',
      'origin_server_ts':
          DateTime.utc(2026, 1, 1).millisecondsSinceEpoch + sequence * 1000,
      'content': {
        'msgtype': MessageTypes.Text,
        'body': body ?? 'synthetic $room row $sequence'
      },
    };

// Native DB work and page-owned zero-delay timers can depend on each other.
// Advance both clocks while observing the real Future; never replace its result.
Future<T> _withBothClocks<T>(WidgetTester tester, Future<T> Function() action,
    {required String phase}) async {
  var done = false;
  T? result;
  Object? error;
  StackTrace? stack;
  await tester.runAsync(() async {
    unawaited(Future<T>.sync(action).then<void>((value) {
      result = value;
      done = true;
    }, onError: (Object caught, StackTrace trace) {
      error = caught;
      stack = trace;
      done = true;
    }));
  });
  for (var i = 0; i < 1600 && !done; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(done, isTrue, reason: 'real native operation must complete: $phase');
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return result as T;
}

class _Fixture {
  _Fixture(this.store, this.client, this.owner, this.a, this.b, this.receipts);
  final _ObservedStore store;
  final _InteractionClient client;
  final MatrixSdkE2eeClient owner;
  final _InteractionRoom a, b;
  final List<String> receipts;
  final leases = <MatrixRoomLease>[];
  final syncStatus = StreamController<SyncStatusUpdate>.broadcast();
  late final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.fixture.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((_) async => http.Response('{}', 503)));

  static Future<_Fixture> create(int persistedCount,
      {String? visibilityTargetId}) async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final store = _ObservedStore('history-interaction',
        database: sql, sqfliteFactory: databaseFactoryFfi);
    await store.open();
    final receipts = <String>[];
    final client = _InteractionClient(store, receipts, <String>[], <String>[])
      ..homeserver = Uri.parse('https://matrix.fixture.test')
      ..accessToken = 'synthetic-token';
    final a = _InteractionRoom(client, 'A');
    final b = _InteractionRoom(client, 'B');
    client.rooms.addAll([a, b]);
    for (final room in [a, b]) {
      room.setState(User(client.userID, membership: 'join', room: room));
      room.setState(
          User('@peer:interaction.test', membership: 'join', room: room));
      await store.prepareTimelineStorage([room.id]);
      final count = identical(room, a) ? persistedCount : 1000;
      for (var start = 0; start < count; start += 256) {
        final end = (start + 256).clamp(0, count);
        await store.transaction(() async {
          for (var index = start; index < end; index++) {
            final row = _row(identical(room, a) ? 'A' : 'B', index,
                body: identical(room, a) && index == count - 1001
                    ? 'retired-page-marker'
                    : null);
            if (row['event_id'] == visibilityTargetId) {
              // Visibility-only fixture: keep canonical position, but make the
              // target eligible after any neighboring row's monotonic receipt.
              row['origin_server_ts'] =
                  DateTime.utc(2026, 2, 1).millisecondsSinceEpoch;
            }
            await store.storeEventUpdate(
                EventUpdate(
                    roomID: room.id,
                    type: EventUpdateType.timeline,
                    content: row),
                client);
          }
        });
      }
    }
    final owner = MatrixSdkE2eeClient(client,
        homeserver: client.homeserver!,
        readContinuityMetadata: (active) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: active.isLogged(),
                userId: active.userID,
                deviceId: active.deviceID,
                ed25519Fingerprint: 'synthetic-fingerprint',
                databaseGeneration: 'synthetic-generation'));
    return _Fixture(store, client, owner, a, b, receipts);
  }

  Future<MatrixRoomLease> mount(
      WidgetTester tester, _InteractionRoom room) async {
    final lease = await _withBothClocks(
        tester, () => owner.openRoomLease(room.id),
        phase: 'open room lease');
    leases.add(lease);
    await tester.pumpWidget(CupertinoApp(
        home: RoomPage(
      key: ValueKey(lease),
      api: api,
      roomLease: lease,
      roomName: identical(room, a) ? 'Room A' : 'Room B',
      remoteSyncStatus: syncStatus.stream,
      initialIdentityCache: ProfileRepository.forTesting(
          accountKey: client.userID, store: MemoryProfileStore()),
      onCreateGroup: () {},
    )));
    // This fixture deliberately fills a 1000-row real SDK window before the
    // page receives it. Each FFI completion may need another widget-clock
    // turn; setup work is bounded by that fixed resident window, not N.
    const setupFrameBudget = 1000 + 2 * 256;
    for (var i = 0;
        i < setupFrameBudget &&
            find.byType(AnchoredTimelineList).evaluate().isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)));
      await tester.pump(const Duration(milliseconds: 1));
    }
    if (find.byType(AnchoredTimelineList).evaluate().length != 1) {
      final dynamic state = tester.state(find.byType(RoomPage));
      debugPrint('mount incomplete: phase=${room.timelinePhase} '
          'controllerReady=${state.controller != null} messages=${state.controller?.messages.length} '
          'timelines=${room.timelines.length} '
          'payloadReads=${store.individualReads} '
          'pageRows=${store.pageRows}');
    }
    expect(find.byType(AnchoredTimelineList), findsOneWidget);
    return lease;
  }

  Future<void> dispose(WidgetTester tester) async {
    store.nextPage?.complete();
    store.pendingSync?.complete();
    a.nextMetadata?.complete();
    b.nextMetadata?.complete();
    await tester.pumpWidget(const SizedBox());
    // FFI completions use the real event loop; page-owned zero-delay timers
    // use the widget test clock. Advance both before awaiting lease teardown.
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Keep advancing both clocks until the page-owned asynchronous work has
    // actually drained. Waiting inside runAsync alone leaves widget-zone
    // continuations' zero-delay timers paused after native FFI completes.
    var drained = false;
    Object? drainError;
    StackTrace? drainStack;
    await tester.runAsync(() async {
      unawaited(Future.wait(leases.map((lease) => lease.cancel())).then<void>(
        (_) => drained = true,
        onError: (Object error, StackTrace stack) {
          drainError = error;
          drainStack = stack;
          drained = true;
        },
      ));
    });
    for (var i = 0; i < 1600 && !drained; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(drained, isTrue, reason: 'real lease cancellation must complete');
    if (drainError != null) {
      Error.throwWithStackTrace(drainError!, drainStack!);
    }
    for (final room in [a, b]) {
      for (final timeline in room.timelines) {
        timeline.cancelSubscriptions();
      }
    }
    await syncStatus.close();
    await tester.runAsync(() => store.close());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull,
        reason: 'synthetic HTTP calls: ${client.requests}');
  }
}

RoomTimelineController _controller(WidgetTester tester) =>
    (tester.state(find.byType(RoomPage)) as dynamic).controller
        as RoomTimelineController;
AnchoredTimelineList _list(WidgetTester tester) =>
    tester.widget<AnchoredTimelineList>(find.byType(AnchoredTimelineList));

void main() {
  setUpAll(sqfliteFfiInit);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ConversationReadState.shared()
      ..resetForTest()
      ..bindAccount('@self:interaction.test');
    LocalMessageSearchRepository.shared.clear();
    LocalMessageSearchRepository.shared.attachAccount('@self:interaction.test');
  });
  tearDown(() {
    ConversationReadState.shared().resetForTest();
    LocalMessageSearchRepository.shared.clear();
  });

  testWidgets('RoomPage padding alone never sends a read marker for its body',
      (tester) async {
    const targetId = 'A-970';
    final fixture = (await tester
        .runAsync(() => _Fixture.create(1000, visibilityTargetId: targetId)))!;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    try {
      await fixture.mount(tester, fixture.a);
      Future<void> settlePageWork() async {
        await tester.pump(const Duration(milliseconds: 900));
        for (var i = 0; i < 64; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 1)));
          await tester.pump(const Duration(milliseconds: 1));
        }
      }

      // Optional service status can change the viewport height. Complete that
      // existing work while receipts are disabled before placing the edge.
      await settlePageWork();
      await _controller(tester).showEarlierWindow();
      await tester.pump();
      final listFinder = find.byType(AnchoredTimelineList);
      await tester.scrollUntilVisible(find.byKey(const ValueKey(targetId)), 200,
          scrollable: find.descendant(
              of: listFinder, matching: find.byType(Scrollable)));
      await tester.pump();
      final scroll = _list(tester).controller;
      final viewportFinder = find
          .ancestor(
              of: listFinder,
              matching: find.byWidgetPredicate(
                  (w) => w is GestureDetector && w.key is GlobalKey))
          .first;
      Rect viewportBounds() => tester.getRect(viewportFinder);
      RenderPadding targetRow() => _list(tester)
          .messageKeys[targetId]!
          .currentContext!
          .findRenderObject()! as RenderPadding;
      Rect rowBounds() {
        final row = targetRow();
        return row.localToGlobal(Offset.zero) & row.size;
      }

      Rect bodyBounds() {
        final body = targetRow().child!;
        return body.localToGlobal(Offset.zero) & body.size;
      }

      // Reverse scrolling moves the row down as its pixel offset increases.
      final targetOffset =
          scroll.offset + viewportBounds().top + 4 - rowBounds().bottom;
      expect(
          targetOffset,
          inInclusiveRange(scroll.position.minScrollExtent,
              scroll.position.maxScrollExtent));
      scroll.jumpTo(targetOffset);
      await tester.pump();
      expect(rowBounds().overlaps(viewportBounds()), isTrue);
      expect(bodyBounds().overlaps(viewportBounds()), isFalse,
          reason: 'only the existing bottom padding enters the viewport');
      expect(fixture.client.readMarkers, isEmpty,
          reason: 'inactive setup must not acknowledge visible history');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await settlePageWork();
      expect(fixture.client.readMarkers, isNotEmpty,
          reason: 'visible neighboring bodies must exercise the receipt path');
      expect(fixture.client.readMarkers, isNot(contains(targetId)),
          reason: 'padding is layout space, not a viewed message body');
      expect(rowBounds().overlaps(viewportBounds()), isTrue,
          reason: 'padding must still overlap after receipts');
      expect(bodyBounds().overlaps(viewportBounds()), isFalse);

      final positiveOffset =
          scroll.offset + viewportBounds().top + 8 - bodyBounds().bottom;
      scroll.jumpTo(positiveOffset);
      await tester.pump();
      expect(bodyBounds().overlaps(viewportBounds()), isTrue,
          reason: 'the positive control must expose the actual message body');
      await settlePageWork();
      expect(fixture.client.readMarkers, contains(targetId),
          reason: 'the same target becomes read when its body enters view');
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  for (final n in [1000, 10000, 100000]) {
    testWidgets(
        'RoomPage unchanged refresh reads no source history, persisted N=$n.',
        (tester) async {
      final fixture = (await tester.runAsync(() => _Fixture.create(n)))!;
      try {
        await fixture.mount(tester, fixture.a);
        await tester.pump(const Duration(milliseconds: 300));
        expect(
            await _withBothClocks(
                tester, () => fixture.store.getTimelineEventCount(fixture.a),
                phase: 'persisted count N=$n'),
            n);
        expect(
            fixture.a.timelines.single.events.length, lessThanOrEqualTo(1000));
        expect(_controller(tester).messages.length, lessThanOrEqualTo(200));
        fixture.a.resetReads();
        fixture.store.resetCounts();
        await _controller(tester).refresh();
        expect(fixture.a.sourceReads, 0,
            reason:
                'unchanged refresh must reuse its revision, independent of N and resident K');
        expect(fixture.store.pageRows + fixture.store.individualReads, 0);
        expect(
            (await _withBothClocks(
                    tester, () => fixture.store.getEventById('A-0', fixture.a),
                    phase: 'retained oldest body N=$n'))
                ?.eventId,
            'A-0',
            reason: 'bounded residency must retain the oldest persisted body');
      } catch (error, stack) {
        debugPrint('PRIMARY ROOMPAGE ERROR type=${error.runtimeType}\n$stack');
        rethrow;
      } finally {
        await fixture.dispose(tester);
      }
    });
  }

  testWidgets(
      'partial and full IME insets permit typing while real local page and sync are pending',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final fixture = (await tester.runAsync(() => _Fixture.create(10000)))!;
    final page = _Gate(), sync = _Gate();
    try {
      await fixture.mount(tester, fixture.a);
      await tester.pump(const Duration(milliseconds: 300));
      final controller = _controller(tester);
      fixture.store.nextPage = page;
      late Future<void> pending;
      await _withBothClocks(tester, () async {
        pending = controller.loadHistory();
        await page.entered.future;
      }, phase: 'held page entered');
      fixture.store.pendingSync = sync;
      late Future<void> syncPending;
      await _withBothClocks(tester, () async {
        syncPending = fixture.client.handleSync(SyncUpdate.fromJson({
          'next_batch': 'synthetic-pending-sync',
          'rooms': {
            'join': {
              fixture.a.id: {
                'timeline': {
                  'limited': false,
                  'events': [
                    _row('A', 10000, id: 'A-sync-pending'),
                  ]
                },
              }
            }
          },
        }));
        await sync.entered.future;
      }, phase: 'held sync entered');
      expect(controller.historyLoading, isTrue);
      final before = _list(tester).eventIds.toList();
      final modelsBefore = controller.messages;
      final input = (tester.state(find.byType(RoomPage)) as dynamic).input
          as TextEditingController;
      final focus = (tester.state(find.byType(RoomPage)) as dynamic)
          .inputFocusNode as FocusNode;
      focus.requestFocus();
      for (final inset in [0.0, 160.0, 320.0, 160.0, 0.0]) {
        fixture.a.resetReads();
        fixture.store.resetCounts();
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        input.value = const TextEditingValue(
            text: 'synthetic draft',
            selection: TextSelection(baseOffset: 2, extentOffset: 9));
        await tester.pump(const Duration(milliseconds: 16));
        expect(input.text, 'synthetic draft');
        expect(input.selection,
            const TextSelection(baseOffset: 2, extentOffset: 9));
        expect(controller.historyLoading, isTrue);
        expect(sync.release.isCompleted, isFalse);
        expect(_list(tester).eventIds, before,
            reason:
                'metric-only layout must preserve the admitted history window');
        expect(fixture.a.sourceReads, 0,
            reason:
                'keyboard and selection changes do not invalidate source presentation');
        expect(identical(controller.messages, modelsBefore), isTrue,
            reason:
                'typing and selection do not publish replacement presentation models');
        expect(fixture.store.pageRows + fixture.store.individualReads, 0);
        expect(_list(tester).controller.positions.length, 1);
        expect(tester.takeException(), isNull);
      }
      page.complete();
      sync.complete();
      await _withBothClocks(tester, () async {
        await pending;
        await syncPending;
      }, phase: 'page and sync released');
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.historyLoading, isFalse);
      expect(input.text, 'synthetic draft');
      expect(
          await _withBothClocks(
              tester, () => fixture.store.getTimelineEventCount(fixture.a),
              phase: 'count after concurrent sync'),
          10001);
    } finally {
      page.complete();
      sync.complete();
      await fixture.dispose(tester);
    }
  });

  testWidgets('A to B to A ignores retired page and metadata completion',
      (tester) async {
    final fixture = (await tester.runAsync(() => _Fixture.create(10000)))!;
    final page = _Gate(), metadata = _Gate();
    try {
      final oldLease = await fixture.mount(tester, fixture.a);
      final oldController = _controller(tester);
      fixture.store.nextPage = page;
      late Future<void> pending;
      await _withBothClocks(tester, () async {
        pending = oldController
            .loadHistory()
            .then<void>((_) {}, onError: (Object _) {});
        await page.entered.future;
      }, phase: 'old page entered');
      fixture.a.nextMetadata = metadata;
      final metadataPending =
          oldLease.refreshRoomInfo().then<void>((_) {}, onError: (Object _) {});
      await _withBothClocks(tester, () => metadata.entered.future,
          phase: 'old metadata entered');
      final cancelOld = oldLease.cancel();
      final bLease = await fixture.mount(tester, fixture.b);
      expect(_list(tester).eventIds.every((id) => id.startsWith('B-')), isTrue);
      final cancelB = bLease.cancel();
      final newLease = await fixture.mount(tester, fixture.a);
      await tester.pump(const Duration(milliseconds: 100));
      final activeController = _controller(tester);
      final admitted = _list(tester).eventIds.toList();
      final receiptsBefore = fixture.receipts.length;
      expect(identical(activeController, oldController), isFalse);
      page.complete();
      metadata.complete();
      await _withBothClocks(tester, () async {
        await pending;
        await metadataPending;
        await cancelOld;
        await cancelB;
      }, phase: 'retired leases released');
      await tester.pump(const Duration(milliseconds: 100));
      expect(newLease.canceled, isFalse);
      expect(oldLease.canceled, isTrue);
      expect(_list(tester).eventIds, admitted,
          reason: 'a retired lease cannot publish its page to the new A page');
      expect(_list(tester).eventIds.every((id) => id.startsWith('A-')), isTrue);
      expect(fixture.receipts.length, receiptsBefore,
          reason: 'late retired work cannot schedule another read receipt');
      expect(
          LocalMessageSearchRepository.shared
              .search('synthetic B')
              .every((hit) => hit.roomId == fixture.b.id),
          isTrue,
          reason: 'search source attribution cannot leak B rows into A');
      expect(LocalMessageSearchRepository.shared.search('retired-page-marker'),
          isEmpty,
          reason: 'retired page completion must not enqueue new search rows');
      expect(tester.takeException(), isNull);
    } finally {
      page.complete();
      metadata.complete();
      await fixture.dispose(tester);
    }
  });

  testWidgets(
      'idle window admission followed by a drag before layout keeps gesture continuity',
      (tester) async {
    final fixture = (await tester.runAsync(() => _Fixture.create(10000)))!;
    try {
      await fixture.mount(tester, fixture.a);
      final controller = _controller(tester);
      final scroll = _list(tester).controller;
      scroll.jumpTo(scroll.position.maxScrollExtent - 40);
      await tester.pump();
      expect(controller.hasEarlierWindow, isTrue);
      final before = _list(tester).eventIds.toList();
      // The real controller accepts the shift synchronously and its publication
      // is pending layout. Start the next gesture before that next layout.
      final shift = controller.showEarlierWindow();
      final gesture = await tester
          .startGesture(tester.getCenter(find.byType(AnchoredTimelineList)));
      await gesture.moveBy(const Offset(0, 24));
      await tester.pump();
      await shift;
      expect(_list(tester).eventIds, isNot(before),
          reason: 'a genuine window shift must occur');
      expect(scroll.position.activity, isA<DragScrollActivity>());
      final first = scroll.offset;
      await gesture.moveBy(const Offset(0, 12));
      await tester.pump(const Duration(milliseconds: 16));
      final second = scroll.offset;
      await gesture.moveBy(const Offset(0, 12));
      await tester.pump(const Duration(milliseconds: 16));
      expect((second - first).abs(), lessThan(80));
      expect((scroll.offset - second).abs(), lessThan(80));
      expect(scroll.position.activity, isA<DragScrollActivity>());
      expect(scroll.positions.length, 1);
      expect(tester.takeException(), isNull);
      await gesture.up();
    } finally {
      await fixture.dispose(tester);
    }
  });
  testWidgets(
      'actual RoomPage keeps ballistic anchor after an admitted window shift',
      (tester) async {
    final fixture = (await tester.runAsync(() => _Fixture.create(10000)))!;
    try {
      await fixture.mount(tester, fixture.a);
      final controller = _controller(tester);
      await controller.showEarlierWindow();
      // Let the expanded lazy sliver publish its new dimensions before using
      // maxScrollExtent to position at the retained overlap.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      final scroll = _list(tester).controller;
      // A short seek makes the expanded lazy delegate estimate its full
      // 200-row extent. Idle pumps alone retain its previous short estimate.
      scroll.jumpTo(100);
      await tester.pump();
      expect(scroll.position.maxScrollExtent,
          greaterThan(scroll.position.viewportDimension * 6));
      scroll.jumpTo(scroll.position.maxScrollExtent -
          scroll.position.viewportDimension * 2.4);
      await tester.pump();
      await tester.fling(
          find.byType(AnchoredTimelineList), const Offset(0, 180), 2500);
      await tester.pump(const Duration(milliseconds: 16));
      expect(scroll.position.activity, isA<BallisticScrollActivity>());
      final viewport = tester
          .widget<GestureDetector>(find
              .ancestor(
                  of: find.byType(AnchoredTimelineList),
                  matching: find.byWidgetPredicate(
                      (w) => w is GestureDetector && w.key is GlobalKey))
              .first)
          .key! as GlobalKey;
      final keys = _list(tester).messageKeys;
      final anchor = TimelineScrollAnchor.capture(keys, viewport)!;
      double anchorY() =>
          (keys[anchor.eventId]!.currentContext!.findRenderObject()!
                  as RenderBox)
              .localToGlobal(Offset.zero)
              .dy;
      final before = anchorY();
      final idsBefore = _list(tester).eventIds.toList();
      expect(idsBefore.indexOf(anchor.eventId), greaterThanOrEqualTo(100),
          reason: 'visible anchor must be in the retained 100-row overlap');
      expect(controller.hasEarlierWindow, isTrue);
      await controller.showEarlierWindow();
      await tester.pump();
      expect(_list(tester).eventIds, isNot(idsBefore));
      final idsAfter = _list(tester).eventIds;
      expect(idsAfter, contains(anchor.eventId));
      expect(keys[anchor.eventId]?.currentContext, isNotNull);
      expect(anchorY(), closeTo(before, 1));
      var previous = before;
      for (var tick = 0; tick < 3; tick++) {
        await tester.pump(const Duration(milliseconds: 16));
        final current = anchorY();
        expect((current - previous).abs(), lessThan(100),
            reason: 'actual bubble must remain continuous on ballistic ticks');
        expect(scroll.position.activity, isA<BallisticScrollActivity>());
        expect(scroll.positions.length, 1);
        expect(controller.messages.length, lessThanOrEqualTo(200));
        previous = current;
      }
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });
}
