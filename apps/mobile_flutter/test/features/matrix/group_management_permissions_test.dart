import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/cupertino.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_page.dart';
import 'package:liuhetong_mobile/features/matrix/group_room_authority.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_controller.dart';
import 'group_chat_info_test.dart' show FakeGroupChatInfoGateway;

void main() {
  test('owner follows transferred power levels rather than room creator', () {
    final room = Room(id: '!room:test', client: Client('test'));
    room.setState(Event(
        type: EventTypes.RoomCreate,
        content: {},
        senderId: '@old:test',
        room: room,
        eventId: r'$create',
        stateKey: '',
        originServerTs: DateTime(2026)));
    room.setState(Event(
        type: EventTypes.RoomPowerLevels,
        content: {
          'users': {'@old:test': 0, '@new:test': 100}
        },
        senderId: '@old:test',
        room: room,
        eventId: r'$power',
        stateKey: '',
        originServerTs: DateTime(2026)));
    expect(GroupRoomAuthority(room).ownerId, '@new:test');
  });
  test('administrator cannot grant roles or transfer ownership', () async {
    final gateway = FakeGroupChatInfoGateway();
    gateway.snapshot = gateway.snapshot.copyWith(
        ownerId: '@owner:test',
        currentUserId: '@admin:test',
        adminIds: ['@admin:test']);
    final controller = GroupChatInfoController(gateway);
    await controller.load();
    await controller.setAdminIds(['@other:test']);
    expect(controller.state.status, GroupChatInfoStatus.failed);
    expect(gateway.snapshot.adminIds, ['@admin:test']);
    await controller.transferOwnership('@other:test');
    expect(controller.state.status, GroupChatInfoStatus.failed);
    expect(await controller.dissolve(), isFalse);
  });
  testWidgets(
      'management route observes controller and hides owner actions from admin',
      (tester) async {
    final gateway = FakeGroupChatInfoGateway();
    gateway.snapshot = gateway.snapshot.copyWith(
        ownerId: '@owner:test',
        currentUserId: '@admin:test',
        adminIds: ['@admin:test']);
    final controller = GroupChatInfoController(gateway);
    await controller.load();
    await tester.pumpWidget(
        CupertinoApp(home: GroupManagementPage(controller: controller)));
    expect(find.text('群主管理权转让'), findsNothing);
    expect(find.text('解散该群聊'), findsNothing);
    await controller.setGroupSetting('qr_join_enabled', false);
    await tester.pump();
    expect(
        tester
            .widget<CupertinoSwitch>(find.byType(CupertinoSwitch).first)
            .value,
        isFalse);
  });
  test('ordinary members cannot mutate shared group settings', () async {
    final gateway = FakeGroupChatInfoGateway();
    gateway.snapshot =
        gateway.snapshot.copyWith(currentUserId: '@ordinary:example.test');
    final controller = GroupChatInfoController(gateway);
    await controller.load();
    await controller.setGroupSetting('qr_join_enabled', false);
    expect(controller.state.status, GroupChatInfoStatus.failed);
    expect(controller.state.snapshot!.qrJoinEnabled, isTrue);
  });
  test('ordinary members cannot remove joined members', () async {
    final gateway = FakeGroupChatInfoGateway();
    gateway.snapshot =
        gateway.snapshot.copyWith(currentUserId: '@ordinary:example.test');
    final controller = GroupChatInfoController(gateway);
    await controller.load();
    await controller.removeMembers(['@member1:example.test']);
    expect(gateway.snapshot.members.length, 12);
    expect(controller.state.status, GroupChatInfoStatus.failed);
  });
}
