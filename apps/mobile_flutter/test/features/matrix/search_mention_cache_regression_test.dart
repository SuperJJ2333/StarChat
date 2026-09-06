import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/features/matrix/unread_mention_tracker.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_session_cache.dart';

/// GLM 审查 R9/R10/R11 回归：未读@复活/搜索竞态/缓存清理。
void main() {
  group('R9：已查看 @ 重复同步后不复活', () {
    test('查看 A → 序列化恢复 → 重复同步 A → 仍已查看', () {
      final tracker = UnreadMentionTracker(accountId: '@me:x', roomId: '!r:x');
      tracker.initializeBoundary(lastReadOrder: 0);
      tracker.onMessageArrived(
          eventId: 'A', order: 1, senderIsSelf: false, mentionedUserIds: {'@me:x'});
      expect(tracker.hasPending, isTrue);
      tracker.markViewed('A');
      expect(tracker.hasPending, isFalse);

      // 序列化恢复。
      final restored = UnreadMentionTracker.decode(tracker.encode())!;
      expect(restored.hasPending, isFalse);
      // 重复同步同一条消息 → 不得复活。
      expect(
        restored.onMessageArrived(
            eventId: 'A', order: 1, senderIsSelf: false, mentionedUserIds: {'@me:x'}),
        isFalse,
        reason: 'R9 修复前：已查看集合未持久化→重复同步后 hasPending 复活为 true',
      );
    });

    test('普通已读推进后，延迟解密的提及仍加入（不因回执排除）', () {
      final tracker = UnreadMentionTracker(accountId: '@me:x', roomId: '!r:x');
      tracker.initializeBoundary(lastReadOrder: 10);
      // 普通已读推进到 order=100。
      tracker.onReadReceiptAdvanced(order: 100);
      // 此后一条延迟解密的提及（order=50，在回执之前但在初始边界之后）。
      expect(
        tracker.onMessageArrived(
            eventId: 'late', order: 50, senderIsSelf: false, mentionedUserIds: {'@me:x'}),
        isTrue,
        reason: '普通已读不替代逐条查看——回执不应收窄提及加入判定',
      );
    });

    test('初始边界之前的旧提及仍不加（回填防护）', () {
      final tracker = UnreadMentionTracker(accountId: '@me:x', roomId: '!r:x');
      tracker.initializeBoundary(lastReadOrder: 10);
      expect(
        tracker.onMessageArrived(
            eventId: 'old', order: 5, senderIsSelf: false, mentionedUserIds: {'@me:x'}),
        isFalse,
        reason: '初始历史边界之前的不加入',
      );
    });
  });

  group('R10：搜索竞态', () {
    ChatSearchMessage msg(String id, String text,
            {String sender = '@a:x', int order = 1}) =>
        ChatSearchMessage(
          eventId: id,
          senderId: sender,
          senderDisplayName: 'A',
          timestamp: DateTime(2026, 9, 6),
          timelineOrder: order,
          visibleText: text,
        );

    test('清空条件 → 空态；旧请求迟到不覆盖', () async {
      final slow = Completer<List<ChatSearchMessage>>();
      var call = 0;
      final controller = ChatSearchQueryController(
        search: (f, {cursor, limit = 50}) async =>
            call == 1 ? slow.future : Future.value([]),
      );
      // 先发起一个慢查询。
      controller.setKeyword('old');
      final oldFuture = controller.executeNow();
      // 清空条件 → 新的空态查询。
      controller.clearAll();
      final emptyResult = await controller.executeNow();
      expect(emptyResult.items, isEmpty);
      // 旧慢查询现在完成 → 不应覆盖（stale）。
      slow.complete([msg('old', 'old hit')]);
      final oldPage = await oldFuture;
      expect(oldPage.stale, isTrue, reason: 'R10：旧请求完成不覆盖空态');
    });

    test('防抖期间换词 → 旧防抖完成不悬挂', () async {
      final controller = ChatSearchQueryController(
        search: (f, {cursor, limit = 50}) async => [],
      );
      controller.setKeyword('first');
      final first = controller.scheduleDebounced();
      controller.setKeyword('second');
      final second = controller.scheduleDebounced();
      // first 被 second 取代 → 以 stale 完成（不悬挂）。
      final firstResult = await first.timeout(const Duration(milliseconds: 100));
      expect(firstResult.stale, isTrue, reason: '被取代的防抖完成不悬挂');
      // second 正常完成。
      await second.timeout(const Duration(milliseconds: 500));
    });

    test('loadMore 期间条件变更 → stale 不合并', () async {
      final data = [for (var i = 0; i < 10; i++) msg('e$i', 'item $i', order: i)];
      final gate = Completer<void>();
      final controller = ChatSearchQueryController(
        search: (f, {cursor, limit = 50}) async {
          if (cursor == null) return data.take(5).toList();
          await gate.future;
          return data.skip(5).toList();
        },
      );
      controller.setKeyword('item');
      final first = await controller.executeNow(limit: 5);
      expect(first.items, hasLength(5));
      // 发起翻页（gate 挂起）。
      final moreFuture = controller.loadMore(first, limit: 5);
      // 翻页期间换词。
      controller.setKeyword('new');
      gate.complete();
      final merged = await moreFuture;
      expect(merged.stale, isTrue, reason: 'R10：旧翻页在新查询后标 stale');
    });

    test('cancelDebounce → Future 完成', () async {
      final controller = ChatSearchQueryController(
        search: (f, {cursor, limit = 50}) async => [],
      );
      controller.setKeyword('x');
      final pending = controller.scheduleDebounced();
      controller.cancelDebounce();
      final result = await pending.timeout(const Duration(milliseconds: 100));
      expect(result.stale, isTrue, reason: '取消的防抖完成不悬挂');
    });
  });

  group('R11：缓存清理生命周期', () {
    test('evict 期间在途加载完成 → 不写回已移除键', () async {
      final disk = <String, Uint8List>{};
      final gate = Completer<void>();
      final started = Completer<void>();
      var loads = 0;
      final cache = VideoPosterSessionCache(
        diskRead: (k) async => disk[k],
        diskWrite: (k, b) async => disk[k] = b,
        diskDelete: (k) async => disk.remove(k),
      );
      const key = 'a|r|m|v1|grid';
      // 发起加载（gate 挂起）。
      final loading = cache.load(key, () async {
        loads++;
        started.complete();
        await gate.future;
        return Uint8List.fromList(List.filled(20, 1));
      });
      // 加载在途时 evict。
      await started.future;
      await cache.evict(key);
      gate.complete();
      final result = await loading;
      expect(result.stale, isTrue, reason: 'evict 后的加载结果不写回');
      expect(cache.memoryEntries, 0, reason: 'R11 修复前：在途加载写回→memoryEntries=1');
      expect(disk.containsKey(key), isFalse,
          reason: 'R11 修复前：在途加载写回磁盘→diskHasOld=true');
      expect(loads, 1);
    });

    test('clearAll 清内存 + 清磁盘', () async {
      final disk = <String, Uint8List>{};
      final cache = VideoPosterSessionCache(
        diskRead: (k) async => disk[k],
        diskWrite: (k, b) async => disk[k] = b,
        diskDelete: (k) async => disk.remove(k),
      );
      await cache.load('k1', () async => Uint8List.fromList(List.filled(10, 1)));
      await cache.load('k2', () async => Uint8List.fromList(List.filled(10, 2)));
      expect(disk, hasLength(2));
      await cache.clearAll();
      expect(cache.memoryEntries, 0);
      expect(disk, isEmpty, reason: 'R11 修复前：clearAll 不清磁盘');
      // clearAll 后磁盘读不到旧条目。
      final result = await cache.load('k1', () async => null);
      expect(result.retryable, isTrue, reason: 'R11 修复前：clearAll 后 fromDisk=true');
    });

    test('replace 后新键可写', () async {
      final disk = <String, Uint8List>{};
      final cache = VideoPosterSessionCache(
        diskRead: (k) async => disk[k],
        diskWrite: (k, b) async => disk[k] = b,
        diskDelete: (k) async => disk.remove(k),
      );
      await cache.replace('old', 'new', Uint8List.fromList(List.filled(10, 9)));
      expect(cache.memoryEntries, 1);
      expect(disk.containsKey('new'), isTrue);
      expect(disk.containsKey('old'), isFalse);
    });
  });
}
