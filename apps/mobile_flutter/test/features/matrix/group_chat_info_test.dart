import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_error.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_controller.dart';
import 'package:liuhetong_mobile/features/matrix/group_qr_code_page.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_page.dart';
import 'package:liuhetong_mobile/ui/components/wechat_list_tile.dart';

final class FakeGroupChatInfoGateway implements GroupChatInfoGateway {
  @override
  String? get roomId => '!group:example.test';

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
  Future<void> withdrawInvite(String matrixUserId) async {}

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
  test(
      'empty business timeline preserves received ownership without pending state',
      () async {
    final gateway = _OwnerGroupInfoGateway();
    final controller = GroupChatInfoController(gateway,
        loadOwnershipTransfers: () async => []);
    await controller.load();
    await controller.refreshOwnershipTransfer();
    expect(controller.state.snapshot!.isOwner, isTrue);
    expect(controller.state.status, GroupChatInfoStatus.ready);
    expect(controller.ownershipTransferPending, isFalse);
    expect(controller.ownershipTransferCompatibilityMessage, isNull);
  });

  testWidgets(
      'legacy timeline uses neutral compatibility copy with existing group management',
      (tester) async {
    final controller = GroupChatInfoController(_OwnerGroupInfoGateway(),
        loadOwnershipTransfers: () async => throw const BusinessApiException(
            statusCode: 404, code: 'HTTP_404', message: 'Not Found'));
    await controller.load();
    await tester.pumpWidget(
        CupertinoApp(home: GroupManagementPage(controller: controller)));
    expect(find.textContaining('群权限按当前群聊显示'), findsOneWidget);
    await tester.tap(find.text('群主管理权转让'));
    await tester.pumpAndSettle();
    expect(find.textContaining('群权限按当前群聊显示'), findsOneWidget);
    expect(find.text('转让状态暂未获取，请重试'), findsNothing);
    expect(find.byKey(const Key('group-transfer-status')), findsNothing);
  });
  test('legacy unsupported transfer timeline retains received Matrix ownership',
      () async {
    final gateway = _OwnerGroupInfoGateway();
    final controller = GroupChatInfoController(gateway,
        loadOwnershipTransfers: () async => throw const BusinessApiException(
            statusCode: 404, code: 'HTTP_404', message: 'Not Found'));
    await controller.load();
    await controller.refreshOwnershipTransfer();
    expect(controller.state.status, GroupChatInfoStatus.ready);
    expect(controller.state.snapshot!.isOwner, isTrue);
    expect(controller.ownershipTransfer, isNull);
    expect(controller.ownershipTransferPending, isFalse);
  });

  test('network failure remains actionable and does not invent transfer',
      () async {
    final controller = GroupChatInfoController(_OwnerGroupInfoGateway(),
        loadOwnershipTransfers: () async => throw const BusinessApiException(
            statusCode: 503,
            code: 'NETWORK_UNAVAILABLE',
            message: 'Unavailable'));
    await controller.load();
    await controller.refreshOwnershipTransfer();
    expect(controller.state.status, GroupChatInfoStatus.failed);
    expect(controller.state.message, '转让状态暂未获取，请重试');
    expect(controller.ownershipTransferPending, isFalse);
  });

  test('unsupported read cannot discard a known business pending transfer',
      () async {
    var failRead = false;
    final controller = GroupChatInfoController(_OwnerGroupInfoGateway(),
        submitOwnershipTransfer: (_) async =>
            {'transfer_id': 'intent', 'stage': 'NEEDS_REVIEW'},
        loadOwnershipTransfers: () async {
          if (failRead) {
            throw const BusinessApiException(
                statusCode: 404, code: 'HTTP_404', message: 'Not Found');
          }
          return [];
        });
    await controller.load();
    await controller.transferOwnership('@member0:example.test');
    failRead = true;
    await controller.refreshOwnershipTransfer();
    expect(controller.ownershipTransferPending, isTrue);
    expect(controller.state.snapshot!.isOwner, isTrue);
    expect(controller.state.status, GroupChatInfoStatus.failed);
  });
  test('resumed transfer uses business owner even when Matrix is promoted',
      () async {
    final gateway = _OwnerGroupInfoGateway();
    gateway.snapshot =
        gateway.snapshot.copyWith(ownerId: '@member0:example.test');
    final controller = GroupChatInfoController(gateway,
        loadOwnershipTransfers: () async => [
              {
                'id': 'intent-1',
                'stage': 'NEEDS_REVIEW',
                'expected_old_owner_matrix_id': '@owner:example.test'
              }
            ]);
    await controller.load();
    expect(controller.state.snapshot!.ownerId, '@owner:example.test');
    expect(controller.ownershipTransferPending, isTrue);
  });
  testWidgets(
      'transfer keeps neutral status on member picker and refreshes completion',
      (tester) async {
    final gateway = _OwnerGroupInfoGateway();
    var submitted = false;
    final controller = GroupChatInfoController(gateway,
        submitOwnershipTransfer: (_) async {
          submitted = true;
          return {'transfer_id': 'intent-1', 'stage': 'NEEDS_REVIEW'};
        },
        loadOwnershipTransfers: () async => submitted
            ? [
                {'id': 'intent-1', 'stage': 'COMPLETED'}
              ]
            : []);
    await controller.load();
    await tester.pumpWidget(
        CupertinoApp(home: GroupManagementPage(controller: controller)));
    await tester.tap(find.text('群主管理权转让'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('成员0'));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('转让'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('group-transfer-status')), findsOneWidget);
    expect(find.textContaining('转让待人工核对'), findsOneWidget);
    expect(controller.state.snapshot!.isOwner, isTrue);
    await tester.tap(find.text('刷新状态'));
    await tester.pumpAndSettle();
    expect(find.text('群主转让已完成'), findsOneWidget);
    expect(controller.state.snapshot!.isOwner, isFalse);
    expect(gateway.transferredTo, isNull);
  });
  test('transfer without coordinator does not write Matrix or change owner',
      () async {
    final gateway = _OwnerGroupInfoGateway();
    final controller = GroupChatInfoController(gateway);
    await controller.load();
    await controller.transferOwnership('@member0:example.test');
    expect(gateway.transferredTo, isNull);
    expect(controller.state.snapshot!.ownerId, '@owner:example.test');
    expect(controller.state.message, contains('暂不可用'));
  });
  test('BUG-29 群主退出前先把群主转移给最早加入的其他成员', () async {
    final gateway = _OwnerGroupInfoGateway();
    String? submitted;
    final controller =
        GroupChatInfoController(gateway, submitOwnershipTransfer: (id) async {
      submitted = id;
      return {'stage': 'COMPLETED'};
    });
    await controller.load();

    final left = await controller.leave();

    expect(left, isTrue);
    expect(submitted, '@member0:example.test',
        reason: '群主退出必须先把群主转移给最早加入的其他成员');
    expect(gateway.transferredTo, isNull);
    expect(gateway.left, isTrue, reason: '转移成功后才执行退出');
  });

  for (final stage in [
    'VALIDATED',
    'MATRIX_PENDING',
    'MATRIX_APPLIED',
    'NEEDS_REVIEW'
  ]) {
    test('backend $stage keeps owner and blocks leaving until completed',
        () async {
      final gateway = _OwnerGroupInfoGateway();
      final controller = GroupChatInfoController(gateway,
          submitOwnershipTransfer: (_) async =>
              {'transfer_id': 'intent-1', 'stage': stage},
          loadOwnershipTransfers: () async => [
                {'id': 'intent-1', 'stage': 'COMPLETED'}
              ]);
      await controller.load();
      await controller.transferOwnership('@member0:example.test');
      expect(controller.state.snapshot!.ownerId, '@owner:example.test');
      gateway.snapshot =
          gateway.snapshot.copyWith(ownerId: '@member0:example.test');
      await controller.load();
      expect(controller.state.snapshot!.ownerId, '@owner:example.test',
          reason:
              'Matrix promotion cannot confirm business transfer completion');
      expect(await controller.leave(), isFalse);
      expect(gateway.left, isFalse);
      expect(gateway.transferredTo, isNull);
      await controller.refreshOwnershipTransfer();
      expect(controller.state.snapshot!.ownerId, '@member0:example.test');
    });
  }

  test('BUG-29 非群主退出不转移', () async {
    final gateway = _OwnerGroupInfoGateway();
    gateway.snapshot = GroupChatInfoSnapshot(
      name: '项目讨论组',
      members: gateway.snapshot.members,
      ownerId: '@owner:example.test',
      currentUserId: '@someone:example.test',
    );
    final controller = GroupChatInfoController(gateway);
    await controller.load();

    await controller.leave();

    expect(gateway.transferredTo, isNull, reason: '非群主退出不得转移群主');
    expect(gateway.left, isTrue);
  });

  test('BUG-29 群内只剩群主一人时退出不转移', () async {
    final gateway = _OwnerGroupInfoGateway();
    gateway.snapshot = GroupChatInfoSnapshot(
      name: '项目讨论组',
      members: [
        GroupChatMember(matrixUserId: '@owner:example.test', displayName: '群主'),
      ],
      ownerId: '@owner:example.test',
      currentUserId: '@owner:example.test',
    );
    final controller = GroupChatInfoController(gateway);
    await controller.load();

    await controller.leave();

    expect(gateway.transferredTo, isNull, reason: '没有其他成员时无从转移');
    expect(gateway.left, isTrue);
  });

  test('blank explicit group names display as unnamed', () {
    expect(groupInfoDisplayName(''), '未命名');
    expect(groupInfoDisplayName('   '), '未命名');
    expect(groupInfoDisplayName(' 项目群 '), '项目群');
  });

  test('group member DTO reports app-owned joined membership', () {
    const joined = GroupChatMember(
      matrixUserId: '@alice:example.test',
      displayName: 'Alice',
    );
    const invited = GroupChatMember(
      matrixUserId: '@bob:example.test',
      displayName: 'Bob',
      membership: GroupMemberMembership.invited,
    );

    expect(joined.isJoined, isTrue);
    expect(invited.isJoined, isFalse);
  });

  test('group chat info controller loads members and persists changes',
      () async {
    final gateway = FakeGroupChatInfoGateway();
    final controller = GroupChatInfoController(gateway);

    await controller.load();
    expect(controller.state.snapshot!.members, hasLength(12));
    expect(controller.state.title, '聊天信息(12)');

    await controller.rename('新群名');
    gateway.snapshot = gateway.snapshot.copyWith(
        ownerId: '@owner:example.test', currentUserId: '@owner:example.test');
    await controller.load();
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

  testWidgets('聊天信息页「清空聊天记录」文字居中', (tester) async {
    tester.view.physicalSize = const Size(393, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = GroupChatInfoController(FakeGroupChatInfoGateway());

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

    final label = find.text('清空聊天记录');
    // 行容器由共享的 WeChatListTile 提供（2026-09-18 起不再委托
    // CupertinoListTile：后者的 spaceBetween 内容列会把文案顶到行边）。
    final row = find.ancestor(of: label, matching: find.byType(WeChatListTile));
    expect(row, findsOneWidget);
    expect((tester.getCenter(label).dx - tester.getCenter(row).dx).abs(),
        lessThan(1.0),
        reason: '「清空聊天记录」文字必须相对所在行居中，而非左对齐');
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
      CupertinoApp(
          home: GroupQrCodePage(snapshot: gateway.snapshot, api: null)),
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
          onInvite: (matrixUserId, businessUserId) async =>
              invited.add(matrixUserId),
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
    await tester.ensureVisible(find.text('消息通知'));
    await tester.tap(find.text('消息通知'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('静音').first);
    await tester.pumpAndSettle();
    // PRD §44：三态切换为"静音"后展开静音专属设置。
    await tester
        .ensureVisible(find.byKey(const Key('notification-mode-muted')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('notification-mode-muted')));
    await tester.pumpAndSettle();
    expect(gateway.snapshot.muted, isTrue);
    expect(find.text('折叠该聊天'), findsOneWidget);
    expect(find.text('以下消息仍通知'), findsOneWidget);

    // 新行为：静音后保持展开，直接切"特别关注"（互斥静音，收起子项）。
    await tester
        .ensureVisible(find.byKey(const Key('notification-mode-attention')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('notification-mode-attention')));
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

  test('group member DTO retains only immutable avatar display data', () {
    const member = GroupChatMember(
      matrixUserId: '@alice:test',
      displayName: 'Alice',
      avatarUrl: 'https://media.example.test/alice.png',
      avatarHeaders: {'authorization': 'Bearer redacted'},
    );

    expect(member.avatarUrl, 'https://media.example.test/alice.png');
    expect(member.avatarHeaders, {'authorization': 'Bearer redacted'});
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

final class _OwnerGroupInfoGateway extends FakeGroupChatInfoGateway
    implements GroupOwnershipGateway {
  _OwnerGroupInfoGateway() {
    // 当前用户 = 群主；成员列表不含群主本人（按加入顺序）。
    snapshot = GroupChatInfoSnapshot(
      name: '项目讨论组',
      members: [
        for (var i = 0; i < 4; i++)
          GroupChatMember(
              matrixUserId: '@member$i:example.test', displayName: '成员$i'),
      ],
      ownerId: '@owner:example.test',
      currentUserId: '@owner:example.test',
    );
  }

  @override
  Future<void> transferOwnership(String userId) {
    transferredTo = userId;
    return Future<void>.value();
  }

  @override
  Future<void> dissolve() async {}

  String? transferredTo;
}
