import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_controller.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_page.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';

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
      GroupChatPreference.attention => snapshot.copyWith(attention: value),
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
  test('blank explicit group names display as unnamed', () {
    expect(groupInfoDisplayName(''), '未命名');
    expect(groupInfoDisplayName('   '), '未命名');
    expect(groupInfoDisplayName(' 项目群 '), '项目群');
  });

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
      '消息通知',
      '置顶聊天',
      '保存到通讯录',
      '清空聊天记录',
      '退出群聊',
    ];
    // 三态通知组件比旧的免打扰开关更高，首屏少容纳一项（PRD §44）。
    for (final label in orderedLabels.take(6)) {
      expect(find.text(label), findsOneWidget);
    }
    final visibleTops = orderedLabels
        .take(6)
        .map((label) => tester.getTopLeft(find.text(label)).dy)
        .toList(growable: false);
    expect(visibleTops, orderedEquals(visibleTops.toList()..sort()));
    await tester.drag(find.byType(ListView).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    for (final label in orderedLabels.skip(6)) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('group info and QR show unnamed for a blank explicit name',
      (tester) async {
    final gateway = FakeGroupChatInfoGateway();
    gateway.snapshot = gateway.snapshot.copyWith(name: '');
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
    expect(find.text('未命名'), findsOneWidget);

    await tester.pumpWidget(
      CupertinoApp(home: GroupQrCodePage(snapshot: gateway.snapshot)),
    );
    await tester.pump();
    expect(find.text('未命名'), findsOneWidget);
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
      CupertinoApp(
        home: GroupChatHistorySearchPage(
          entries: [
            GroupChatHistoryEntry(
              sender: 'Alice',
              text: '明天开会',
              timestamp: DateTime(2026, 8, 23),
            ),
            GroupChatHistoryEntry(
              sender: 'Bob',
              text: '今天休息',
              timestamp: DateTime(2026, 8, 22),
            ),
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
    // 拖动后确保三态组件完全进入视口再点击（PRD §44）。
    await tester.ensureVisible(find.text('静音').first);
    await tester.pumpAndSettle();
    // PRD §44：三态切换为"静音"后展开静音专属设置。
    await tester.tap(find.text('静音').first);
    await tester.pumpAndSettle();
    expect(gateway.snapshot.muted, isTrue);
    expect(find.text('折叠该聊天'), findsOneWidget);
    expect(find.text('以下消息仍通知'), findsOneWidget);

    // 切回"默认"收回静音专属设置；"特别关注"互斥静音（PRD §44）。
    await tester.ensureVisible(find.text('特别关注').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('特别关注').first);
    await tester.pumpAndSettle();
    expect(gateway.snapshot.attention, isTrue);
    expect(gateway.snapshot.muted, isFalse);
    expect(find.text('折叠该聊天'), findsNothing);
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
  test('replaces members in place and keeps owner admin ordering', () async {
    final gateway = FakeGroupChatInfoGateway();
    final controller = GroupChatInfoController(gateway);
    await controller.load();
    gateway.snapshot = gateway.snapshot.copyWith(
      ownerId: '@owner:test',
      adminIds: const ['@admin:test'],
    );
    await controller.load();
    controller.replaceMembers([
      const GroupChatMember(matrixUserId: '@zoe:test', displayName: 'Zoe'),
      const GroupChatMember(matrixUserId: '@owner:test', displayName: 'Owner'),
      const GroupChatMember(matrixUserId: '@admin:test', displayName: 'Admin'),
    ]);
    expect(controller.state.title, '聊天信息(3)');
    expect(controller.state.snapshot!.members.map((m) => m.matrixUserId), [
      '@owner:test',
      '@admin:test',
      '@zoe:test',
    ]);
  });
}
