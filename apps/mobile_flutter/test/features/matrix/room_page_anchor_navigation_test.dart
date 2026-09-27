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
    return _AnchorTimeline(this);
  }
}

final class _AnchorTimeline extends Fake implements Timeline {
  _AnchorTimeline(Room room)
      : events = [
          for (var index = 1; index <= 3; index++)
            Event(
              room: room,
              eventId: r'$m' '$index',
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
    String roomId = '!anchor:test',
    VoidCallback? onPerformanceContentReady,
    void Function()? afterFirstFrame}) async {
  final client = _AnchorClient(roomId: roomId);
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
      remoteSyncStatus: remoteSyncStatus,
      remoteSyncAlreadyReady: remoteSyncAlreadyReady,
      roomLease: lease,
      roomName: 'Anchor room',
      initialIdentityCache: identities,
      initialAnchorEventId: anchorEventId,
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
