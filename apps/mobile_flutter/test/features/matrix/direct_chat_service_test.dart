import 'dart:convert';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'room_timeline_controller_test.dart' show FakeTimelineAdapter;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_presentation.dart';
import 'package:matrix/matrix.dart' show Membership;

void main() {
  group('规格1/5：私聊不产生群聊邀请 + 类型集中判定（源码合同）', () {
    test('时间线推导入群通知前有私聊分型门', () {
      final source = readFile('lib/features/matrix/matrix_e2ee_client.dart')
          .replaceAll('\r\n', '\n');
      expect(
          source.contains(
              '_lease._activeRoom.isDirectChat\n        ? const <GroupJoinNotice>[]'),
          isTrue,
          reason: '私聊房间绝不能推导"A邀请B加入群聊"通知');
    });

    test('业务层禁止直接 createRoom——私聊唯一入口 DirectChatService', () {
      final service = readFile('lib/features/matrix/direct_chat_service.dart');
      expect(service.contains('createOrGetDirectChat'), isTrue);
      expect(service.contains('_cache[matrixUserId]'), isTrue,
          reason: '规格7：friendId→roomId 缓存避免重复查询');
      // 复用语义：绝不重复建房（m.direct 权威 + 缓存）。
      expect(service.contains('getDirectChatFromUserId'), isTrue);
      expect(service.contains('Membership.join'), isTrue);
    });

    test('RoomType 判定：不以成员数量单独判私聊（必须 isDirectChat+2人）', () {
      expect(conversationRoomType(isDirectChat: true, memberCount: 2),
          ConversationRoomType.direct);
      expect(conversationRoomType(isDirectChat: false, memberCount: 2),
          ConversationRoomType.group);
      expect(conversationRoomType(isDirectChat: true, memberCount: 3),
          ConversationRoomType.group);
      expect(Membership.join.toString(), contains('join')); // import 锚
    });
  });

  group('规格4/5：详情页 UI 合同', () {
    test('Group 房间保留"保存到通讯录"，Direct 隐藏', () {
      final direct = readFile('lib/features/matrix/direct_chat_info_page.dart');
      expect(direct.contains("保存到通讯录"), isFalse, reason: '私聊详情页不得出现保存到通讯录');
      final group = readFile('lib/features/matrix/group_chat_info_page.dart');
      expect(group.contains('保存到通讯录'), isTrue, reason: '群详情页保留保存到通讯录');
    });

    test('清空聊天记录按钮居中（Center，非 padding 模拟）', () {
      final direct = readFile('lib/features/matrix/direct_chat_info_page.dart');
      final i = direct.lastIndexOf('清空聊天记录');
      expect(i, greaterThan(0));
      expect(direct.lastIndexOf('Center(', i), greaterThan(0),
          reason: '清空按钮必须在 Center 内');
    });

    test('消息通知一级菜单默认收起（AnimatedSize）', () {
      final direct = readFile('lib/features/matrix/direct_chat_info_page.dart');
      expect(direct.contains('ConversationNotificationSection('), isTrue);
      final shared = readFile(
          'lib/ui/notification/conversation_notification_mode_tile.dart');
      expect(shared.contains('bool expanded = false'), isTrue);
      expect(shared.contains('AnimatedSize'), isTrue);
    });

    test('头像点击进入 APP 好友资料页（onTapPerson，禁 Matrix Profile）', () {
      final direct = readFile('lib/features/matrix/direct_chat_info_page.dart');
      expect(direct.contains('onTapPerson'), isTrue);
      final room = readFile('lib/features/matrix/room_page.dart');
      expect(room.contains('onTapPerson:'), isTrue);
      expect(room.contains('AddFriendProfilePage('), isTrue);
    });
  });

  group('规格2/3/7：发送门禁与性能链路（源码合同）', () {
    test('发送路径服务层权限门：blocked/deleted → 本地 failed', () async {
      final adapter = FakeTimelineAdapter();
      final controller =
          RoomTimelineController(adapter, canSendNow: () => false);
      final observed = <RoomDeliveryState>[];
      var sends = 0;
      controller.addListener(() {
        observed.addAll(
            controller.messages.map((message) => message.deliveryState));
      });
      await controller.sendText('blocked', send: (_) async {
        sends++;
        return r'$sent';
      });
      await controller.refresh();
      expect(sends, 0);
      expect(observed, isNotEmpty);
      expect(observed, everyElement(RoomDeliveryState.failed));
      expect(
          controller.messages.single.deliveryState, RoomDeliveryState.failed);
      controller.dispose();
    });

    test('打开聊天先 push 再后台预热（5 秒延迟根因修复）', () {
      final home = readFile('lib/features/matrix/matrix_home_page.dart');
      // 身份预热仍是 fire-and-forget：打开房间不等待它。
      expect(home.indexOf('unawaited(_warmChatIdentity('), greaterThan(0));
      final openRoomStart =
          home.indexOf('Future<void> _openRoom(_RoomSnapshot snapshot)');
      expect(openRoomStart, greaterThan(0));
      final delegated =
          home.indexOf('await openRoom(RoomOpenRequest(', openRoomStart);
      expect(delegated, greaterThan(openRoomStart));
      // 预载/头像预解码只存在于 _warmChatIdentity（后台），
      // _openRoom 主体内在委托统一入口前无任何 await preload，也不自取租约。
      final body = home.substring(openRoomStart, delegated);
      expect(body.contains('await _identityCache.preload()'), isFalse,
          reason: '_openRoom 内不得串行等待身份预载（先 push 后台补齐）');
      expect(body.contains('openRoomLease('), isFalse,
          reason: 'RoomLease 生命周期已收敛到 AppHome 的统一房间导航');

      // AppHome 的统一打开流程：先取租约再 push，中途不串行等待身份预载。
      final appHome = readFile('lib/app_home.dart');
      final routeStart = appHome.indexOf('Future<void> _openManagedRoomRoute(');
      expect(routeStart, greaterThan(0));
      final routeBody = appHome.substring(
          routeStart, appHome.indexOf('handle.register(route);', routeStart));
      expect(routeBody.contains('await widget.matrix.openRoomLease(roomId)'),
          isTrue);
      expect(routeBody.contains('preload()'), isFalse,
          reason: '房间打开流程不得串行等待身份预载');
    });
  });
}

String readFile(String path) => File(path).readAsStringSync(encoding: utf8);

// dart:io 已在文件头 import（见上）。
// ignore: always_use_package_imports
// （测试读取仓库源码做合同断言，与 video_send_stage_test 同模式。）
