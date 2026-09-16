import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';
import 'package:liuhetong_mobile/features/matrix/room_history_date_capability.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _DateTimeline extends Fake implements Timeline {
  @override
  final events = <Event>[];
  int subscriptionCancels = 0;
  int futureCalls = 0;
  bool future = false;
  Future<void> Function()? onFuture;
  @override
  bool get canRequestFuture => future;
  @override
  Future<void> requestFuture({int historyCount = 20}) async {
    futureCalls++;
    await onFuture?.call();
  }

  @override
  void cancelSubscriptions() {
    subscriptionCancels++;
  }
}

final class _DateClient extends Client {
  _DateClient() : super('history-date-test');

  late Room room;
  final timestampCalls =
      <(String roomId, int timestamp, Direction direction)>[];
  Completer<GetEventByTimestampResponse>? pendingTimestamp;
  GetEventByTimestampResponse? timestampResult;

  @override
  Room? getRoomById(String id) => room.id == id ? room : null;

  @override
  Future<GetEventByTimestampResponse> getEventByTimestamp(
    String roomId,
    int timestamp,
    Direction direction,
  ) {
    timestampCalls.add((roomId, timestamp, direction));
    final pending = pendingTimestamp;
    if (pending != null) return pending.future;
    return Future.value(timestampResult!);
  }
}

final class _DateRoom extends Room {
  _DateRoom(this.dateClient)
      : super(id: '!history-date:test', client: dateClient) {
    dateClient.room = this;
  }

  final _DateClient dateClient;
  final live = _DateTimeline();
  _DateTimeline? context;
  Completer<Timeline>? pendingContext;
  final contextEventIds = <String>[];
  void Function()? contextOnUpdate;

  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
  }) {
    if (eventContextId == null) return Future.value(live);
    contextEventIds.add(eventContextId);
    contextOnUpdate = onUpdate;
    final pending = pendingContext;
    if (pending != null) return pending.future;
    return Future.value(context!);
  }
}

Future<MatrixClientContinuityMetadata> _continuity(Client client) async =>
    MatrixClientContinuityMetadata(
      isLoggedIn: client.isLogged(),
      userId: client.userID,
      deviceId: client.deviceID,
      ed25519Fingerprint: 'date-fixture',
      databaseGeneration: 'date-fixture',
    );

Event _message(_DateRoom room, String id, DateTime timestamp) => Event(
      room: room,
      eventId: id,
      senderId: '@peer:test',
      type: EventTypes.Message,
      originServerTs: timestamp,
      content: {'msgtype': MessageTypes.Text, 'body': 'fixture'},
    );

Future<(MatrixRoomLease, RoomHistoryDateCapability)> _openCapability(
    _DateRoom room) async {
  final owner = MatrixSdkE2eeClient(
    room.dateClient,
    homeserver: Uri.parse('https://matrix.invalid'),
    readContinuityMetadata: _continuity,
  );
  final lease = await owner.openRoomLease(room.id);
  final capability = await lease.openRoomTimeline(onUpdate: () {});
  return (lease, capability as RoomHistoryDateCapability);
}

void main() {
  test('date lookup uses one forward timestamp request and adopts its context',
      () async {
    final client = _DateClient();
    final room = _DateRoom(client);
    final day = DateTime(2026, 9, 5);
    final context = _DateTimeline()
      ..events
          .add(_message(room, r'$selected', day.add(const Duration(hours: 8))));
    room.context = context;
    client.timestampResult = GetEventByTimestampResponse(
      eventId: r'$anchor',
      originServerTs: day.add(const Duration(hours: 1)).millisecondsSinceEpoch,
    );
    final owner = MatrixSdkE2eeClient(
      room.dateClient,
      homeserver: Uri.parse('https://matrix.invalid'),
      readContinuityMetadata: _continuity,
    );
    final lease = await owner.openRoomLease(room.id);
    var updates = 0;
    final capability = (await lease.openRoomTimeline(onUpdate: () {
      updates++;
    })) as RoomHistoryDateCapability;

    final location = await capability.locateDay(day);

    expect(location?.eventId, r'$selected');
    expect(room.contextEventIds, [r'$anchor']);
    expect(client.timestampCalls, hasLength(1));
    expect(client.timestampCalls.single.$1, room.id);
    expect(client.timestampCalls.single.$2, day.millisecondsSinceEpoch);
    expect(client.timestampCalls.single.$3, Direction.f);
    expect(capability.loadedDayMetadata.map((item) => item.day), contains(day));

    // A repeated local lookup must not invalidate the adopted context's SDK
    // callback: the context continues to receive redactions and forward pages.
    await capability.locateDay(day);
    expect(client.timestampCalls, hasLength(1));
    room.contextOnUpdate!();
    expect(updates, 2);
    await lease.cancel();
  });

  test('loaded date lookup uses the SDK timeline without an HTTP request',
      () async {
    final client = _DateClient();
    final room = _DateRoom(client);
    final day = DateTime(2026, 9, 6);
    room.live.events.add(
        _message(room, r'$already-loaded', day.add(const Duration(hours: 12))));
    final (lease, capability) = await _openCapability(room);

    final location = await capability.locateDay(day);

    expect(location?.eventId, r'$already-loaded');
    expect(client.timestampCalls, isEmpty);
    expect(room.contextEventIds, isEmpty);
    await lease.cancel();
  });

  test('an earlier timestamp response is incomplete rather than an empty day',
      () async {
    final client = _DateClient();
    final room = _DateRoom(client);
    final day = DateTime(2026, 9, 6);
    client.timestampResult = GetEventByTimestampResponse(
      eventId: r'$earlier-anchor',
      originServerTs:
          day.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
    );
    final (lease, capability) = await _openCapability(room);

    await expectLater(
      capability.locateDay(day),
      throwsA(isA<RoomHistoryLookupIncomplete>()),
    );
    expect(room.contextEventIds, isEmpty);
    await lease.cancel();
  });

  test(
      'live selection and lease cancellation reject a late context and release it',
      () async {
    final client = _DateClient();
    final room = _DateRoom(client);
    final day = DateTime(2026, 9, 7);
    final lateContext = _DateTimeline()
      ..events.add(_message(room, r'$late', day.add(const Duration(hours: 3))));
    room.pendingContext = Completer<Timeline>();
    client.timestampResult = GetEventByTimestampResponse(
      eventId: r'$anchor',
      originServerTs: day.millisecondsSinceEpoch,
    );
    final (lease, capability) = await _openCapability(room);

    final locating = capability.locateDay(day);
    await Future<void>.delayed(Duration.zero);
    expect(room.contextEventIds, [r'$anchor']);

    capability.cancelPendingDateLookup();
    room.pendingContext!.complete(lateContext);
    expect(await locating, isNull);
    expect(lateContext.subscriptionCancels, 1);
    expect(capability.loadedDayMetadata, isEmpty);

    room.pendingContext = Completer<Timeline>();
    final second = capability.locateDay(day);
    await Future<void>.delayed(Duration.zero);
    await lease.cancel();
    final revokedContext = _DateTimeline()
      ..events
          .add(_message(room, r'$revoked', day.add(const Duration(hours: 4))));
    room.pendingContext!.complete(revokedContext);
    expect(await second, isNull);
    expect(revokedContext.subscriptionCancels, 1);
  });

  test('history context keeps newest projection and controller state on live',
      () async {
    final client = _DateClient();
    final room = _DateRoom(client);
    final day = DateTime(2026, 9, 8);
    room.live.events
        .add(_message(room, r'$live-newest', day.add(const Duration(days: 2))));
    room.context = _DateTimeline()
      ..events.add(
          _message(room, r'$context-day', day.add(const Duration(hours: 2))));
    client.timestampResult = GetEventByTimestampResponse(
      eventId: r'$anchor',
      originServerTs: day.millisecondsSinceEpoch,
    );
    final owner = MatrixSdkE2eeClient(
      room.dateClient,
      homeserver: Uri.parse('https://matrix.invalid'),
      readContinuityMetadata: _continuity,
    );
    final lease = await owner.openRoomLease(room.id);
    final capability = await lease.openRoomTimeline(onUpdate: () {});
    final adapter = MatrixRoomTimelineAdapter(capability);
    final controller = RoomTimelineController(adapter, windowed: true);

    expect(controller.isViewingHistoryContext, isFalse);
    final location = await controller.locateDay(day);

    expect(location?.eventId, r'$context-day');
    expect(controller.isViewingHistoryContext, isTrue);
    expect(controller.newestMessage?.id, r'$live-newest',
        reason:
            'the live loaded tail is independent from the context viewport');
    await controller.selectLatest();
    expect(controller.isViewingHistoryContext, isFalse);
    controller.dispose();
    await lease.cancel();
  });

  test('state-only context pages forward to a visible message on the day',
      () async {
    final client = _DateClient();
    final room = _DateRoom(client);
    final day = DateTime(2026, 9, 9);
    final context = _DateTimeline()..future = true;
    context.onFuture = () async {
      context.events
          .add(_message(room, r'$visible', day.add(const Duration(hours: 2))));
      context.future = false;
    };
    room.context = context;
    client.timestampResult = GetEventByTimestampResponse(
        eventId: r'$state', originServerTs: day.millisecondsSinceEpoch);
    final (lease, capability) = await _openCapability(room);
    expect((await capability.locateDay(day))?.eventId, r'$visible');
    await lease.cancel();
  });

  test('failed forward lookup releases only its new context', () async {
    final client = _DateClient();
    final room = _DateRoom(client);
    final selectedDay = DateTime(2026, 9, 10);
    final oldContext = _DateTimeline()
      ..events.add(
          _message(room, r'$old', selectedDay.add(const Duration(hours: 1))));
    room.context = oldContext;
    client.timestampResult = GetEventByTimestampResponse(
      eventId: r'$old-anchor',
      originServerTs: selectedDay.millisecondsSinceEpoch,
    );
    final (lease, capability) = await _openCapability(room);
    await capability.locateDay(selectedDay);

    final nextDay = selectedDay.add(const Duration(days: 1));
    final failedContext = _DateTimeline()
      ..future = true
      ..onFuture = () async => throw StateError('forward failed');
    room.context = failedContext;
    client.timestampResult = GetEventByTimestampResponse(
      eventId: r'$failed-anchor',
      originServerTs: nextDay.millisecondsSinceEpoch,
    );

    await expectLater(capability.locateDay(nextDay), throwsStateError);
    expect(failedContext.subscriptionCancels, 1);
    expect(oldContext.subscriptionCancels, 0,
        reason: 'a failed replacement must preserve the adopted context');
    expect(capability.isViewingHistoryContext, isTrue);
    await lease.cancel();
  });

  test('visible next-day context confirms empty day without a future request',
      () async {
    final client = _DateClient();
    final room = _DateRoom(client);
    final day = DateTime(2026, 9, 11);
    final context = _DateTimeline()
      ..future = true
      ..events
          .add(_message(room, r'$next-day', day.add(const Duration(days: 1))));
    room.context = context;
    client.timestampResult = GetEventByTimestampResponse(
      eventId: r'$anchor',
      originServerTs: day.millisecondsSinceEpoch,
    );
    final (lease, capability) = await _openCapability(room);

    expect(await capability.locateDay(day), isNull);
    expect(context.futureCalls, 0);
    await lease.cancel();
  });

  test('three unreadable forward pages report an incomplete lookup', () async {
    final client = _DateClient();
    final room = _DateRoom(client);
    final day = DateTime(2026, 9, 12);
    final context = _DateTimeline()
      ..future = true
      ..onFuture = () async {};
    room.context = context;
    client.timestampResult = GetEventByTimestampResponse(
      eventId: r'$anchor',
      originServerTs: day.millisecondsSinceEpoch,
    );
    final (lease, capability) = await _openCapability(room);

    await expectLater(
      capability.locateDay(day),
      throwsA(isA<RoomHistoryLookupIncomplete>()),
    );
    expect(context.futureCalls, 3);
    expect(context.subscriptionCancels, 1);
    await lease.cancel();
  });

  test('encrypted same-day context does not turn a next-day row into empty',
      () async {
    final client = _DateClient();
    final room = _DateRoom(client);
    final day = DateTime(2026, 9, 13);
    final context = _DateTimeline()
      ..events.add(Event(
        room: room,
        eventId: r'$encrypted',
        senderId: '@peer:test',
        type: EventTypes.Encrypted,
        originServerTs: day.add(const Duration(hours: 1)),
        content: const {},
      ))
      ..events
          .add(_message(room, r'$next-day', day.add(const Duration(days: 1))))
      ..future = true;
    room.context = context;
    client.timestampResult = GetEventByTimestampResponse(
      eventId: r'$anchor',
      originServerTs: day.millisecondsSinceEpoch,
    );
    final (lease, capability) = await _openCapability(room);

    await expectLater(
      capability.locateDay(day),
      throwsA(isA<RoomHistoryLookupIncomplete>()),
    );
    expect(context.futureCalls, 0,
        reason:
            'the loaded next-day boundary already proves no more scan helps');
    await lease.cancel();
  });

  group('Task A：月级日期 metadata', () {
    test('整月为空由两次有界探测确认，且不加载正文/媒体/上下文', () async {
      SharedPreferences.setMockInitialValues({});
      final client = _DateClient();
      final room = _DateRoom(client);
      final month = const CalendarMonth(2026, 9);
      // 该月起点之后最早的可见事件在 10 月 → 服务端确认 9 月整月为空。
      client.timestampResult = GetEventByTimestampResponse(
        eventId: r'$next-month',
        originServerTs: DateTime(2026, 10, 2).millisecondsSinceEpoch,
      );
      final (lease, capability) = await _openCapability(room);

      final days = await capability.loadMonthDays(month);

      expect(days.month, month);
      expect(days.hasUnknown, isFalse);
      expect(days.coverageComplete, isTrue);
      expect(days.stateOf(15), RoomHistoryDayState.knownEmpty);
      expect(days.presentDates, isEmpty);
      expect(client.timestampCalls, hasLength(2),
          reason: '只有两次有界探测：月起点向后、月终点向前');
      expect(client.timestampCalls.first.$3, Direction.f);
      expect(client.timestampCalls.last.$3, Direction.b);
      expect(room.contextEventIds, isEmpty,
          reason: '月 metadata 查询绝不切换/加载历史上下文');
      await lease.cancel();
    });

    test('月内首个事件成为 anchor，earliestMonth 与 anchorForDay 不再访问服务端',
        () async {
      SharedPreferences.setMockInitialValues({});
      final client = _DateClient();
      final room = _DateRoom(client);
      final month = const CalendarMonth(2026, 9);
      client.timestampResult = GetEventByTimestampResponse(
        eventId: r'$first-of-month',
        originServerTs: DateTime(2026, 9, 12, 9).millisecondsSinceEpoch,
      );
      final (lease, capability) = await _openCapability(room);

      final days = await capability.loadMonthDays(month);

      expect(days.stateOf(12), RoomHistoryDayState.knownPresent);
      expect(days.anchors[12], r'$first-of-month');
      expect(days.stateOf(5), RoomHistoryDayState.knownEmpty,
          reason: '月起点到首个事件之间已确认无事件');
      expect(days.hasUnknown, isFalse);
      expect(capability.earliestMonth, month);
      final probes = client.timestampCalls.length;
      expect(capability.anchorForDay(DateTime(2026, 9, 12)), r'$first-of-month');
      expect(capability.anchorForDay(DateTime(2026, 9, 13)), isNull);
      expect(client.timestampCalls, hasLength(probes),
          reason: 'anchor 查询必须是本地索引读取');
      await lease.cancel();
    });

    test('已知月份命中缓存：重复打开不产生新的探测', () async {
      SharedPreferences.setMockInitialValues({});
      final client = _DateClient();
      final room = _DateRoom(client);
      final month = const CalendarMonth(2026, 9);
      client.timestampResult = GetEventByTimestampResponse(
        eventId: r'$next-month',
        originServerTs: DateTime(2026, 10, 2).millisecondsSinceEpoch,
      );
      final (lease, capability) = await _openCapability(room);

      await capability.loadMonthDays(month);
      final probes = client.timestampCalls.length;
      final again = await capability.loadMonthDays(month);

      expect(client.timestampCalls, hasLength(probes));
      expect(again.stateOf(15), RoomHistoryDayState.knownEmpty);
      await lease.cancel();
    });

    test('取消在途月查询后，过期响应不得把该月发布成"确认空"', () async {
      SharedPreferences.setMockInitialValues({});
      final client = _DateClient();
      final room = _DateRoom(client);
      final month = const CalendarMonth(2026, 9);
      client.pendingTimestamp = Completer<GetEventByTimestampResponse>();
      final (lease, capability) = await _openCapability(room);

      final pending = capability.loadMonthDays(month);
      await Future<void>.delayed(Duration.zero);
      capability.cancelMonthLookup();
      client.pendingTimestamp!.complete(GetEventByTimestampResponse(
        eventId: r'$next-month',
        originServerTs: DateTime(2026, 10, 2).millisecondsSinceEpoch,
      ));

      final days = await pending;
      expect(days.hasUnknown, isTrue,
          reason: '取消 ≠ 确认空；未覆盖的月份必须保持 unknown');
      expect(days.stateOf(15), RoomHistoryDayState.unknown);
      expect(capability.anchorForDay(DateTime(2026, 9, 15)), isNull);
      await lease.cancel();
    });

    test('没有任何日期证据时 earliestMonth 是 null，绝不是 1970', () async {
      SharedPreferences.setMockInitialValues({});
      final client = _DateClient();
      final room = _DateRoom(client);
      final (lease, capability) = await _openCapability(room);

      expect(capability.earliestMonth, isNull);
      await lease.cancel();
    });
  });
}
