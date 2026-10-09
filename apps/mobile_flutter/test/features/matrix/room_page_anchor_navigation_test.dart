import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';
import 'package:liuhetong_mobile/features/matrix/room_navigation_coordinator.dart';
import 'package:liuhetong_mobile/features/matrix/room_route_frame_probe.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/ui/chat/message_highlight_pulse.dart';
import 'profile_repository_test.dart' show MemoryProfileStore;

/// Task B：全局搜索 / 深链的房间导航 anchor 契约。
///
/// `RoomOpenRequest.anchorEventId → RoomPage.initialAnchorEventId`，进入房间后
/// 定位并高亮该消息；没有 anchor 时不得高亮任何消息。
final class _AnchorClient extends Client {
  _AnchorClient({String roomId = '!anchor:test'}) : super('room-anchor-test') {
    room = _AnchorRoom(this, roomId);
  }

  late final _AnchorRoom room;

  @override
  String? get userID => '@anchor-user:test';

  @override
  Room? getRoomById(String roomId) => roomId == room.id ? room : null;
}

final class _AnchorRoom extends Room {
  _AnchorRoom(Client client, String roomId) : super(id: roomId, client: client);
  Completer<void>? timelineGate;
  Completer<Timeline>? contextGate;
  Object? contextError;
  int liveMessageCount = 3;
  final timelines = <_AnchorTimeline>[];
  final contextRequests = <String>[];

  @override
  bool get isDirectChat => false;

  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
  }) async {
    if (timelineGate != null) await timelineGate!.future;
    if (eventContextId != null) {
      contextRequests.add(eventContextId);
      if (contextError != null) throw contextError!;
      if (contextGate != null) return contextGate!.future;
    }
    final timeline = _AnchorTimeline(this,
        eventContextId: eventContextId, liveMessageCount: liveMessageCount);
    timelines.add(timeline);
    return timeline;
  }
}

final class _TrackedContextTimeline extends Timeline {
  _TrackedContextTimeline(Room room)
      : super(
            room: room,
            chunk: TimelineChunk(isFragment: true, events: [
              Event(
                room: room,
                eventId: r'$cold-old',
                senderId: '@synthetic:test',
                type: EventTypes.Message,
                originServerTs: DateTime.utc(2025, 9, 1),
                content: {
                  'msgtype': MessageTypes.Text,
                  'body': 'synthetic context'
                },
              )
            ]));
  int subscriptionCancels = 0;
  @override
  void cancelSubscriptions() {
    subscriptionCancels++;
    super.cancelSubscriptions();
  }
}

final class _AnchorTimeline extends Fake implements Timeline {
  _AnchorTimeline(Room room, {String? eventContextId, int liveMessageCount = 3})
      : events = [
          for (var index = 1;
              index <=
                  (eventContextId == null
                      ? liveMessageCount
                      : eventContextId == r'$cold-old'
                          ? 1
                          : 0);
              index++)
            Event(
              room: room,
              eventId: eventContextId ?? r'$m' '$index',
              senderId: '@peer:test',
              type: EventTypes.Message,
              originServerTs: DateTime.utc(2026, 9, 10 + index),
              content: {'msgtype': 'm.text', 'body': '消息$index'},
            ),
        ];

  @override
  final List<Event> events;

  @override
  bool get isFragmentedTimeline => false;

  @override
  bool get canRequestHistory => false;

  @override
  bool get canRequestFuture => false;

  @override
  Future<void> setReadMarker({String? eventId, bool? public}) async {}

  @override
  void cancelSubscriptions() {}
}

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

Future<BusinessApiClient> _api() async {
  final session = SecureSessionStore(_MemoryStore());
  await session.saveSession(
      accessToken: 'test-access', refreshToken: 'test-refresh');
  return BusinessApiClient(
    baseUri: Uri.parse('https://business.test'),
    sessionStore: session,
    client: MockClient((request) async {
      if (request.url.path.endsWith('/profile/me')) {
        return http.Response(
          '{"username":"anchor-user","nickname":"Anchor user",'
          '"masked_email":"","avatar_fallback_seed":"anchor-user"}',
          200,
        );
      }
      return http.Response('{}', 404);
    }),
  );
}

Future<void> _pumpRoom(WidgetTester tester, String? anchorEventId,
    {PerformanceTrace? performanceTrace,
    Stream<SyncStatusUpdate>? remoteSyncStatus,
    bool remoteSyncAlreadyReady = false,
    Completer<void>? timelineGate,
    ValueNotifier<RoomOpenRequest>? navigationRequests,
    String roomId = '!anchor:test',
    VoidCallback? onPerformanceContentReady,
    RoomRouteFrameProbe? roomRouteProbe,
    PerformanceTraceRecorder? interactionRecorder,
    void Function()? afterFirstFrame,
    void Function(_AnchorClient)? onClient}) async {
  final client = _AnchorClient(roomId: roomId);
  onClient?.call(client);
  client.room.timelineGate = timelineGate;
  final identities = ProfileRepository.forTesting(
    accountKey: 'matrix:@anchor-user:test',
    store: MemoryProfileStore(),
    loadProfile: () async => const ProfileData(
      username: 'anchor-user',
      nickname: 'Anchor user',
      maskedEmail: '',
      fallbackSeed: 'anchor-user',
    ),
    loadContacts: () async => const [],
  );
  await identities.preload();
  final lease = await MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://matrix.test'))
      .openRoomLease(client.room.id);
  await tester.pumpWidget(CupertinoApp(
    home: RoomPage(
      api: await _api(),
      performanceTrace: performanceTrace,
      onPerformanceContentReady: onPerformanceContentReady,
      roomRouteProbe: roomRouteProbe,
      interactionRecorder: interactionRecorder,
      remoteSyncStatus: remoteSyncStatus,
      remoteSyncAlreadyReady: remoteSyncAlreadyReady,
      roomLease: lease,
      roomName: 'Anchor room',
      initialIdentityCache: identities,
      initialAnchorEventId: anchorEventId,
      navigationRequests: navigationRequests,
      onCreateGroup: () {},
    ),
  ));
  afterFirstFrame?.call();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

MessageHighlightPulse? _pulseFor(WidgetTester tester, String eventId) {
  final row = find.byKey(ValueKey(eventId));
  if (row.evaluate().isEmpty) return null;
  final pulse =
      find.descendant(of: row, matching: find.byType(MessageHighlightPulse));
  if (pulse.evaluate().isEmpty) return null;
  return tester.widget<MessageHighlightPulse>(pulse.first);
}

/// 1.5s 高亮脉冲结束后卸载组件树，避免测试结束时残留计时器。
Future<void> _disposeRoom(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1600));
  await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
  await tester.pump();
}

void main() {
  testWidgets(
      'starting a user drag cancels delayed context before it can replace current rows',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final gate = Completer<Timeline>();
    final navigation = ValueNotifier(const RoomOpenRequest(
        roomId: '!drag-cancel-context:test', roomName: 'synthetic'));
    late _AnchorClient client;
    await _pumpRoom(tester, null,
        roomId: '!drag-cancel-context:test',
        navigationRequests: navigation, onClient: (value) {
      client = value;
      client.room.contextGate = gate;
      client.room.liveMessageCount = 100;
    });
    navigation.value = const RoomOpenRequest(
        roomId: '!drag-cancel-context:test',
        roomName: 'synthetic',
        anchorEventId: r'$cold-old');
    for (var i = 0; i < 20 && client.room.contextRequests.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(client.room.contextRequests, [r'$cold-old']);
    final before = tester
        .widget<AnchoredTimelineList>(find.byType(AnchoredTimelineList))
        .eventIds
        .toList();
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(AnchoredTimelineList)));
    // DragStartBehavior.start enters DragScrollActivity without a direction
    // update: source cancellation must happen at the start itself.
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump();
    final scrollable = tester.state<ScrollableState>(find
        .descendant(
            of: find.byType(AnchoredTimelineList),
            matching: find.byType(Scrollable))
        .first);
    expect(scrollable.position.activity, isA<DragScrollActivity>());
    final late = _TrackedContextTimeline(client.room);
    gate.complete(late);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
        tester
            .widget<AnchoredTimelineList>(find.byType(AnchoredTimelineList))
            .eventIds,
        before);
    expect(late.subscriptionCancels, 1);
    expect(find.byKey(const ValueKey(r'$cold-old')), findsNothing);
    expect(find.text('未找到该消息，请稍后重试'), findsNothing);
    await gesture.up();
    await _disposeRoom(tester);
    navigation.dispose();
    expect(tester.takeException(), isNull);
  });

  for (final variant in [
    'denied',
    'unauthorized',
    'unavailable',
    'timeout',
    'missing'
  ]) {
    testWidgets('context $variant shows an accurate safe locator message',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final error = variant == 'timeout'
          ? TimeoutException('synthetic context wait')
          : MatrixException(http.Response(
              switch (variant) {
                'denied' => '{"errcode":"M_FORBIDDEN","error":"synthetic"}',
                'unauthorized' =>
                  '{"errcode":"M_UNAUTHORIZED","error":"synthetic"}',
                'missing' => '{"errcode":"M_NOT_FOUND","error":"synthetic"}',
                _ => '{"errcode":"M_UNKNOWN","error":"synthetic"}',
              },
              variant == 'unavailable'
                  ? 503
                  : variant == 'missing'
                      ? 404
                      : 403));
      await _pumpRoom(tester, r'$cold-old',
          roomId: '!locator-feedback-$variant:test',
          onClient: (client) => client.room.contextError = error);
      expect(
          find.text(switch (variant) {
            'denied' || 'unauthorized' => '无权限查看该消息',
            'missing' => '未找到该消息，请稍后重试',
            _ => '消息暂时无法定位，请稍后重试',
          }),
          findsOneWidget);
      if (variant != 'missing') expect(find.text('未找到该消息，请稍后重试'), findsNothing);
      expect(find.text('synthetic'), findsNothing);
      await _disposeRoom(tester);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('cold old-event route opens context and highlights exact bubble',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    late _AnchorClient client;
    await _pumpRoom(tester, r'$cold-old',
        roomId: '!cold-anchor:test', onClient: (value) => client = value);
    expect(client.room.contextRequests, [r'$cold-old']);
    expect(_pulseFor(tester, r'$cold-old'), isNotNull);
    expect(tester.takeException(), isNull);
    await _disposeRoom(tester);
  });
  testWidgets(
      'composer panels retain timeline projection while viewport resizes',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    late _AnchorClient client;
    addTearDown(tester.view.resetViewInsets);
    await _pumpRoom(tester, null,
        roomId: '!composer-projection:test',
        onClient: (value) => client = value);
    final list =
        tester.widget<AnchoredTimelineList>(find.byType(AnchoredTimelineList));
    final beforeHeight =
        tester.getSize(find.byType(AnchoredTimelineList)).height;
    await tester.tap(find.byKey(const Key('composer-more')));
    await tester.pump(const Duration(milliseconds: 60));
    final after =
        tester.widget<AnchoredTimelineList>(find.byType(AnchoredTimelineList));
    expect(identical(after.eventIds, list.eventIds), isTrue,
        reason: 'composer state must not allocate a fresh timeline projection');
    expect(identical(after, list), isTrue,
        reason:
            'retaining the child skips timeline filtering/indexing/build work');
    expect(tester.getSize(find.byType(AnchoredTimelineList)).height,
        lessThan(beforeHeight));
    await tester.tap(find.byKey(const Key('composer-more')));
    await tester.pump();
    final input = tester
        .widget<CupertinoTextField>(find.byType(CupertinoTextField).first);
    input.focusNode!.requestFocus();
    await tester.pump();
    for (final inset in [40.0, 80.0, 120.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
      expect(
          identical(
              tester.widget<AnchoredTimelineList>(
                  find.byType(AnchoredTimelineList)),
              list),
          isTrue);
    }
    for (var i = 0; i < 20; i++) {
      for (final timeline in client.room.timelines) {
        timeline.events.insert(
            0,
            Event(
                room: client.room,
                eventId: 'incoming-$i',
                senderId: '@peer:test',
                type: EventTypes.Message,
                originServerTs:
                    DateTime.utc(2026, 10, 3).add(Duration(seconds: i)),
                content: {'msgtype': 'm.text', 'body': 'incoming fixture $i'}));
      }
      client.onEvent.add(EventUpdate(
          roomID: client.room.id,
          type: EventUpdateType.decryptedTimelineQueue,
          content: {
            'event_id': 'incoming-$i',
            'type': EventTypes.Message,
            'content': {'msgtype': 'm.text', 'body': 'incoming fixture $i'}
          }));
    }
    await tester.pump();
    await tester.pump();
    final updated =
        tester.widget<AnchoredTimelineList>(find.byType(AnchoredTimelineList));
    expect(updated.eventIds, hasLength(23));
    expect(updated.eventIds.first, 'incoming-19');
    expect(identical(updated, list), isFalse,
        reason: 'incoming messages must invalidate the retained timeline');
    input.focusNode!.unfocus();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    expect(tester.takeException(), isNull);
    await _disposeRoom(tester);
  });

  testWidgets('room first frame completes local route span before sync',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      enabled: () => true,
      onRecord: records.add,
    );
    final routeProbe = RoomRouteFrameProbe(recorder)..beginEnter();
    final sync = StreamController<SyncStatusUpdate>.broadcast(sync: true);
    addTearDown(sync.close);
    await _pumpRoom(tester, null,
        roomRouteProbe: routeProbe,
        remoteSyncStatus: sync.stream,
        timelineGate: Completer<void>(),
        roomId: '!route-frame:test');
    expect(records, hasLength(1));
    expect(records.single.operation, PerformanceOperationType.roomLocalFrame);
    expect(records.single.result, PerformanceResult.success);
    expect(records.single.stagesUs,
        contains(PerformanceStage.roomLocalFirstFrame));
    await _disposeRoom(tester);
    routeProbe.dispose();
  });

  testWidgets('composer focus measures stable keyboard frame locally',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      enabled: () => true,
      onRecord: records.add,
    );
    addTearDown(tester.view.resetViewInsets);
    await _pumpRoom(tester, null,
        interactionRecorder: recorder, roomId: '!keyboard-frame:test');
    final input = tester
        .widget<CupertinoTextField>(find.byType(CupertinoTextField).first);
    input.focusNode!.requestFocus();
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pumpAndSettle();
    var keyboard = records
        .where((record) =>
            record.operation == PerformanceOperationType.keyboardTransition)
        .toList();
    expect(keyboard, hasLength(1));
    expect(keyboard.single.result, PerformanceResult.success);
    expect(
        keyboard.single.keyboardDirection, PerformanceKeyboardDirection.show);
    expect(keyboard.single.stagesUs,
        contains(PerformanceStage.keyboardStableFrame));
    input.focusNode!.unfocus();
    await tester.pump();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    keyboard = records
        .where((record) =>
            record.operation == PerformanceOperationType.keyboardTransition)
        .toList();
    expect(keyboard, hasLength(2));
    expect(keyboard.last.result, PerformanceResult.success);
    expect(keyboard.last.keyboardDirection, PerformanceKeyboardDirection.hide);
    await _disposeRoom(tester);
  });

  testWidgets('打开房间时 anchor 消息被定位并高亮（其他消息不高亮）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpRoom(tester, r'$m2');

    expect(_pulseFor(tester, r'$m2')?.active, isTrue, reason: 'anchor 消息必须高亮');
    expect(_pulseFor(tester, r'$m1')?.active, isFalse);
    expect(_pulseFor(tester, r'$m3')?.active, isFalse);
    expect(tester.takeException(), isNull);
    await _disposeRoom(tester);
  });

  testWidgets('没有 anchor 时不高亮任何消息', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpRoom(tester, null);

    for (final id in [r'$m1', r'$m2', r'$m3']) {
      expect(_pulseFor(tester, id)?.active ?? false, isFalse);
    }
    expect(tester.takeException(), isNull);
    await _disposeRoom(tester);
  });

  testWidgets('anchor 指向不存在的消息时不崩溃、不高亮', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpRoom(tester, r'$missing');

    for (final id in [r'$m1', r'$m2', r'$m3']) {
      expect(_pulseFor(tester, id)?.active ?? false, isFalse);
    }
    expect(tester.takeException(), isNull);
    await _disposeRoom(tester);
  });

  testWidgets(
      'room trace observes actual early sync independently of local load',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final records = <PerformanceRecord>[];
    var tick = 0;
    final recorder = PerformanceTraceRecorder(
      enabled: () => true,
      clockUs: () => tick += 1000,
      onRecord: records.add,
    );
    final trace = recorder.start(PerformanceOperationType.conversationOpen)
      ..mark(PerformanceStage.userAction)
      ..mark(PerformanceStage.routePushStarted);
    final sync = StreamController<SyncStatusUpdate>.broadcast(sync: true);
    final timelineGate = Completer<void>();
    var contentReady = 0;
    addTearDown(sync.close);
    await _pumpRoom(tester, null,
        performanceTrace: trace,
        remoteSyncStatus: sync.stream,
        timelineGate: timelineGate,
        roomId: '!anchor-performance:test',
        onPerformanceContentReady: () => contentReady++,
        afterFirstFrame: () {
          sync.add(SyncStatusUpdate(SyncStatus.finished));
          timelineGate.complete();
        });
    final record = records.single;
    expect(contentReady, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(contentReady, 2);
    await _disposeRoom(tester);
    expect(record.stagesUs, contains(PerformanceStage.firstFrameRendered));
    expect(record.stagesUs, contains(PerformanceStage.localTimelineReady));
    expect(record.stagesUs, contains(PerformanceStage.remoteSyncReady));
    expect(record.stagesUs[PerformanceStage.remoteSyncReady],
        lessThan(record.stagesUs[PerformanceStage.localTimelineReady]!));
  });

  testWidgets('room trace keeps measured sync phases on its operation ID',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final records = <PerformanceRecord>[];
    var tick = 0;
    final recorder = PerformanceTraceRecorder(
      enabled: () => true,
      clockUs: () => tick += 1000,
      onRecord: records.add,
    );
    final trace = recorder.start(PerformanceOperationType.conversationOpen)
      ..mark(PerformanceStage.userAction)
      ..mark(PerformanceStage.routePushStarted);
    final sync = StreamController<SyncStatusUpdate>.broadcast(sync: true);
    final timelineGate = Completer<void>();
    addTearDown(sync.close);
    await _pumpRoom(tester, null,
        performanceTrace: trace,
        remoteSyncStatus: sync.stream,
        timelineGate: timelineGate,
        roomId: '!anchor-sync-phases:test', afterFirstFrame: () {
      sync.add(SyncStatusUpdate(SyncStatus.waitingForResponse));
      sync.add(SyncStatusUpdate(SyncStatus.processing));
      sync.add(SyncStatusUpdate(SyncStatus.cleaningUp));
      sync.add(SyncStatusUpdate(SyncStatus.finished));
      timelineGate.complete();
    });
    final record = records.single;
    expect(record.operationId, trace.operationId);
    expect(
        record.stagesUs.keys,
        containsAll([
          PerformanceStage.syncResponseWaitStarted,
          PerformanceStage.syncResponseReceived,
          PerformanceStage.syncProcessingDone,
          PerformanceStage.syncCleanupDone,
          PerformanceStage.remoteSyncReady,
        ]));
    expect(record.timingSummaryMs['sync_response_wait_ms'], greaterThan(0));
    expect(record.timingSummaryMs['sync_processing_ms'], greaterThan(0));
    expect(record.timingSummaryMs['sync_cleanup_ms'], greaterThan(0));
    await _disposeRoom(tester);
  });

  testWidgets('room trace excludes synthetic progress from sync phase timing',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final records = <PerformanceRecord>[];
    var nowUs = 0;
    final recorder = PerformanceTraceRecorder(
        enabled: () => true, clockUs: () => nowUs, onRecord: records.add);
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    final sync = StreamController<SyncStatusUpdate>.broadcast(sync: true);
    final timelineGate = Completer<void>();
    addTearDown(sync.close);
    await _pumpRoom(tester, null,
        performanceTrace: trace,
        remoteSyncStatus: sync.stream,
        timelineGate: timelineGate,
        roomId: '!anchor-synthetic-progress:test', afterFirstFrame: () {
      sync.add(SyncStatusUpdate(SyncStatus.waitingForResponse));
      nowUs = 1000000;
      sync.add(SyncStatusUpdate(SyncStatus.processing, progress: 1));
      nowUs = 30000000;
      sync.add(SyncStatusUpdate(SyncStatus.processing));
      nowUs = 30040000;
      sync.add(SyncStatusUpdate(SyncStatus.cleaningUp));
      nowUs = 30042000;
      sync.add(SyncStatusUpdate(SyncStatus.finished));
      timelineGate.complete();
    });
    final record = records.single;
    expect(record.timingSummaryMs['sync_response_wait_ms'], 30000);
    expect(record.timingSummaryMs['sync_processing_ms'], 40);
    expect(record.timingSummaryMs['sync_cleanup_ms'], 2);
    expect(record.stagesUs, contains(PerformanceStage.remoteSyncReady));
    await _disposeRoom(tester);
  });

  testWidgets('mid-cycle room entry measures processing without a wait start',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final records = <PerformanceRecord>[];
    final recorder =
        PerformanceTraceRecorder(enabled: () => true, onRecord: records.add);
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    final sync = StreamController<SyncStatusUpdate>.broadcast(sync: true);
    final timelineGate = Completer<void>();
    addTearDown(sync.close);
    await _pumpRoom(tester, null,
        performanceTrace: trace,
        remoteSyncStatus: sync.stream,
        timelineGate: timelineGate,
        roomId: '!anchor-mid-cycle:test', afterFirstFrame: () {
      sync.add(SyncStatusUpdate(SyncStatus.processing));
      sync.add(SyncStatusUpdate(SyncStatus.cleaningUp));
      sync.add(SyncStatusUpdate(SyncStatus.finished));
      timelineGate.complete();
    });
    final record = records.single;
    expect(record.stagesUs,
        isNot(contains(PerformanceStage.syncResponseWaitStarted)));
    expect(record.stagesUs, contains(PerformanceStage.syncResponseReceived));
    expect(record.stagesUs, contains(PerformanceStage.syncProcessingDone));
    expect(record.stagesUs, contains(PerformanceStage.syncCleanupDone));
    expect(
        record.timingSummaryMs.containsKey('sync_response_wait_ms'), isFalse);
    await _disposeRoom(tester);
  });

  testWidgets('failed sync cycle never joins phases from a later retry',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final records = <PerformanceRecord>[];
    final recorder =
        PerformanceTraceRecorder(enabled: () => true, onRecord: records.add);
    final trace = recorder.start(PerformanceOperationType.conversationOpen);
    final sync = StreamController<SyncStatusUpdate>.broadcast(sync: true);
    final timelineGate = Completer<void>();
    addTearDown(sync.close);
    await _pumpRoom(tester, null,
        performanceTrace: trace,
        remoteSyncStatus: sync.stream,
        timelineGate: timelineGate,
        roomId: '!anchor-sync-retry:test', afterFirstFrame: () {
      sync.add(SyncStatusUpdate(SyncStatus.waitingForResponse));
      sync.add(SyncStatusUpdate(SyncStatus.processing));
      sync.add(SyncStatusUpdate(SyncStatus.error));
      sync.add(SyncStatusUpdate(SyncStatus.waitingForResponse));
      sync.add(SyncStatusUpdate(SyncStatus.processing));
      sync.add(SyncStatusUpdate(SyncStatus.cleaningUp));
      sync.add(SyncStatusUpdate(SyncStatus.finished));
      timelineGate.complete();
    });
    final record = records.single;
    expect(record.stagesUs, contains(PerformanceStage.remoteSyncReady));
    expect(
        record.stagesUs, isNot(contains(PerformanceStage.syncProcessingDone)));
    expect(record.stagesUs, isNot(contains(PerformanceStage.syncCleanupDone)));
    expect(record.timingSummaryMs.containsKey('sync_processing_ms'), isFalse);
    expect(record.timingSummaryMs.containsKey('sync_cleanup_ms'), isFalse);
    await _disposeRoom(tester);
  });

  testWidgets('preconnected Matrix still records first frame before trace ends',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final records = <PerformanceRecord>[];
    final recorder =
        PerformanceTraceRecorder(enabled: () => true, onRecord: records.add);
    final trace = recorder.start(PerformanceOperationType.conversationOpen)
      ..mark(PerformanceStage.userAction)
      ..mark(PerformanceStage.routePushStarted);
    await _pumpRoom(tester, null,
        roomId: '!anchor-preconnected:test',
        performanceTrace: trace,
        remoteSyncAlreadyReady: true);
    final record = records.single;
    await _disposeRoom(tester);
    expect(record.stagesUs, contains(PerformanceStage.firstFrameRendered));
    expect(record.stagesUs, contains(PerformanceStage.localTimelineReady));
    expect(record.stagesUs, contains(PerformanceStage.remoteSyncReady));
  });

  testWidgets(
      'leaving before local timeline readiness retains a cancelled trace',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final records = <PerformanceRecord>[];
    final recorder =
        PerformanceTraceRecorder(enabled: () => true, onRecord: records.add);
    final trace = recorder.start(PerformanceOperationType.conversationOpen)
      ..mark(PerformanceStage.userAction)
      ..mark(PerformanceStage.routePushStarted);
    final timelineGate = Completer<void>();
    await _pumpRoom(tester, null,
        roomId: '!anchor-abandoned:test',
        performanceTrace: trace,
        timelineGate: timelineGate);
    expect(trace.isRecording, isTrue);
    await _disposeRoom(tester);
    expect(records, hasLength(1));
    expect(records.single.result, PerformanceResult.cancelled);
    expect(
        records.single.stagesUs, contains(PerformanceStage.firstFrameRendered));
    expect(records.single.stagesUs,
        isNot(contains(PerformanceStage.localTimelineReady)));
  });
}
