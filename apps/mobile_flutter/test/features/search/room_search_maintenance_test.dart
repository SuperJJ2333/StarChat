import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/maintenance_activity.dart';
import 'package:liuhetong_mobile/features/matrix/room_paged_history_source.dart';
import 'package:liuhetong_mobile/features/search/room_search_index_pump.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';

class BodySource implements RoomPagedHistorySource {
  int reads = 0;
  final finishFirst = Completer<void>();
  @override
  bool get supportsPagedHistory => true;
  @override
  Future<RoomHistoryMessagePage> readHistoryPage(
      {RoomHistoryReadCursor? cursor,
      String? anchorEventId,
      String? sourceRoomId,
      required RoomHistoryDirection direction,
      int rawLimit = 64,
      Future<void> Function()? beforeRead}) async {
    for (var i = 0; i < rawLimit; i++) {
      await beforeRead?.call();
      reads++;
      if (reads == 1) await finishFirst.future;
    }
    return RoomHistoryMessagePage(
        messages: const [],
        exhausted: true,
        fragmentGeneration: 1,
        rawCount: rawLimit);
  }
}

class CheckedCursor implements RoomHistoryReadCursor {
  int accepted = 0;
  bool disposed = false;
  @override
  void dispose() {
    disposed = true;
  }
}

class CheckedSource implements RoomPagedHistorySource {
  final cursors = <CheckedCursor>[];
  final first = Completer<void>();
  int attempts = 0;
  @override
  bool get supportsPagedHistory => true;
  @override
  Future<RoomHistoryMessagePage> readHistoryPage(
      {RoomHistoryReadCursor? cursor,
      String? anchorEventId,
      String? sourceRoomId,
      required RoomHistoryDirection direction,
      int rawLimit = 64,
      Future<void> Function()? beforeRead}) async {
    final current = cursor as CheckedCursor? ?? CheckedCursor();
    if (cursor == null) cursors.add(current);
    attempts++;
    try {
      await beforeRead?.call();
      if (attempts == 1) await first.future;
      await beforeRead?.call();
      current.accepted += 2;
      current.dispose();
      return RoomHistoryMessagePage(messages: [
        for (var i = 0; i < 2; i++)
          RoomMessageViewModel(
              id: 'saved-$i',
              senderId: 's',
              text: 'fixture',
              isOwn: false,
              timestamp: DateTime.utc(2026),
              deliveryState: RoomDeliveryState.sent)
      ], exhausted: true, fragmentGeneration: 1, rawCount: 2);
    } catch (_) {
      if (cursor == null) current.dispose();
      rethrow;
    }
  }
}

void main() {
  for (final reason in ['keyboard', 'typing', 'scroll', 'call']) {
    testWidgets('index pages wait for $reason and resume after quiet',
        (tester) async {
      final activity = MaintenanceActivity.instance..resetForTesting();
      final source = BodySource();
      final pump = RoomSearchIndexPump(
          source: () => const [],
          pagedSource: source,
          isActive: () => true,
          upsert: (_) {},
          remove: (_) {});
      addTearDown(pump.dispose);
      activity.setInteractive(reason, true);
      pump.request([]);
      await tester.pump(const Duration(milliseconds: 50));
      expect(source.reads, 0);
      activity.setInteractive(reason, false);
      await tester.pump(const Duration(milliseconds: 499));
      expect(source.reads, 0);
      await tester.pump(const Duration(milliseconds: 2));
      expect(source.reads, 1);
      source.finishFirst.complete();
      await tester.pump();
      pump.dispose();
      await tester.pump();
      expect(activity.heavyBusy, false);
      expect(activity.pendingWaiters, 0);
    });
  }
  for (final interruption in ['keyboard', 'pressure', 'dispose']) {
    testWidgets('active index page stops body reads on $interruption',
        (tester) async {
      final activity = MaintenanceActivity.instance..resetForTesting();
      final source = BodySource();
      final pump = RoomSearchIndexPump(
          source: () => const [],
          pagedSource: source,
          isActive: () => true,
          upsert: (_) {},
          remove: (_) {});
      addTearDown(pump.dispose);
      pump.request([]);
      await tester.pump(const Duration(milliseconds: 1));
      expect(source.reads, 1);
      if (interruption == 'pressure') {
        activity.pressure();
      } else if (interruption == 'dispose') {
        pump.dispose();
      } else {
        activity.setInteractive(interruption, true);
      }
      source.finishFirst.complete();
      await tester.pump();
      expect(source.reads, 1,
          reason: 'only an already-started body read may finish');
      expect(activity.heavyBusy, false);
      pump.dispose();
      await tester.pump();
      expect(activity.pendingWaiters, 0);
    });
  }
  for (final interruption in ['pressure', 'generation']) {
    testWidgets(
        'cancelled $interruption page does not accept cursor and rebuilds exactly',
        (tester) async {
      final activity = MaintenanceActivity.instance..resetForTesting();
      final source = CheckedSource();
      final saved = <String, int>{};
      final pump = RoomSearchIndexPump(
          source: () => const [],
          pagedSource: source,
          isActive: () => true,
          maxPendingIds: 1,
          upsert: (rows) {
            for (final r in rows) {
              saved.update(r.id, (n) => n + 1, ifAbsent: () => 1);
            }
          },
          remove: (_) {});
      addTearDown(pump.dispose);
      pump.request([]);
      await tester.pump(const Duration(milliseconds: 1));
      expect(source.attempts, 1);
      if (interruption == 'pressure') {
        activity.pressure();
      } else {
        pump.request([
          for (var i = 0; i < 2; i++)
            RoomMessageViewModel(
                id: 'live-$i',
                senderId: 's',
                text: 'fixture',
                isOwn: false,
                timestamp: DateTime.utc(2026),
                deliveryState: RoomDeliveryState.sent)
        ]);
      }
      source.first.complete();
      await tester.pump();
      expect(source.cursors.first.accepted, 0);
      expect(source.cursors.first.disposed, true);
      expect(activity.heavyBusy, false);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(saved['saved-0'], 1);
      expect(saved['saved-1'], 1);
      expect(source.cursors.last.accepted, 2);
      pump.dispose();
      await tester.pump();
      expect(activity.pendingWaiters, 0);
    });
  }
}
