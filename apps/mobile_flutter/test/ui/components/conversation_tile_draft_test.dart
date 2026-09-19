import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/room_draft_store.dart';
import 'package:liuhetong_mobile/ui/components/conversation_list_tile.dart';

/// BUG-20：有草稿的会话在消息列表中显示红色「草稿：」标识。
/// 真机回归修订：草稿预览改为逐 tile 通知器（ValueListenable），
/// 更新只重建对应 tile——不再全列表 setState（修卡顿与延迟）。
void main() {
  testWidgets('tile 渲染草稿标识：红色「草稿：」前缀 + 草稿正文，更新即时生效',
      (tester) async {
    final draft = ValueNotifier<String?>('明天记得带伞');
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: ConversationListTile(
          title: '周然',
          subtitle: '上次聊到的消息摘要',
          draftListenable: draft,
          timeLabel: '昨天',
          avatar: const SizedBox.shrink(),
        ),
      ),
    ));

    expect(find.textContaining('草稿：明天记得带伞', findRichText: true),
        findsOneWidget,
        reason: '草稿标识与正文同段渲染（红色前缀 + 灰色正文）');
    expect(find.text('上次聊到的消息摘要'), findsNothing,
        reason: '有草稿时副标题被草稿标识取代（微信语义）');

    // 逐 tile 监听：通知器更新（含清空）即时反映，不需要父级重建。
    draft.value = '换成了别的草稿';
    await tester.pump();
    expect(find.textContaining('草稿：换成了别的草稿', findRichText: true),
        findsOneWidget);
    draft.value = null;
    await tester.pump();
    expect(find.textContaining('草稿：', findRichText: true), findsNothing);
    expect(find.text('上次聊到的消息摘要'), findsOneWidget);
  });

  testWidgets('无草稿时保持原副标题', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: ConversationListTile(
          title: '周然',
          subtitle: '上次聊到的消息摘要',
          timeLabel: '昨天',
          avatar: const SizedBox.shrink(),
        ),
      ),
    ));

    expect(find.textContaining('草稿：', findRichText: true), findsNothing);
    expect(find.text('上次聊到的消息摘要'), findsOneWidget);
  });

  test('RoomDraftStore 预览索引：逐房间通知器登记/清除/更新/幂等', () {
    final store = RoomDraftStore(_MemoryStore());
    final listenable = store.draftListenable('!room:example');
    final seen = <String?>[];
    listenable.addListener(() => seen.add(listenable.value));

    expect(listenable.value, isNull);
    store.recordDraftPreview('!room:example', '未发送的草稿');
    expect(listenable.value, '未发送的草稿');
    store.recordDraftPreview('!room:example', '更新后的草稿');
    expect(listenable.value, '更新后的草稿');
    store.recordDraftPreview('!room:example', '');
    expect(listenable.value, isNull, reason: '发送/清空后移除');
    expect(seen, ['未发送的草稿', '更新后的草稿', null],
        reason: '值变化必须逐次通知对应 tile');

    // 相同内容重复登记不产生多余通知（打字防抖期间多次保存）。
    store.recordDraftPreview('!room:example', '新的草稿');
    store.recordDraftPreview('!room:example', '新的草稿');
    expect(seen.length, 4, reason: '幂等登记只通知一次');
  });

  test('BUG-20 排序：进入/离开草稿态发成员修订，正文编辑不触发', () {
    final store = RoomDraftStore(_MemoryStore());
    final memberships = <int>[];
    store.draftMembershipRevision
        .addListener(() => memberships.add(store.draftMembershipRevision.value));

    store.recordDraftPreview('!room:example', '第一');
    expect(store.draftRoomIds, {'!room:example'});
    expect(memberships.length, 1, reason: '进入草稿态：触发重排');

    store.recordDraftPreview('!room:example', '第一稿更新了');
    store.recordDraftPreview('!room:example', '第一稿又更新');
    expect(memberships.length, 1,
        reason: '草稿正文编辑不得触发列表重排（逐 tile 即时更新即可）');

    store.recordDraftPreview('!room:example', '');
    expect(store.draftRoomIds, isEmpty);
    expect(memberships.length, 2, reason: '离开草稿态：触发重排');
  });
}

final class _MemoryStore implements SecureKeyValueStore {
  final _values = <String, String>{};
  @override
  Future<void> delete(String key) async => _values.remove(key);
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}
