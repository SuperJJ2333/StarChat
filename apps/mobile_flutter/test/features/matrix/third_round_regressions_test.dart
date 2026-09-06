import 'dart:async';
// unawaited from dart:async
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/features/matrix/mention_composer_model.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_session_cache.dart';

/// 第三轮复审修复回归。
void main() {
  group('光标仅移动清触发（selection-only 通知）', () {
    test('输入 @兄 → 移动光标到 0 → 触发应清除', () {
      final input = TextEditingController();
      final model = MentionComposerModel();
      var lastText = '';
      void handler() {
        final next = input.text;
        if (next != lastText) {
          model.text = next;
          final cursor = input.selection.baseOffset;
          if (cursor > 0 && cursor <= next.length &&
              next.codeUnitAt(cursor - 1) == 0x40) {
            model.triggerAt(cursor - 1);
          }
          lastText = next;
        }
        // 三审修复：光标检查在文本差分之外——仅移动 selection 也执行。
        final cursor = input.selection.baseOffset;
        final trigger = model.pendingTriggerStart;
        if (trigger != null && cursor >= 0) {
          final inRange = cursor > trigger && cursor <= input.text.length;
          if (!inRange) model.pendingTriggerStart = null;
        }
      }
      input.addListener(handler);
      addTearDown(() => input.dispose());

      // 先输入 @（触发记录在 0）。
      input.value = const TextEditingValue(
          text: '@', selection: TextSelection.collapsed(offset: 1));
      expect(model.pendingTriggerStart, 0);

      // 继续输入查询词 @兄。
      input.value = const TextEditingValue(
          text: '@兄', selection: TextSelection.collapsed(offset: 2));
      expect(model.pendingTriggerStart, 0,
          reason: '查询词扩展不清触发');

      // 仅移动光标到 0（文本不变——旧代码此检查在 if 内不会运行）。
      input.selection = const TextSelection.collapsed(offset: 0);
      expect(model.pendingTriggerStart, isNull,
          reason: '三审修复前：光标检查在 if(text 变化) 内，selection-only 不触发');
    });
  });

  group('防抖悬挂（外部 executeNow 完成旧 Future）', () {
    test('scheduleDebounced → executeNow（提交按钮）→ 旧 Future 完成', () async {
      final controller = ChatSearchQueryController(
        search: (f, {cursor, limit = 50}) async => [],
      );
      controller.setKeyword('test');
      final pending = controller.scheduleDebounced();
      // 用户在防抖等待期间点了搜索按钮。
      await controller.executeNow();
      // 旧 Future 应完成（stale），不悬挂。
      final result =
          await pending.timeout(const Duration(milliseconds: 200));
      expect(result.stale, isTrue,
          reason: '三审修复前：timer 取消但 completer 不完成→悬挂');
    });
  });

  group('缓存 I/O 竞争', () {
    test('diskWrite 期间 clearAll → 写入撤销+返回 stale', () async {
      final disk = <String, Uint8List>{};
      final writeGate = Completer<void>();
      final cache = VideoPosterSessionCache(
        diskRead: (k) async => disk[k],
        diskWrite: (k, b) async {
          await writeGate.future;
          disk[k] = b;
        },
        diskDelete: (k) async => disk.remove(k),
      );
      // 发起加载（写盘挂起）。
      final loading = cache.load('key', () async => Uint8List.fromList(List.filled(10, 1)));
      // 写盘期间 clearAll。
      await cache.clearAll();
      writeGate.complete();
      final result = await loading;
      expect(result.stale, isTrue, reason: '三审修复前：写入完成后返回 stale=false');
      expect(disk, isEmpty, reason: '三审修复前：写入落盘后已清理内容复活');
    });

    test('diskRead 期间 evict → 返回 stale', () async {
      final disk = <String, Uint8List>{};
      final readGate = Completer<void>();
      var readCalls = 0;
      final cache = VideoPosterSessionCache(
        diskRead: (k) async {
          readCalls++;
          if (readCalls > 1) await readGate.future; // 只挂起第二次读。
          return disk[k];
        },
        diskWrite: (k, b) async => disk[k] = b,
        // 不传 diskDelete：evict 只标记键（磁盘数据仍在——模拟读取
        // 期间 evict 但磁盘删除尚未完成的窗口）。
      );
      // 先写入一个条目（首次读不挂起）。
      await cache.load('k1', () async => Uint8List.fromList(List.filled(10, 1)));
      // 清内存使下次 load 走磁盘。
      cache.clearMemory();
      // 发起磁盘读（第二次读挂起）。
      final reading = cache.load('k1', () async => null);
      // 读取期间 evict（标记已移除，但磁盘数据还在——readGate 挂起中）。
      // 注意：evict 的 diskDelete 为 null，所以磁盘条目未被删。
      // 但 _evictedKeys 已含 k1。
      unawaited(cache.evict('k1'));
      // 等待微任务让 evict 完成（_evictedKeys.add 已同步执行）。
      await Future<void>.delayed(Duration.zero);
      readGate.complete();
      final result = await reading;
      expect(result.stale, isTrue, reason: '三审修复前：读取期间 evict 返回 stale=false');
    });
  });

  group('翻页结果不被覆盖（状态源统一）', () {
    test('loadMore 后 items 长度持续 > 首页（模拟 build 不覆盖）', () async {
      final data = [
        for (var i = 0; i < 100; i++)
          ChatSearchMessage(
            eventId: 'e$i',
            senderId: '@a:x',
            senderDisplayName: 'A',
            timestamp: DateTime(2026, 9, 6),
            timelineOrder: i,
            visibleText: 'item $i',
          ),
      ];
      final controller = ChatSearchQueryController(
        search: (f, {cursor, limit = 50}) async {
          int start = 0;
          if (cursor != null) {
            start = data.indexWhere((m) => m.timelineOrder == cursor.order) + 1;
          }
          return data.skip(start).take(limit).toList();
        },
      );
      controller.setKeyword('item');
      final first = await controller.executeNow(limit: 50);
      expect(first.items, hasLength(50));
      final second = await controller.loadMore(first, limit: 50);
      expect(second.items, hasLength(100),
          reason: '翻页应追加到 100 条，不被首批覆盖');
      expect(second.stale, isFalse);
      // 模拟 _loadMore setState 后 _lastPage 更新（不被 build 覆盖）。
      // ChatSearchPage 的修复在 UI 层：_lastPage 只在 loaded 回调中写入。
    });
  });
}
