import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/search/global_search_controller.dart';
import 'package:liuhetong_mobile/features/search/global_search_index.dart';
import 'package:liuhetong_mobile/features/search/global_search_models.dart';

/// 微信级加载模型（2026-09-19 审计）：搜索控制器原先**先等联系人再等房间**，
/// 而联系人加载器在"接线缺身份缓存"时会退化成一次网络请求——于是已经完全本地的
/// 房间/聊天记录命中被卡在这条网络请求后面，页面停在加载态（L1/L2）。
/// 新顺序：先发布本机房间与索引命中，联系人到位后再补一次。
void main() {
  test('本机房间命中先发布，不被在途的联系人加载阻塞', () async {
    final contacts = Completer<List<GlobalSearchContactResult>>();
    final controller = GlobalSearchController(
      loadContacts: () => contacts.future,
      loadRooms: () async => const [
        GlobalSearchRoomResult(
            roomId: 'r1', displayName: '测试群', isDirect: false),
      ],
      index: GlobalSearchIndex(),
    );

    controller.setQuery('测试');
    final refreshing = controller.refresh();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.results.rooms.map((room) => room.roomId), contains('r1'),
        reason: '联系人还没回来时，本机房间结果必须先出现');
    expect(controller.loading, isFalse,
        reason: '本地结果已经可展示，不得继续停在加载态');
    expect(controller.error, isNull);

    contacts.complete(const []);
    await refreshing;
    expect(controller.results.rooms.map((room) => room.roomId), contains('r1'));
    controller.dispose();
  });

  test('联系人到位后再补一次，不丢联系人分组', () async {
    final controller = GlobalSearchController(
      loadContacts: () async => const [
        GlobalSearchContactResult(
            userId: 'u1', displayName: '小鸿', username: 'xiaohong'),
      ],
      loadRooms: () async => const [],
      index: GlobalSearchIndex(),
    );

    controller.setQuery('小鸿');
    await controller.refresh();

    expect(controller.results.contacts.map((c) => c.userId), contains('u1'));
    expect(controller.loading, isFalse);
    controller.dispose();
  });
}
