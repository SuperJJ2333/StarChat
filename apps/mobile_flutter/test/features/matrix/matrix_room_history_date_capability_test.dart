import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';
import 'package:liuhetong_mobile/features/matrix/room_history_date_capability.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/room_event_context_capability.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  _DateClient({http.Client? httpClient})
      : super('history-date-test', httpClient: httpClient);

  late Room room;
  DatabaseApi? localStore;
  @override
  DatabaseApi? get database => localStore ?? super.database;
  final timestampCalls =
      <(String roomId, int timestamp, Direction direction)>[];
  Completer<GetEventByTimestampResponse>? pendingTimestamp;
  GetEventByTimestampResponse? timestampResult;
  Object? timestampError;

  @override
  Room? getRoomById(String id) => room.id == id ? room : null;

  @override
  Future<GetEventByTimestampResponse> getEventByTimestamp(
    String roomId,
    int timestamp,
    Direction direction,
  ) {
    timestampCalls.add((roomId, timestamp, direction));
    if (timestampError != null) return Future.error(timestampError!);
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
  Object? contextError;
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
    if (contextError != null) return Future.error(contextError!);
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
  test(
      'loaded window anchor revalidates a newly hidden target before selection',
      () async {
    final client = _DateClient();
    final room = _DateRoom(client);
    room.live.events.add(_message(room, r'$loaded', DateTime(2025)));
    final (lease, capability) = await _openCapability(room);
    final controller = RoomTimelineController(
        MatrixRoomTimelineAdapter(capability as RoomTimelineCapability),
        windowed: true);
    controller.setHiddenFilter((id, _) => id == r'$loaded');
    expect(await controller.openAnchor(r'$loaded'), isFalse);
    expect(room.contextEventIds, isEmpty);
    controller.dispose();
    await lease.cancel();
  });
  test('year-old persisted event opens offline before remote context lookup',
      () async {
    sqfliteFfiInit();
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase(inMemoryDatabasePath,
        database: raw, sqfliteFactory: databaseFactoryFfi);
    await db.open();
    var requests = 0;
    final client = _DateClient(httpClient: MockClient((_) async {
      requests++;
      throw StateError('synthetic offline');
    }))
      ..localStore = db
      ..homeserver = Uri.parse('https://matrix.invalid')
      ..accessToken = 'synthetic-token';
    final room = client.room = Room(id: '!offline:synthetic', client: client);
    for (var i = 0; i < 40; i++) {
      await db.storeEventUpdate(
          EventUpdate(
              roomID: room.id,
              type: EventUpdateType.timeline,
              content: {
                'event_id': 'local-$i',
                'sender': '@synthetic:test',
                'type': EventTypes.Message,
                'origin_server_ts':
                    DateTime(2025, 9, 1 + i).millisecondsSinceEpoch,
                'content': {'msgtype': MessageTypes.Text, 'body': 'synthetic'}
              }),
          client);
    }
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.invalid'),
        readContinuityMetadata: _continuity);
    final lease = await owner.openRoomLease(room.id);
    final capability = await lease.openRoomTimeline(onUpdate: () {});
    final controller = RoomTimelineController(
        MatrixRoomTimelineAdapter(capability),
        windowed: true);
    expect(controller.indexOf('local-0'), isNull);
    expect(await controller.openAnchor('local-0'), isTrue);
    expect(controller.messages.single.id, 'local-0');
    expect(requests, 0);
    expect(controller.newestMessage?.id, 'local-39');
    await controller.showLatest();
    expect(controller.messages.last.id, 'local-39');
    controller.dispose();
    await lease.cancel();
    await db.close();
    await client.dispose();
  });
  test('old explicit event opens SDK context without scanning recent history',
      () async {
    final client = _DateClient();
    final room = _DateRoom(client);
    final old = _message(room, r'$year-old', DateTime(2025, 9, 1));
    room.context = _DateTimeline()..events.add(old);
    final (lease, capability) = await _openCapability(room);
    final controller = RoomTimelineController(
        MatrixRoomTimelineAdapter(capability as RoomTimelineCapability),
        windowed: true);
    await controller.refresh();
    expect(await controller.openAnchor(old.eventId), isTrue);
    expect(controller.indexOf(old.eventId), isNotNull);
    expect(room.contextEventIds, [old.eventId]);
    expect(client.timestampCalls, isEmpty);
    controller.dispose();
    await lease.cancel();
  });

  test(
      'explicit anchor uses the real SDK context endpoint and retains live tail',
      () async {
    final paths = <String>[];
    final client = _DateClient(httpClient: MockClient((request) async {
      paths.add(request.url.path);
      expect(request.url.path, contains('/context/'));
      return http.Response(
          r'{"start":"older","end":"","event":{"event_id":"$remote-old","type":"m.room.message","sender":"@synthetic:test","origin_server_ts":1,"content":{"msgtype":"m.text","body":"synthetic"}},"events_before":[],"events_after":[]}',
          200);
    }));
    client.homeserver = Uri.parse('https://matrix.invalid');
    client.accessToken = 'synthetic-token';
    final room =
        client.room = Room(id: '!real-context:synthetic', client: client);
    final owner = MatrixSdkE2eeClient(client,
        homeserver: client.homeserver!, readContinuityMetadata: _continuity);
    final lease = await owner.openRoomLease(room.id);
    final capability = await lease.openRoomTimeline(onUpdate: () {});
    final controller = RoomTimelineController(
        MatrixRoomTimelineAdapter(capability),
        windowed: true);
    expect(await controller.openAnchor(r'$remote-old'), isTrue);
    expect(controller.messages.single.id, r'$remote-old');
    expect(paths, hasLength(1));
    await controller.showLatest();
    expect(controller.messages, isEmpty);
    controller.dispose();
    await lease.cancel();
    await client.dispose();
  });

  test(
      'canceled direct context returns promptly and releases a late SDK timeline',
      () async {
    final client = _DateClient();
    final room = _DateRoom(client)..pendingContext = Completer<Timeline>();
    final (lease, capability) = await _openCapability(room);
    final eventContext = capability as RoomEventContextCapability;
    final locating = eventContext.locateEvent(r'$late');
    await Future<void>.delayed(Duration.zero);
    eventContext.cancelPendingEventLookup();
    expect(await locating.timeout(const Duration(milliseconds: 100)), isFalse);
    final late = _DateTimeline()
      ..events.add(_message(room, r'$late', DateTime(2025)));
    room.pendingContext!.complete(late);
    await Future<void>.delayed(Duration.zero);
    expect(late.subscriptionCancels, 1);
    expect(capability.isViewingHistoryContext, isFalse);
    await lease.cancel();
  });

  testWidgets(
      'context timeout releases late SDK subscription and leaves latest intact',
      (tester) async {
    final client = _DateClient();
    final room = _DateRoom(client)..pendingContext = Completer<Timeline>();
    final (lease, capability) = await _openCapability(room);
    final expected = expectLater(
        (capability as RoomEventContextCapability).locateEvent(r'$late'),
        throwsA(isA<TimeoutException>()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 13));
    await expected;
    final late = _DateTimeline()
      ..events.add(_message(room, r'$late', DateTime(2025)));
    room.pendingContext!.complete(late);
    await tester.pump();
    expect(late.subscriptionCancels, 1);
    expect(capability.isViewingHistoryContext, isFalse);
    await lease.cancel();
  });

  test('visibility is checked again after the context network wait', () async {
    final client = _DateClient();
    final room = _DateRoom(client)..pendingContext = Completer<Timeline>();
    final (lease, capability) = await _openCapability(room);
    final source = capability as RoomWindowedTimelineSource;
    source.enableWindow();
    var hidden = false;
    source.setHiddenFilter((_, __) => hidden);
    final locating =
        (capability as RoomEventContextCapability).locateEvent(r'$target');
    await Future<void>.delayed(Duration.zero);
    hidden = true;
    final late = _DateTimeline()
      ..events.add(_message(room, r'$target', DateTime(2025)));
    room.pendingContext!.complete(late);
    expect(await locating, isFalse);
    expect(late.subscriptionCancels, 1);
    expect(capability.isViewingHistoryContext, isFalse);
    await lease.cancel();
  });

  test(
      'absent contexts return false; denied and transient failures allow a later retry',
      () async {
    for (final code in [
      'M_NOT_FOUND',
      'M_FORBIDDEN',
      'M_UNAUTHORIZED',
      'M_UNKNOWN'
    ]) {
      final client = _DateClient();
      final room = _DateRoom(client)
        ..contextError = MatrixException(http.Response(
            '{"errcode":"$code","error":"synthetic"}',
            code == 'M_NOT_FOUND' ? 404 : 403));
      final (lease, capability) = await _openCapability(room);
      final events = capability as RoomEventContextCapability;
      if (code == 'M_NOT_FOUND') {
        expect(await events.locateEvent(r'$target'), isFalse);
      } else {
        await expectLater(
            events.locateEvent(r'$target'), throwsA(isA<MatrixException>()));
      }
      expect(capability.isViewingHistoryContext, isFalse);
      room.contextError = null;
      room.context = _DateTimeline()
        ..events.add(_message(room, r'$target', DateTime(2025)));
      expect(await events.locateEvent(r'$target'), isTrue);
      await lease.cancel();
    }
  });

  test(
      'revoked direct context cannot publish late events or retain subscriptions',
      () async {
    final client = _DateClient();
    final room = _DateRoom(client)..pendingContext = Completer<Timeline>();
    final (lease, capability) = await _openCapability(room);
    final locating =
        (capability as RoomEventContextCapability).locateEvent(r'$late');
    await Future<void>.delayed(Duration.zero);
    await lease.cancel();
    expect(await locating.timeout(const Duration(milliseconds: 100)), isFalse);
    final late = _DateTimeline()
      ..events.add(_message(room, r'$late', DateTime(2025)));
    room.pendingContext!.complete(late);
    await Future<void>.delayed(Duration.zero);
    expect(late.subscriptionCancels, 1);
  });

  test('context rejects wrong event, recall, encrypted and hidden targets',
      () async {
    for (final variant in ['wrong', 'recall', 'encrypted', 'hidden']) {
      final client = _DateClient();
      final room = _DateRoom(client);
      final event = _message(
          room, variant == 'wrong' ? r'$other' : r'$target', DateTime(2025));
      if (variant == 'recall') {
        event.unsigned = {
          'redacted_because': {
            'event_id': 'recall',
            'type': EventTypes.Redaction,
            'sender': '@synthetic:test',
            'origin_server_ts': 1,
            'content': <String, dynamic>{},
          }
        };
      }
      if (variant == 'encrypted') event.type = EventTypes.Encrypted;
      final context = room.context = _DateTimeline()..events.add(event);
      final (lease, capability) = await _openCapability(room);
      final source = capability as RoomWindowedTimelineSource;
      source.enableWindow();
      if (variant == 'hidden') {
        source.setHiddenFilter((id, _) => id == r'$target');
      }
      expect(
          await (capability as RoomEventContextCapability)
              .locateEvent(r'$target'),
          isFalse,
          reason: variant);
      expect(capability.isViewingHistoryContext, isFalse);
      expect(context.subscriptionCancels, 1);
      await lease.cancel();
    }
  });

  test('date cancellation does not wait for timestamp network completion',
      () async {
    final client = _DateClient()
      ..pendingTimestamp = Completer<GetEventByTimestampResponse>();
    final room = _DateRoom(client);
    final (lease, capability) = await _openCapability(room);
    final pending = capability.locateDay(DateTime(2026, 9, 15));
    await Future<void>.delayed(Duration.zero);
    capability.cancelPendingDateLookup();
    expect(await pending.timeout(const Duration(milliseconds: 100)), isNull);
    client.pendingTimestamp!.complete(GetEventByTimestampResponse(
        eventId: r'$late',
        originServerTs: DateTime(2026, 9, 15).millisecondsSinceEpoch));
    await Future<void>.delayed(Duration.zero);
    expect(room.contextEventIds, isEmpty);
    await lease.cancel();
  });
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
    // Cancellation now returns immediately; the late SDK completion releases
    // its own subscriptions in its continuation, not on the canceled UI future.
    await Future<void>.delayed(Duration.zero);
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
    await Future<void>.delayed(Duration.zero);
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
    test('month cancellation completes before an unresponsive server',
        () async {
      SharedPreferences.setMockInitialValues({});
      final client = _DateClient()
        ..pendingTimestamp = Completer<GetEventByTimestampResponse>();
      final room = _DateRoom(client);
      final (lease, capability) = await _openCapability(room);
      final pending = capability.loadMonthDays(const CalendarMonth(2026, 9));
      await Future<void>.delayed(Duration.zero);
      capability.cancelMonthLookup();
      final canceled = await pending.timeout(const Duration(milliseconds: 100));
      expect(canceled.hasUnknown, isTrue);
      client.pendingTimestamp!.complete(GetEventByTimestampResponse(
          eventId: r'$late',
          originServerTs: DateTime(2026, 10, 1).millisecondsSinceEpoch));
      await Future<void>.delayed(Duration.zero);
      expect(capability.anchorForDay(DateTime(2026, 9, 15)), isNull);
      await lease.cancel();
    });

    test('timestamp timeout stays unknown with an error and can retry',
        () async {
      SharedPreferences.setMockInitialValues({});
      final client = _DateClient()..timestampError = TimeoutException('probe');
      final room = _DateRoom(client);
      final (lease, capability) = await _openCapability(room);
      const month = CalendarMonth(2026, 9);
      final failed = await capability.loadMonthDays(month);
      expect(failed.error, isA<TimeoutException>());
      expect(failed.stateOf(15), RoomHistoryDayState.unknown);
      expect(failed.coverageComplete, isFalse);
      client.timestampError = null;
      client.timestampResult = GetEventByTimestampResponse(
          eventId: r'$retry',
          originServerTs: DateTime(2026, 9, 15).millisecondsSinceEpoch);
      final retried = await capability.loadMonthDays(month);
      expect(retried.stateOf(15), RoomHistoryDayState.knownPresent);
      await lease.cancel();
    });

    test('only explicit Matrix M_NOT_FOUND establishes no timestamp event',
        () async {
      SharedPreferences.setMockInitialValues({});
      final client = _DateClient()
        ..timestampError = MatrixException(
            http.Response('{"errcode":"M_NOT_FOUND","error":"No event"}', 404));
      final room = _DateRoom(client);
      final (lease, capability) = await _openCapability(room);
      final result =
          await capability.loadMonthDays(const CalendarMonth(2026, 9));
      expect(result.error, isNull);
      expect(result.stateOf(15), RoomHistoryDayState.knownEmpty);
      await lease.cancel();
    });

    test('a denied timestamp request never establishes an empty month',
        () async {
      SharedPreferences.setMockInitialValues({});
      final error = MatrixException(
          http.Response('{"errcode":"M_FORBIDDEN","error":"denied"}', 403));
      final client = _DateClient()..timestampError = error;
      final room = _DateRoom(client);
      final (lease, capability) = await _openCapability(room);
      final result =
          await capability.loadMonthDays(const CalendarMonth(2026, 9));
      expect(result.error, same(error));
      expect(result.stateOf(15), RoomHistoryDayState.unknown);
      await lease.cancel();
    });
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

    test('月内首个事件成为 anchor，earliestMonth 与 anchorForDay 不再访问服务端', () async {
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
      expect(
          capability.anchorForDay(DateTime(2026, 9, 12)), r'$first-of-month');
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
      expect(days.hasUnknown, isTrue, reason: '取消 ≠ 确认空；未覆盖的月份必须保持 unknown');
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
