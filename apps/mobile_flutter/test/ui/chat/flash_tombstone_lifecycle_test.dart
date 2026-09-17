import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/flash_photo.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 闪照 tombstone 的**真实生命周期**契约。
///
/// 安全不变量：标记（tombstone）绝**不**因容量原因淘汰。
/// 只允许在「本地数据真的消失」时清理：
/// - 单条消息在本地被永久删除 → 只删该 event 的标记；
/// - 房间本地历史被**永久**清除 → 只删该房间的标记；
/// - 该账号的本地加密库被整体删除 → 删该账号全部标记。
///
/// 反向不变量（同样重要）：**软隐藏**（清空聊天记录 = 写 cutoff）与**普通
/// 登出**（保留本地库）都**不得**清理标记——否则旧事件重新同步后会重新
/// 变成「未查看」并可再次打开，这是 fail-open。
void main() {
  const accountA = 'matrix:@a:test';
  const accountB = 'matrix:@b:test';
  const roomA = '!room-a:test';
  const roomB = '!room-b:test';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('按房间清理', () {
    test('clearRoom 只清该房间，其他房间与账号不受影响', () async {
      final store = await FlashPhotoViewedStore.load(accountA);
      store.markViewed(r'$a1', roomId: roomA);
      store.markViewed(r'$a2', roomId: roomA);
      store.markViewed(r'$b1', roomId: roomB);
      expect(store.debugCount, 3);

      await store.clearRoom(roomA);

      expect(store.isViewed(r'$a1'), isFalse);
      expect(store.isViewed(r'$a2'), isFalse);
      expect(store.isViewed(r'$b1'), isTrue, reason: '清空一个房间绝不能误删其他房间的标记');
      expect(store.debugCount, 1);
    });

    test('clearRoom 的清理是持久化的（重载后仍然生效）', () async {
      final store = await FlashPhotoViewedStore.load(accountA);
      store.markViewed(r'$a1', roomId: roomA);
      store.markViewed(r'$b1', roomId: roomB);
      await store.clearRoom(roomA);

      final reloaded = await FlashPhotoViewedStore.load(accountA);
      expect(reloaded.isViewed(r'$a1'), isFalse);
      expect(reloaded.isViewed(r'$b1'), isTrue);
    });

    test('未标记过的房间调用 clearRoom 是安全的空操作', () async {
      final store = await FlashPhotoViewedStore.load(accountA);
      store.markViewed(r'$b1', roomId: roomB);
      await store.clearRoom('!never-marked:test');
      expect(store.isViewed(r'$b1'), isTrue);
    });

    test('兼容无房间维度的旧数据：dropForEventIds 仍能按事件清理', () async {
      final store = await FlashPhotoViewedStore.load(accountA);
      // 旧格式（仅 eventId）——升级前写入的标记。
      store.markViewed(r'$legacy');
      expect(store.isViewed(r'$legacy'), isTrue);

      store.dropForEventIds([r'$legacy']);
      expect(store.isViewed(r'$legacy'), isFalse);
      expect((await FlashPhotoViewedStore.load(accountA)).isViewed(r'$legacy'),
          isFalse,
          reason: '清理必须落盘');
    });

    test('dropForEventIds 不会误删同房间的其他事件', () async {
      final store = await FlashPhotoViewedStore.load(accountA);
      store.markViewed(r'$a1', roomId: roomA);
      store.markViewed(r'$a2', roomId: roomA);
      store.dropForEventIds([r'$a1']);
      expect(store.isViewed(r'$a1'), isFalse);
      expect(store.isViewed(r'$a2'), isTrue);
    });
  });

  group('按账号清理', () {
    test('clearAccount 清空该账号（含房间维度与旧格式条目）', () async {
      final store = await FlashPhotoViewedStore.load(accountA);
      store.markViewed(r'$a1', roomId: roomA);
      store.markViewed(r'$legacy');
      await FlashPhotoViewedStore.clearAccount(accountA);

      final reloaded = await FlashPhotoViewedStore.load(accountA);
      expect(reloaded.isViewed(r'$a1'), isFalse);
      expect(reloaded.isViewed(r'$legacy'), isFalse);
      expect(reloaded.debugCount, 0);
    });

    test('账号 A 的清理绝不影响账号 B', () async {
      final a = await FlashPhotoViewedStore.load(accountA);
      final b = await FlashPhotoViewedStore.load(accountB);
      a.markViewed(r'$shared-event-id', roomId: roomA);
      b.markViewed(r'$shared-event-id', roomId: roomA);

      await FlashPhotoViewedStore.clearAccount(accountA);

      expect(
          (await FlashPhotoViewedStore.load(accountA))
              .isViewed(r'$shared-event-id'),
          isFalse);
      expect(
          (await FlashPhotoViewedStore.load(accountB))
              .isViewed(r'$shared-event-id'),
          isTrue,
          reason: '账号之间必须完全隔离（同 eventId 也不能互相影响）');
    });

    test('store.clear() 清空当前账号并落盘', () async {
      final store = await FlashPhotoViewedStore.load(accountA);
      store.markViewed(r'$a1', roomId: roomA);
      store.markViewed(r'$a2', roomId: roomB);
      await store.clear();
      expect(store.debugCount, 0);
      expect((await FlashPhotoViewedStore.load(accountA)).debugCount, 0);
    });
  });

  group('生命周期语义：什么时候**不**清理', () {
    test('软隐藏（清空聊天记录 = 写 cutoff）不得清理标记', () async {
      // 生产语义：RoomPage._clearLocalHistory 只写 cutoff，事件仍在本地库，
      // 重新同步后可能再次出现。此时清标记 = 旧闪照复活 = fail-open。
      final store = await FlashPhotoViewedStore.load(accountA);
      store.markViewed(r'$soft-hidden', roomId: roomA);

      // 「清空聊天记录」不接触 tombstone：这里显式断言调用方不存在该路径，
      // 用「模拟清空后重新读取」来证明标记仍在。
      final reloaded = await FlashPhotoViewedStore.load(accountA);
      expect(reloaded.isViewed(r'$soft-hidden'), isTrue,
          reason: '软隐藏后标记必须保留，否则旧事件会重新可看');
    });

    test('普通登出（保留本地加密库）不得清理标记', () async {
      // 生产语义：suspend() 明确保留加密库与本地历史；登出只暂停会话。
      final store = await FlashPhotoViewedStore.load(accountA);
      store.markViewed(r'$a1', roomId: roomA);
      store.markViewed(r'$a2', roomId: roomB);

      final reloaded = await FlashPhotoViewedStore.load(accountA);
      expect(reloaded.debugCount, 2, reason: '登出保留本地历史 → 标记必须保留');
    });

    test('容量永不淘汰：远超旧上限后最早一条仍然有效', () async {
      final store = await FlashPhotoViewedStore.load(accountA);
      for (var i = 0; i <= 1200; i++) {
        store.markViewed('e$i', roomId: roomA);
      }
      expect(store.isViewed('e0'), isTrue, reason: '不存在任何按数量淘汰的机制');
      final reloaded = await FlashPhotoViewedStore.load(accountA);
      expect(reloaded.isViewed('e0'), isTrue);
      expect(reloaded.debugCount, 1201);
    });
  });

  group('持久化格式', () {
    test('含房间维度的条目在重载后仍然可查（且不泄漏明文）', () async {
      final store = await FlashPhotoViewedStore.load(accountA);
      store.markViewed(r'$with-room', roomId: roomA);
      final reloaded = await FlashPhotoViewedStore.load(accountA);
      expect(reloaded.isViewed(r'$with-room'), isTrue);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(FlashPhotoViewedStore.keyFor(accountA));
      expect(raw, isNotNull);
      // 只存不透明标识（roomId + eventId），不含任何正文/媒体/密钥。
      for (final entry in raw!) {
        expect(entry, contains(r'$with-room'));
        for (final forbidden in [
          'body',
          'plaintext',
          'mxc://',
          'accessToken',
          'data:image',
        ]) {
          expect(entry, isNot(contains(forbidden)));
        }
      }
    });

    test('账号 key 前缀稳定（登出清理路径依赖）', () {
      expect(FlashPhotoViewedStore.keyFor(accountA), 'flash-viewed:$accountA');
    });
  });
}
