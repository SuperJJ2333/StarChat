import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/voice_playback_controller.dart';
import 'package:liuhetong_mobile/features/matrix/room_paged_history_source.dart';
import 'package:liuhetong_mobile/features/matrix/logical_conversation_timeline.dart';
import 'package:liuhetong_mobile/features/search/room_search_index_pump.dart';
import 'package:liuhetong_mobile/features/matrix/local_search_id_snapshot.dart';
import 'package:liuhetong_mobile/features/matrix/local_room_history_search.dart';
import 'package:liuhetong_mobile/features/matrix/local_room_history_snapshot.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/features/matrix/room_history_day_index.dart';

import 'voice_playback_controller_test.dart' show FakeVoiceAudioEngine;
import 'logical_conversation_timeline_test.dart' show Source;

class _Cursor implements RoomHistoryReadCursor {
  _Cursor(this.index, this.rows);
  int index;
  final List<RoomMessageViewModel> rows;
  bool disposed = false;
  @override
  void dispose() {
    disposed = true;
  }
}

class _PagedSource extends Source implements RoomPagedHistorySource {
  _PagedSource(this.saved, {this.filteredCount = 0})
      : super(saved.take(2).toList());
  final List<RoomMessageViewModel> saved;
  final int filteredCount;
  int pagedReads = 0;
  Completer<void>? gate;
  _Cursor? lastCursor;
  @override
  bool get supportsPagedHistory => true;
  @override
  Future<RoomHistoryMessagePage> readHistoryPage({
    RoomHistoryReadCursor? cursor,
    String? anchorEventId,
    String? sourceRoomId,
    required RoomHistoryDirection direction,
    int rawLimit = 64,
  }) async {
    final anchorIndex = anchorEventId == null
        ? null
        : saved.indexWhere((r) => r.id == anchorEventId);
    final ordered = direction == RoomHistoryDirection.newer
        ? saved.take(anchorIndex ?? saved.length).toList().reversed.toList()
        : saved;
    final current = cursor as _Cursor? ??
        _Cursor(
            direction == RoomHistoryDirection.newer || anchorEventId == null
                ? 0
                : anchorIndex! + 1,
            ordered);
    lastCursor = current;
    final start = current.index;
    final end = (start + rawLimit).clamp(0, current.rows.length);
    pagedReads += end - start;
    await gate?.future;
    current.index = end;
    return RoomHistoryMessagePage(
        messages: current.rows
            .sublist(start, end)
            .where((r) => saved.indexOf(r) >= filteredCount),
        rawCount: end - start,
        exhausted: end == current.rows.length,
        nextCursor: end == current.rows.length ? null : current,
        fragmentGeneration: 1);
  }
}

RoomMessageViewModel _text(String id, int time) => RoomMessageViewModel(
    id: id,
    senderId: '@synthetic:test',
    text: 'synthetic $id',
    isOwn: false,
    timestamp: DateTime.fromMillisecondsSinceEpoch(time),
    deliveryState: RoomDeliveryState.sent);

RoomMessageViewModel _voice(String id, {int time = 100}) =>
    RoomMessageViewModel(
      id: id,
      senderId: '@synthetic:test',
      text: '',
      isOwn: false,
      deliveryState: RoomDeliveryState.sent,
      timestamp: DateTime.fromMillisecondsSinceEpoch(time),
      kind: RoomMessageKind.voice,
    );

void main() {
  test('paged voice excludes canonically older rows with future timestamps',
      () async {
    final completed = _voice('completed', time: 100);
    final source = _PagedSource([
      _voice('canonical-newer', time: 300),
      completed,
      _voice('older-with-skewed-clock', time: 200),
    ]);
    final next = await nextUnreadVoiceFromHistory(
        source: source,
        completed: completed,
        isActive: () => true,
        isPlayed: (_) => false);
    expect(next?.id, 'canonical-newer');
    expect(source.pagedReads, 1);
    expect(source.pages, 0);
  });

  test('paged voice stops after cancellation during a bounded read', () async {
    final completed = _voice('completed');
    final source = _PagedSource([_voice('later', time: 200), completed])
      ..gate = Completer<void>();
    var active = true;
    final pending = nextUnreadVoiceFromHistory(
        source: source,
        completed: completed,
        isActive: () => active,
        isPlayed: (_) => false);
    active = false;
    source.gate!.complete();
    expect(await pending, isNull);
    expect(source.pagedReads, 1);
  });

  final searchRow = ChatSearchMessage(
      eventId: 'after-retired-rows',
      senderId: 'synthetic',
      senderDisplayName: 'synthetic',
      timestamp: DateTime.utc(2026, 9, 2),
      timelineOrder: 1,
      visibleText: 'needle');
  Future<List<ChatSearchMessage>> sparsePage(
          String room, int offset, int limit) async =>
      offset == 0
          ? LocalHistoryPage([], nextOffset: 256, hasMore: true, rawCount: 256)
          : LocalHistoryPage([searchRow],
              nextOffset: 257, hasMore: false, rawCount: 1);

  test('global search continues after a retired-only raw page', () async {
    final search = LocalRoomHistorySearch(
        roomIds: () => ['room'],
        readPage: sparsePage,
        project: (_, row) => row);
    try {
      final result =
          await search.search(const ChatSearchFilters(keyword: 'needle'));
      expect(result.items.map((r) => r.eventId), ['after-retired-rows']);
    } finally {
      search.cancel();
    }
  });

  test('calendar cannot declare a day empty at a retired-only raw page',
      () async {
    final snapshot =
        LocalRoomHistorySnapshot(roomIds: () => ['room'], readPage: sparsePage);
    final month = await snapshot.monthDays(const CalendarMonth(2026, 9));
    expect(month.stateOf(2), RoomHistoryDayState.knownPresent);
    expect(month.anchors[2], 'after-retired-rows');
    snapshot.clear();
  });

  testWidgets(
      'search reaches saved history outside resident slice through empty pages',
      (tester) async {
    final source = _PagedSource(
        List.generate(1400, (i) => _text('saved-$i', 1400 - i)),
        filteredCount: 64);
    final saved = <String>{};
    final pump = RoomSearchIndexPump(
        source: () => source.messages,
        pagedSource: source,
        isActive: () => true,
        upsert: (rows) => saved.addAll(rows.map((r) => r.id)),
        remove: (_) {});
    try {
      pump.request([]);
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 5));
      }
      expect(saved, contains('saved-1399'));
      expect(saved, isNot(contains('saved-0')));
      expect(source.pagedReads, 1400);
      expect(source.pages, 0,
          reason: 'Index catch-up never changes the visible timeline.');
      expect(source.messages.map((r) => r.id), ['saved-0', 'saved-1']);
    } finally {
      pump.dispose();
    }
  });

  testWidgets('late search page after account disposal cannot publish',
      (tester) async {
    final source = _PagedSource([_text('late', 1)])..gate = Completer<void>();
    final saved = <String>{};
    var active = true;
    final pump = RoomSearchIndexPump(
        source: () => source.messages,
        pagedSource: source,
        isActive: () => active,
        upsert: (rows) => saved.addAll(rows.map((r) => r.id)),
        remove: (_) {});
    pump.request([]);
    await tester.pump(const Duration(milliseconds: 5));
    active = false;
    pump.dispose();
    source.gate!.complete();
    await tester.pump(const Duration(milliseconds: 5));
    expect(saved, isEmpty);
  });

  test('logical paging merges source frontiers without moving visible windows',
      () async {
    final primary =
        _PagedSource([_text('a9', 9), _text('a5', 5), _text('a1', 1)]);
    final older =
        _PagedSource([_text('b8', 8), _text('b4', 4), _text('b0', 0)]);
    final logical = LogicalConversationTimelineCapability(
        primaryRoomId: 'a', primary: primary, sources: {'b': older});
    RoomHistoryReadCursor? cursor;
    final ids = <String>[];
    final owners = <String, String>{};
    try {
      for (var i = 0; i < 10; i++) {
        final page = await logical.readHistoryPage(
            cursor: cursor, direction: RoomHistoryDirection.older, rawLimit: 2);
        cursor = page.nextCursor;
        expect(page.rawCount, lessThanOrEqualTo(2));
        ids.addAll(page.messages.map((r) => r.id));
        owners.addAll(page.sourceRoomIds);
        if (page.exhausted) break;
      }
      expect(ids, ['a9', 'b8', 'a5', 'b4', 'a1', 'b0']);
      expect(owners['a1'], 'a');
      expect(owners['b0'], 'b');
      expect(logical.sourceRoomId('b0'), 'b');
      expect(primary.pages + older.pages, 0);
    } finally {
      cursor?.dispose();
      logical.dispose();
    }
  });

  for (final action in ['stop', 'new play', 'dispose', 'call', 'disabled']) {
    test('late async voice successor cannot override $action', () async {
      final engine = FakeVoiceAudioEngine();
      final page = Completer<RoomMessageViewModel?>();
      final downloads = <String>[];
      var allowed = true;
      var enabled = true;
      final controller = VoicePlaybackController(
        engine: engine,
        canPlay: () => allowed,
        autoPlayNextVoiceEnabled: () => enabled,
        loadAttachment: (id) async {
          downloads.add(id);
          return Uint8List.fromList([1]);
        },
        nextAutoPlayVoice: (_) => page.future,
      );
      var disposed = false;
      try {
        await controller.toggle(_voice('completed'));
        engine.finishNaturally();
        await Future<void>.delayed(Duration.zero);
        switch (action) {
          case 'stop':
            await controller.stopAll();
          case 'new play':
            await controller.toggle(_voice('manual'));
          case 'dispose':
            controller.dispose();
            disposed = true;
          case 'call':
            allowed = false;
          case 'disabled':
            enabled = false;
        }
        page.complete(_voice('successor'));
        await Future<void>.delayed(Duration.zero);
        expect(downloads,
            action == 'new play' ? ['completed', 'manual'] : ['completed']);
      } finally {
        if (!disposed) controller.dispose();
        await engine.completedController.close();
        await engine.positionController.close();
      }
    });
  }

  test('async successor resumes autoplay after a bounded history read',
      () async {
    final engine = FakeVoiceAudioEngine();
    final page = Completer<RoomMessageViewModel?>();
    final controller = VoicePlaybackController(
      engine: engine,
      loadAttachment: (_) async => Uint8List.fromList([1]),
      nextAutoPlayVoice: (_) => page.future,
    );
    try {
      await controller.toggle(_voice('completed'));
      engine.finishNaturally();
      await Future<void>.delayed(Duration.zero);
      expect(controller.playingIds, isEmpty);
      page.complete(_voice('successor'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.isPlaying('successor'), isTrue);
    } finally {
      controller.dispose();
      await engine.completedController.close();
      await engine.positionController.close();
    }
  });

  test('manual stop during successor lookup invalidates autoplay result',
      () async {
    final engine = FakeVoiceAudioEngine();
    final downloads = <String>[];
    late VoicePlaybackController controller;
    controller = VoicePlaybackController(
      engine: engine,
      loadAttachment: (id) async {
        downloads.add(id);
        return Uint8List.fromList([1]);
      },
      nextAutoPlayVoice: (_) {
        unawaited(controller.stopAll());
        return _voice('successor');
      },
    );
    try {
      await controller.toggle(_voice('completed'));
      engine.finishNaturally();
      await Future<void>.delayed(Duration.zero);
      expect(downloads, ['completed'],
          reason: 'The manual stop supersedes the in-flight successor lookup.');
      expect(controller.playingIds, isEmpty);
    } finally {
      controller.dispose();
      await engine.completedController.close();
      await engine.positionController.close();
    }
  });
}
