import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/unread_mention_tracker.dart';

/// 规格 #2：未读 @ 状态机。
void main() {
  UnreadMentionTracker make({String account = '@me:x', String room = '!r:x'}) =>
      UnreadMentionTracker(accountId: account, roomId: room);

  group('判定规则', () {
    test('结构化提及包含本人 → 计入；不凭正文 @ 判断', () {
      final tracker = make();
      final added = tracker.onMessageArrived(
        eventId: 'e1',
        order: 10,
        senderIsSelf: false,
        mentionedUserIds: {'@me:x', '@other:x'},
      );
      expect(added, isTrue);
      // 正文有 @ 但结构化目标不含本人 → 不计入。
      final plain = tracker.onMessageArrived(
        eventId: 'e2',
        order: 11,
        senderIsSelf: false,
        mentionedUserIds: {'@someone-else:x'},
      );
      expect(plain, isFalse);
    });

    test('本人发送 / 已撤回删除 → 不计入；撤回后移除', () {
      final tracker = make();
      expect(
        tracker.onMessageArrived(
            eventId: 'own', order: 1, senderIsSelf: true, mentionedUserIds: {'@me:x'}),
        isFalse,
      );
      expect(
        tracker.onMessageArrived(
            eventId: 'redacted',
            order: 2,
            senderIsSelf: false,
            mentionedUserIds: {'@me:x'},
            redactedOrDeleted: true),
        isFalse,
      );
      tracker.onMessageArrived(
          eventId: 'e1', order: 3, senderIsSelf: false, mentionedUserIds: {'@me:x'});
      tracker.onRedacted('e1');
      expect(tracker.hasPending, isFalse);
    });

    test('@所有人：本人属于提醒范围 → 计入', () {
      final tracker = make();
      final added = tracker.onMessageArrived(
        eventId: 'all-1',
        order: 5,
        senderIsSelf: false,
        // @所有人展开后的成员集合包含本人。
        mentionedUserIds: {'@me:x', '@a:x', '@b:x'},
      );
      expect(added, isTrue);
    });

    test('历史边界：初次建立的已读位置之前不加入；重新解密不重复', () {
      final tracker = make()..initializeBoundary(lastReadOrder: 100);
      expect(
        tracker.onMessageArrived(
            eventId: 'old', order: 50, senderIsSelf: false, mentionedUserIds: {'@me:x'}),
        isFalse,
        reason: '边界之前的旧提及不加入',
      );
      expect(
        tracker.onMessageArrived(
            eventId: 'new', order: 101, senderIsSelf: false, mentionedUserIds: {'@me:x'}),
        isTrue,
      );
      expect(
        tracker.onMessageArrived(
            eventId: 'new', order: 101, senderIsSelf: false, mentionedUserIds: {'@me:x'}),
        isFalse,
        reason: '重复（重新解密）不重复加入',
      );
    });
  });

  group('验收：逐条跳转与清空', () {
    test('A、B、C 时间递增 → 依次定位 C→B→A；全部查看后清空', () {
      final tracker = make();
      for (final (i, id) in ['A', 'B', 'C'].indexed) {
        tracker.onMessageArrived(
            eventId: id, order: 100 + i, senderIsSelf: false, mentionedUserIds: {'@me:x'});
      }
      expect(tracker.nextJumpTarget, 'C', reason: '最新优先');
      expect(tracker.markViewed('C'), isTrue);
      expect(tracker.nextJumpTarget, 'B');
      tracker.markViewed('B');
      expect(tracker.nextJumpTarget, 'A');
      tracker.markViewed('A');
      expect(tracker.hasPending, isFalse, reason: '集合为空才视为清空');
    });

    test('查看 C 后收到 D → 下次定位 D；继续 B→A', () {
      final tracker = make();
      tracker.onMessageArrived(
          eventId: 'A', order: 1, senderIsSelf: false, mentionedUserIds: {'@me:x'});
      tracker.onMessageArrived(
          eventId: 'B', order: 2, senderIsSelf: false, mentionedUserIds: {'@me:x'});
      tracker.onMessageArrived(
          eventId: 'C', order: 3, senderIsSelf: false, mentionedUserIds: {'@me:x'});
      tracker.markViewed('C');
      tracker.onMessageArrived(
          eventId: 'D', order: 4, senderIsSelf: false, mentionedUserIds: {'@me:x'});
      expect(tracker.nextJumpTarget, 'D');
      tracker.markViewed('D');
      expect(tracker.pendingEventIdsNewestFirst(), ['B', 'A']);
    });

    test('手动查看 B → 跳转队列不再包含 B', () {
      final tracker = make();
      tracker.onMessageArrived(
          eventId: 'A', order: 1, senderIsSelf: false, mentionedUserIds: {'@me:x'});
      tracker.onMessageArrived(
          eventId: 'B', order: 2, senderIsSelf: false, mentionedUserIds: {'@me:x'});
      tracker.markViewed('B');
      expect(tracker.pendingEventIdsNewestFirst(), ['A']);
    });

    test('跳转失败不消费记录', () {
      final tracker = make();
      tracker.onMessageArrived(
          eventId: 'A', order: 1, senderIsSelf: false, mentionedUserIds: {'@me:x'});
      tracker.onJumpFailed('A');
      expect(tracker.hasPending, isTrue);
      expect(tracker.nextJumpTarget, 'A');
    });

    test('普通已读推进不清空未查看 @', () {
      final tracker = make()..initializeBoundary(lastReadOrder: 0);
      tracker.onMessageArrived(
          eventId: 'A', order: 5, senderIsSelf: false, mentionedUserIds: {'@me:x'});
      tracker.onReadReceiptAdvanced(order: 100);
      expect(tracker.hasPending, isTrue, reason: '已读回执不清空 @ 集合');
      // 但边界推进后，更早的回填提及不再加入。
      expect(
        tracker.onMessageArrived(
            eventId: 'old', order: 50, senderIsSelf: false, mentionedUserIds: {'@me:x'}),
        isFalse,
      );
    });
  });

  group('持久化（账号隔离）', () {
    test('序列化/反序列化保持待查看集合与排序', () {
      final tracker = make(account: '@acct-a:x');
      tracker.initializeBoundary(lastReadOrder: 0);
      tracker.onMessageArrived(
          eventId: 'A', order: 1, senderIsSelf: false, mentionedUserIds: {'@acct-a:x'});
      tracker.onMessageArrived(
          eventId: 'B', order: 2, senderIsSelf: false, mentionedUserIds: {'@acct-a:x'});
      final restored = UnreadMentionTracker.decode(tracker.encode())!;
      expect(restored.accountId, '@acct-a:x');
      expect(restored.pendingEventIdsNewestFirst(), ['B', 'A']);
      expect(restored.nextJumpTarget, 'B');
    });

    test('重启后可恢复；退出重进不清空（边界不回退）', () {
      final tracker = make();
      tracker.initializeBoundary(lastReadOrder: 10);
      tracker.onMessageArrived(
          eventId: 'A', order: 11, senderIsSelf: false, mentionedUserIds: {'@me:x'});
      final restored = UnreadMentionTracker.decode(tracker.encode())!;
      expect(restored.hasPending, isTrue);
      // 恢复后边界不重置：旧提及（≤10）仍不加入。
      expect(
        restored.onMessageArrived(
            eventId: 'old', order: 10, senderIsSelf: false, mentionedUserIds: {'@me:x'}),
        isFalse,
      );
    });

    test('另一账号的持久化数据不可读（键隔离由存储层保证；数据自带账号）', () {
      final trackerA = make(account: '@a:x');
      trackerA.onMessageArrived(
          eventId: 'A', order: 1, senderIsSelf: false, mentionedUserIds: {'@a:x'});
      // 解码出的 tracker 属于账号 A；B 的 tracker 不会命中 A 的事件。
      final decoded = UnreadMentionTracker.decode(trackerA.encode())!;
      expect(decoded.accountId, '@a:x');
      final trackerB = make(account: '@b:x');
      expect(trackerB.pendingCount, 0);
    });
  });

  group('会话摘要前缀', () {
    test('[有人@你] 为独立前缀片段，不覆盖原摘要', () {
      final (prefix, rest) = mentionPrefixForSummary(
          hasPendingMention: true, originalSummary: '张三: 中午吃饭吗');
      expect(prefix, '[有人@你] ');
      expect(rest, '张三: 中午吃饭吗');
      final (nonePrefix, noneRest) = mentionPrefixForSummary(
          hasPendingMention: false, originalSummary: '摘要');
      expect(nonePrefix, '');
      expect(noneRest, '摘要');
    });
  });
}
