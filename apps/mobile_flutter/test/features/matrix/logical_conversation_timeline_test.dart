import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/logical_conversation_timeline.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/room_history_date_capability.dart';

RoomMessageViewModel message(String id, int second, {String? transaction}) =>
    RoomMessageViewModel(
        id: id,
        senderId: 'user',
        text: 'same text',
        isOwn: true,
        deliveryState: RoomDeliveryState.sent,
        timestamp: DateTime(2026, 9, 19, 0, 0, second),
        transactionId: transaction);

class Source extends Fake
    implements
        RoomTimelineCapability,
        RoomHistoryStatus,
        RoomMessageLookupSource {
  Source(this.messages);
  final List<RoomMessageViewModel> messages;
  final List<String> sends = [], retries = [], attachments = [];
  int reads = 0, disposed = 0, pages = 0;
  Object? historyError;
  Object? disposeError;
  Object? lookupError;
  RoomMessageViewModel? remoteMessage;
  Completer<void>? lookupGate;
  final List<String> lookups = [];
  @override
  bool canLoadHistory = true;
  @override
  bool get supportsMessageLookup => true;
  int snapshots = 0;
  @override
  List<RoomMessageViewModel> snapshot() {
    snapshots++;
    return messages;
  }

  @override
  Future<String> sendText(String text) async {
    sends.add(text);
    return 'sent';
  }

  @override
  Future<String> sendTextWithTransaction(String text, String transactionId) =>
      sendText(text);
  @override
  Future<String> sendTransferReference(
          String transferId, String amount, String? note,
          {String? receiverId, String? receiverMatrixId}) =>
      sendText('transfer:$transferId');
  @override
  Future<String> sendRedPacketReference(String packetId, String greeting,
          {String? mode, String? recipientId, String? recipientMatrixId}) =>
      sendText('packet:$packetId');
  @override
  Future<void> retry(String transactionId) async {
    retries.add(transactionId);
  }

  @override
  Future<Uint8List> loadAttachment(String eventId) async {
    attachments.add(eventId);
    return Uint8List.fromList([1]);
  }

  @override
  Future<Uint8List?> loadThumbnail(String eventId) => loadAttachment(eventId);
  @override
  Future<void> markRead() async {
    reads++;
  }

  @override
  Future<void> loadHistory() async {
    pages++;
    if (historyError != null) throw historyError!;
  }

  @override
  Future<RoomMessageViewModel?> lookupMessage(String id) async {
    lookups.add(id);
    await lookupGate?.future;
    if (lookupError != null) throw lookupError!;
    return messages.where((m) => m.id == id).firstOrNull ?? remoteMessage;
  }

  @override
  void dispose() {
    disposed++;
    if (disposeError != null) throw disposeError!;
  }
}

class VisibleSource extends Source implements RoomVisibleReadCapability {
  VisibleSource(super.messages);
  final List<String> viewed = [];
  @override
  Future<void> markReadVisible(Iterable<String> eventIds) async {
    viewed.addAll(eventIds);
  }
}

class DateSource extends Source implements RoomHistoryDateCapability {
  DateSource(super.messages, this.monthDays);
  RoomHistoryMonthDays monthDays;
  int cancellations = 0;
  @override
  Iterable<RoomHistoryDayMetadata> get loadedDayMetadata =>
      messages.map((m) => RoomHistoryDayMetadata(m.timestamp));
  @override
  bool get isViewingHistoryContext => false;
  @override
  CalendarMonth? get earliestMonth => const CalendarMonth(2026, 9);
  @override
  Future<RoomHistoryMonthDays> loadMonthDays(CalendarMonth month) async =>
      monthDays;
  @override
  Future<RoomHistoryDayLocation?> locateDay(DateTime localDay) async =>
      messages.isEmpty
          ? null
          : RoomHistoryDayLocation(eventId: messages.first.id, day: localDay);
  @override
  String? anchorForDay(DateTime day) => messages.firstOrNull?.id;
  @override
  void cancelPendingDateLookup() {
    cancellations++;
  }

  @override
  void cancelMonthLookup() {}
  @override
  void selectLatest() {}
}

class DeferredDateSource extends DateSource {
  DeferredDateSource()
      : super([], RoomHistoryMonthDays(month: const CalendarMonth(2026, 9)));
  final day = Completer<RoomHistoryDayLocation?>();
  final month = Completer<RoomHistoryMonthDays>();
  int dayCalls = 0, monthCancels = 0;
  @override
  Future<RoomHistoryDayLocation?> locateDay(DateTime value) {
    dayCalls++;
    return day.future;
  }

  @override
  Future<RoomHistoryMonthDays> loadMonthDays(CalendarMonth value) =>
      month.future;
  @override
  void cancelMonthLookup() {
    monthCancels++;
  }
}

void main() {
  late Source primary, old;
  late LogicalConversationTimelineCapability timeline;
  setUp(() {
    primary = Source([message('new', 3, transaction: 'primary-tx')]);
    old = Source(
        [message('old', 1, transaction: 'old-tx'), message('middle', 2)]);
    timeline = LogicalConversationTimelineCapability(
        primaryRoomId: 'primary', primary: primary, sources: {'old': old});
  });
  testWidgets('logical date budget expires and cancels all sources',
      (tester) async {
    final first = DeferredDateSource(), second = DeferredDateSource();
    final logical = LogicalConversationTimelineCapability(
        primaryRoomId: 'primary', primary: first, sources: {'old': second});
    Object? error;
    logical.locateDay(DateTime(2026, 9, 1)).then<void>((_) {},
        onError: (Object e) {
      error = e;
    });
    await tester.pump(const Duration(seconds: 13));
    expect(error, isA<RoomHistoryLookupIncomplete>());
    expect(first.cancellations, greaterThan(0));
    expect(second.cancellations, greaterThan(0));
    first.day.complete(
        RoomHistoryDayLocation(eventId: 'late', day: DateTime(2026, 9, 1)));
    await tester.pump();
    expect(second.dayCalls, 0);
    expect(logical.sourceRoomId('late'), isNull);
    logical.dispose();
  });
  testWidgets(
      'logical month budget fails rather than publishing empty coverage',
      (tester) async {
    final first = DeferredDateSource();
    final logical = LogicalConversationTimelineCapability(
        primaryRoomId: 'primary', primary: first, sources: {});
    Object? error;
    logical.loadMonthDays(const CalendarMonth(2026, 9)).then<void>((_) {},
        onError: (Object e) {
      error = e;
    });
    await tester.pump(const Duration(seconds: 13));
    expect(error, isA<RoomHistoryLookupIncomplete>());
    expect(first.monthCancels, greaterThan(0));
    first.month.complete(RoomHistoryMonthDays(
        month: const CalendarMonth(2026, 9), anchors: {1: 'late'}));
    await tester.pump();
    expect(logical.sourceRoomId('late'), isNull);
    logical.dispose();
  });
  testWidgets('logical cancellation settles without waiting for network',
      (tester) async {
    final first = DeferredDateSource();
    final logical = LogicalConversationTimelineCapability(
        primaryRoomId: 'primary', primary: first, sources: {});
    Object? error;
    logical.locateDay(DateTime(2026, 9, 1)).then<void>((_) {},
        onError: (Object e) {
      error = e;
    });
    logical.cancelPendingDateLookup();
    await tester.pump();
    expect(error, isA<RoomHistoryLookupCancelled>());
    logical.dispose();
  });
  test('indexed source lookups do not rebuild all loaded messages', () {
    primary.messages.addAll(List.generate(1000, (i) => message('many-$i', i)));
    final snapshot = timeline.snapshot();
    final calls = primary.snapshots + old.snapshots;
    for (final row in snapshot) {
      expect(timeline.sourceRoomId(row.id), isNotNull);
    }
    expect(primary.snapshots + old.snapshots, calls);
  });
  test('cold and added sources are indexed once; missing IDs do not rescan',
      () {
    expect(timeline.sourceRoomId('old'), 'old');
    final calls = primary.snapshots + old.snapshots;
    expect(timeline.sourceRoomId('missing'), isNull);
    expect(timeline.sourceRoomId('another-missing'), isNull);
    expect(primary.snapshots + old.snapshots, calls);
    final added = Source([message('added', 4)]);
    timeline.addSource('added-room', added);
    expect(timeline.sourceRoomId('added'), 'added-room');
    final after = primary.snapshots + old.snapshots + added.snapshots;
    expect(timeline.sourceRoomId('added'), 'added-room');
    expect(primary.snapshots + old.snapshots + added.snapshots, after);
  });
  test('unchanged merged snapshots reuse models, replacements remain visible',
      () {
    final before = timeline.snapshot();
    expect(identical(timeline.snapshot(), before), isTrue);
    old.messages[0] = message('old', 5);
    final after = timeline.snapshot();
    expect(after.last.id, 'old');
    expect(identical(after, before), isFalse);
    expect(timeline.sourceRoomId('old'), 'old');
  });
  test('adds newly discovered source without leaking replacement ownership',
      () {
    final additional = Source([message('extra', 4)]);
    timeline.addSource('extra-room', additional);
    expect(timeline.snapshot().map((event) => event.id),
        ['old', 'middle', 'new', 'extra']);
    expect(() => timeline.addSource('old', additional), throwsStateError);
    timeline.dispose();
    expect(additional.disposed, 1);
    expect(() => timeline.addSource('later', Source([])), throwsStateError);
  });
  test('cold source hint avoids querying the wrong room', () async {
    old.remoteMessage = message('cold', 0);
    timeline.hintSource('cold', 'old');
    expect((await timeline.lookupMessage('cold'))?.id, 'cold');
    expect(old.lookups, ['cold']);
    expect(primary.lookups, isEmpty);
  });
  test('source discovery during an awaited lookup does not corrupt iteration',
      () async {
    primary.lookupGate = Completer<void>();
    old.remoteMessage = message('cold', 0);
    final lookup = timeline.lookupMessage('cold');
    timeline.addSource('later', Source([]));
    primary.lookupGate!.complete();
    expect((await lookup)?.id, 'cold');
  });
  test('disposed lookup does not start another source network request',
      () async {
    primary.lookupGate = Completer<void>();
    final lookup = timeline.lookupMessage('cold');
    timeline.dispose();
    primary.lookupGate!.complete();
    await expectLater(lookup, throwsStateError);
    expect(old.lookups, isEmpty);
  });
  test(
      'financial references stay on primary; historical exact receipts retain event bounds',
      () async {
    final retained =
        VisibleSource([message('visible', 1), message('unseen', 2)]);
    timeline.addSource('retained', retained);
    await timeline.sendTransferReference('transfer', '1.00', null);
    await timeline.sendRedPacketReference('packet', 'hello');
    expect(primary.sends, ['transfer:transfer', 'packet:packet']);
    expect(old.sends, isEmpty);
    await timeline.markReadVisible(['visible']);
    expect(retained.viewed, ['visible']);
    expect(retained.reads, 0);
    expect(primary.reads, 0);
  });
  test('lookup failure remains retryable instead of falsely returning absent',
      () async {
    old.lookupError = const ReplyMessageLookupUnavailable('offline');
    await expectLater(timeline.lookupMessage('cold'),
        throwsA(isA<ReplyMessageLookupUnavailable>()));
  });
  test('disposal releases all sources and callback even when one throws', () {
    primary.disposeError = StateError('dispose failure');
    var released = false;
    final merged = LogicalConversationTimelineCapability(
        primaryRoomId: 'primary',
        primary: primary,
        sources: {'old': old},
        onDispose: () {
          released = true;
        });
    expect(merged.dispose, throwsStateError);
    expect(old.disposed, 1);
    expect(released, isTrue);
  });
  test('merges chronologically by event identity and preserves identical text',
      () {
    old.messages.add(message('new', 3));
    expect(timeline.snapshot().map((m) => m.id), ['old', 'middle', 'new']);
    expect(timeline.sourceRoomId('new'), 'primary');
    expect(timeline.sourceRoomId('old'), 'old');
  });
  test('writes only primary and refuses retained-room or unknown retry',
      () async {
    await timeline.sendText('hello');
    await timeline.sendTextWithTransaction('again', 'tx');
    await timeline.retry('primary-tx');
    await expectLater(timeline.retry('old-tx'), throwsStateError);
    await expectLater(timeline.retry('unknown'), throwsStateError);
    expect(primary.sends, ['hello', 'again']);
    expect(primary.retries, ['primary-tx']);
    expect(old.sends, isEmpty);
  });
  test('attachments and lookup use the original source', () async {
    await timeline.loadAttachment('old');
    await timeline.loadThumbnail('middle');
    expect((await timeline.lookupMessage('old'))?.id, 'old');
    expect(old.attachments, ['old', 'middle']);
    expect(primary.attachments, isEmpty);
  });
  test('opening and seeing only an earlier event do not clear unseen history',
      () async {
    await timeline.markRead();
    await timeline.markReadVisible(['old']);
    expect(old.reads, 0);
    expect(primary.reads, 0);
    await timeline.markReadVisible(['middle']);
    expect(old.reads, 1);
    expect(primary.reads, 0);
  });
  test('pagination preserves failure and disposal releases every source once',
      () async {
    old.historyError = StateError('offline');
    await expectLater(timeline.loadHistory(), throwsStateError);
    timeline.dispose();
    timeline.dispose();
    expect(primary.disposed, 1);
    expect(old.disposed, 1);
  });
  test('calendar union never labels an incompletely covered source as empty',
      () async {
    const month = CalendarMonth(2026, 9);
    final current = DateSource(
        [],
        const RoomHistoryMonthDays(
            month: month,
            dayStates: {
              1: RoomHistoryDayState.knownEmpty,
              2: RoomHistoryDayState.knownPresent
            },
            coverageComplete: true));
    final retained = DateSource(
        [message('retained', 1)],
        const RoomHistoryMonthDays(month: month, dayStates: {
          1: RoomHistoryDayState.unknown,
          2: RoomHistoryDayState.knownEmpty
        }));
    final merged = LogicalConversationTimelineCapability(
        primaryRoomId: 'primary', primary: current, sources: {'old': retained});
    final date = merged as RoomHistoryDateCapability;
    final result = await date.loadMonthDays(month);
    expect(result.dayStates[1], RoomHistoryDayState.unknown);
    expect(result.dayStates[2], RoomHistoryDayState.knownPresent);
    expect(result.coverageComplete, false);
    expect((await date.locateDay(DateTime(2026, 9, 19)))?.eventId, 'retained');
    expect(merged.sourceRoomId('retained'), 'old');
    date.cancelPendingDateLookup();
    expect(retained.cancellations, 1);
  });
}
