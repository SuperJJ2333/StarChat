import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/features/matrix/unread_mention_tracker.dart';

ChatSearchMessage message(String id, String body) => ChatSearchMessage(
  eventId: id, senderId: '@a:x', senderDisplayName: 'A',
  timestamp: DateTime(2026, 9, 6), timelineOrder: 1, visibleText: body,
);

void main() {
  test('viewed mention must not reappear after repeated sync or restore', () {
    final tracker = UnreadMentionTracker(accountId: '@me:x', roomId: '!r:x')
      ..initializeBoundary(lastReadOrder: 0);
    tracker.onMessageArrived(eventId: 'A', order: 1, senderIsSelf: false,
      mentionedUserIds: {'@me:x'});
    tracker.markViewed('A');
    final restored = UnreadMentionTracker.decode(tracker.encode())!;
    restored.onMessageArrived(eventId: 'A', order: 1, senderIsSelf: false,
      mentionedUserIds: {'@me:x'});
    expect(restored.hasPending, isFalse);
  });

  test('clearing all search conditions invalidates the in-flight result', () async {
    final pending = Completer<List<ChatSearchMessage>>();
    final controller = ChatSearchQueryController(
      search: (filters, {cursor, limit = 50}) => pending.future);
    final states = <ChatSearchStateChange>[];
    controller.setKeyword('old');
    final old = controller.executeNow(onStateChange: states.add);
    controller.clearAll();
    await controller.executeNow(onStateChange: states.add);
    pending.complete([message('old', 'old')]);
    final result = await old;
    expect(result.stale, isTrue);
    expect(states.last, isA<ChatSearchEmptyState>());
  });

  test('changing keyword invalidates old result during debounce window', () async {
    final pending = Completer<List<ChatSearchMessage>>();
    final controller = ChatSearchQueryController(
      search: (filters, {cursor, limit = 50}) => pending.future);
    controller.setKeyword('old');
    final old = controller.executeNow();
    controller.setKeyword('new');
    controller.scheduleDebounced();
    pending.complete([message('old', 'old')]);
    final result = await old;
    controller.cancelDebounce();
    expect(result.stale, isTrue);
  });

  test('old pagination completing after a new query must be stale', () async {
    final pendingMore = Completer<List<ChatSearchMessage>>();
    final controller = ChatSearchQueryController(
      search: (filters, {cursor, limit = 50}) async {
        if (cursor != null) return pendingMore.future;
        return [message(filters.keyword!, filters.keyword!)];
      });
    controller.setKeyword('old');
    final oldFirst = await controller.executeNow();
    final oldMore = controller.loadMore(oldFirst);
    controller.setKeyword('new');
    await controller.executeNow();
    pendingMore.complete([message('old2', 'old')]);
    expect((await oldMore).stale, isTrue);
  });

  test('superseded debounce future must settle instead of hanging', () async {
    final controller = ChatSearchQueryController(
      debounce: const Duration(milliseconds: 1),
      search: (filters, {cursor, limit = 50}) async => []);
    controller.setKeyword('one');
    var settled = false;
    controller.scheduleDebounced().then((_) { settled = true; });
    controller.setKeyword('two');
    await controller.scheduleDebounced();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(settled, isTrue);
  });
}
