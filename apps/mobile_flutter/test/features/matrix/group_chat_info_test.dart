import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_controller.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_page.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';
import 'package:liuhetong_mobile/ui/components/wechat_list_tile.dart';

final class FakeGroupChatInfoGateway implements GroupChatInfoGateway {
  GroupChatInfoSnapshot snapshot = GroupChatInfoSnapshot(
    name: '项目讨论组',
    announcement: '今天 18:00 开会',
    remark: '核心项目',
    members: List.generate(
      12,
      (index) => GroupChatMember(
        matrixUserId: '@member$index:example.test',
        displayName: '成员$index',
      ),
    ),
  );
  final invited = <String>[];
  var left = false;

  @override
  Future<GroupChatInfoSnapshot> load() async => snapshot;

  @override
  Future<void> invite(String matrixUserId) async => invited.add(matrixUserId);

  @override
  Future<void> leave() async => left = true;

  @override
  Future<void> rename(String name) async {
    snapshot = snapshot.copyWith(name: name);
  }

  @override
  Future<void> setAnnouncement(String announcement) async {
    snapshot = snapshot.copyWith(announcement: announcement);
  }

  @override
  Future<void> setPreference(GroupChatPreference preference, bool value) async {
    snapshot = switch (preference) {
      GroupChatPreference.muted => snapshot.copyWith(muted: value),
      GroupChatPreference.pinned => snapshot.copyWith(pinned: value),
      GroupChatPreference.saved => snapshot.copyWith(saved: value),
      GroupChatPreference.folded => snapshot.copyWith(folded: value),
      GroupChatPreference.notifyMentionMe =>
        snapshot.copyWith(notifyMentionMe: value),
      GroupChatPreference.notifyMentionAll =>
        snapshot.copyWith(notifyMentionAll: value),
      GroupChatPreference.notifyAnnouncement =>
        snapshot.copyWith(notifyAnnouncement: value),
    };
  }

  @override
  Future<void> setFollowedMemberIds(List<String> matrixUserIds) async {
    snapshot =
        snapshot.copyWith(followedMemberIds: matrixUserIds.take(4).toList());
  }

  @override
  Future<void> setRemark(String remark) async {
    snapshot = snapshot.copyWith(remark: remark);
  }

  @override
  Future<void> removeMembers(List<String> matrixUserIds) async {
    snapshot = snapshot.copyWith(
      members: snapshot.members
          .where((member) => !matrixUserIds.contains(member.matrixUserId))
          .toList(),
    );
  }

  @override
  Future<void> setAdminIds(List<String> matrixUserIds) async {
    snapshot = snapshot.copyWith(adminIds: matrixUserIds);
  }

  @override
  Future<void> setGroupSetting(String key, Object value) async {}
}

void main() {
  test('loads joined members before building a group avatar mosaic', () async {
    final client = Client('test')
      ..homeserver = Uri.parse('https://matrix.example.test');
    final room = Room(id: '!group:example.test', client: client);
    room.setState(
      User(
        '@alice:example.test',
        room: room,
        displayName: 'Alice',
        membership: 'join',
      ),
    );

    expect(orderedJoinedMembers(room), hasLength(1));
  });

  test('group chat info controller loads members and persists changes',
      () async {
    final gateway = FakeGroupChatInfoGateway();
    final controller = GroupChatInfoController(gateway);

    await controller.load();
    expect(controller.state.snapshot!.members, hasLength(12));
    expect(controller.state.title, '聊天信息(12)');

    await controller.rename('新群名');
    await controller.setAnnouncement('新公告');
    await controller.setRemark('新备注');
    await controller.setPreference(GroupChatPreference.muted, true);

    expect(controller.state.snapshot!.name, '新群名');
    expect(controller.state.snapshot!.announcement, '新公告');
    expect(controller.state.snapshot!.remark, '新备注');
    expect(controller.state.snapshot!.muted, isTrue);
  });

  testWidgets('group info folds members and keeps add as the final grid item',
      (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = GroupChatInfoController(FakeGroupChatInfoGateway());

    await tester.pumpWidget(
      CupertinoApp(
        home: GroupChatInfoPage(
          controller: controller,
          onAddMember: () {},
          onSearchHistory: () {},
          onClearLocalHistory: () async {},
          onLeft: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('聊天信息(12)'), findsOneWidget);
    expect(find.byKey(const Key('group-member-add')), findsOneWidget);
    expect(find.byKey(const Key('group-member-9')), findsNothing);
    expect(find.text('查看更多群成员'), findsOneWidget);

    final orderedLabels = [
      '群聊名称',
      '群公告',
      '备注',
      '查找聊天记录',
      '消息免打扰',
      '置顶聊天',
      '保存到通讯录',
      '清空聊天记录',
      '退出群聊',
    ];
    for (final label in orderedLabels.take(7)) {
      expect(find.text(label), findsOneWidget);
    }
    final visibleTops = orderedLabels
        .take(7)
        .map((label) => tester.getTopLeft(find.text(label)).dy)
        .toList(growable: false);
    expect(visibleTops, orderedEquals(visibleTops.toList()..sort()));
    await tester.drag(find.byType(ListView).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    for (final label in orderedLabels.skip(7)) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a group member opens that member profile',
      (tester) async {
    GroupChatMember? tapped;
    final controller = GroupChatInfoController(FakeGroupChatInfoGateway());
    await tester.pumpWidget(CupertinoApp(
      home: GroupChatInfoPage(
        controller: controller,
        onAddMember: () {},
        onSearchHistory: () {},
        onClearLocalHistory: () async {},
        onLeft: () {},
        onMemberTap: (member) => tapped = member,
      ),
    ));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const Key('group-member-@member0:example.test')));
    expect(tapped?.matrixUserId, '@member0:example.test');
  });
  testWidgets('member picker excludes existing members and invites selection',
      (tester) async {
    final invited = <String>[];
    await tester.pumpWidget(
      CupertinoApp(
        home: GroupMemberPickerPage(
          contacts: const [
            ContactSummary(
              userId: 'existing',
              username: 'existing',
              matrixUserId: '@existing:example.test',
            ),
            ContactSummary(
              userId: 'new',
              username: 'new',
              nickname: '新成员',
              matrixUserId: '@new:example.test',
            ),
          ],
          existingMemberIds: const {'@existing:example.test'},
          onInvite: (matrixUserId) async => invited.add(matrixUserId),
        ),
      ),
    );

    expect(find.text('existing'), findsNothing);
    await tester.tap(find.text('新成员'));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pump();
    expect(invited, ['@new:example.test']);
  });

  testWidgets('history search filters locally decrypted entries',
      (tester) async {
    await tester.pumpWidget(
      const CupertinoApp(
        home: GroupChatHistorySearchPage(
          entries: [
            GroupChatHistoryEntry(sender: 'Alice', text: '明天开会'),
            GroupChatHistoryEntry(sender: 'Bob', text: '今天休息'),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(CupertinoSearchTextField), '开会');
    await tester.pump();
    expect(find.text('明天开会'), findsOneWidget);
    expect(find.text('今天休息'), findsNothing);
  });

  testWidgets('mute exposes only the approved nested settings when enabled',
      (tester) async {
    final gateway = FakeGroupChatInfoGateway();
    final controller = GroupChatInfoController(gateway);
    await tester.pumpWidget(CupertinoApp(
      home: GroupChatInfoPage(
        controller: controller,
        onAddMember: () {},
        onSearchHistory: () {},
        onClearLocalHistory: () async {},
        onLeft: () {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('折叠该聊天'), findsNothing);
    await tester.drag(find.byType(ListView).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    final muteTile = find.ancestor(
      of: find.text('消息免打扰').first,
      matching: find.byType(WeChatListTile),
    );
    await tester.tap(find.descendant(
      of: muteTile,
      matching: find.byType(CupertinoSwitch),
    ));
    await tester.pumpAndSettle();
    expect(find.text('折叠该聊天'), findsOneWidget);
    expect(find.text('以下消息仍通知'), findsOneWidget);
  });
  test('orders owner then administrators then other members by name', () {
    final members = const [
      GroupChatMember(matrixUserId: '@zoe:test', displayName: 'Zoe'),
      GroupChatMember(matrixUserId: '@owner:test', displayName: 'Owner'),
      GroupChatMember(matrixUserId: '@adam:test', displayName: 'Adam'),
      GroupChatMember(matrixUserId: '@admin:test', displayName: 'Admin'),
    ];
    expect(
      orderGroupMembers(
        members: members,
        ownerId: '@owner:test',
        adminIds: const {'@admin:test'},
      ).map((member) => member.matrixUserId),
      ['@owner:test', '@admin:test', '@adam:test', '@zoe:test'],
    );
  });

  test('group management limits administrators to three', () {
    expect(
      normalizeGroupAdminIds(
        const ['@one:test', '@two:test', '@three:test', '@four:test'],
        ownerId: '@owner:test',
      ),
      ['@one:test', '@two:test', '@three:test'],
    );
  });
}
