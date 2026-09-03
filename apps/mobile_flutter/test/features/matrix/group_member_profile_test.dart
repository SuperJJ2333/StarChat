import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/add_friend_profile_page.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_controller.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';

/// BUG 2：群成员点击分流——非好友也必须能进"用户资料"页发起
/// 添加到通讯录；好友进"好友资料"页；自己不可点。
void main() {
  ContactDetails friendContact() => const ContactDetails(
        userId: 'u-friend',
        username: 'friend',
        nickname: '好友甲',
        matrixUserId: '@friend:example.test',
      );

  Widget host({required Future<void> Function() tap}) => CupertinoApp(
        home: Center(
          child: CupertinoButton(
            key: const Key('trigger'),
            onPressed: tap,
            child: const Text('tap'),
          ),
        ),
      );

  testWidgets('非好友群成员 → 反查后进入用户资料页，添加按钮可用', (tester) async {
    await tester.pumpWidget(
      host(
        tap: () => openGroupMemberProfile(
          tester.element(find.byKey(const Key('trigger'))),
          api: _FakeAddFriendGateway(),
          lookupByMatrixId: (mxid) async => {
            'user_id': 'u-stranger',
            'username': 'stranger88',
            'nickname': '陌生群员',
            'matrix_user_id': mxid,
            'relationship_state': 'NONE',
          },
          member: const GroupChatMember(
            matrixUserId: '@stranger:example.test',
            displayName: '群昵称',
          ),
          selfMatrixUserId: '@me:example.test',
          friendContact: null,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();

    expect(find.byType(AddFriendProfilePage), findsOneWidget);
    expect(find.text('用户资料'), findsOneWidget);
    expect(find.text('畅聊号：stranger88'), findsOneWidget);
    final addButton = find.byKey(const Key('add-friend-profile-add'));
    expect(addButton, findsOneWidget);
    expect(
      tester.widget<CupertinoButton>(addButton).onPressed,
      isNotNull,
      reason: 'NONE 状态必须可发起添加',
    );
  });

  testWidgets('好友群成员 → 打开好友资料页，不做反查', (tester) async {
    var lookups = 0;
    var openedFriend = false;
    await tester.pumpWidget(
      host(
        tap: () => openGroupMemberProfile(
          tester.element(find.byKey(const Key('trigger'))),
          api: _FakeAddFriendGateway(),
          lookupByMatrixId: (mxid) async {
            lookups++;
            return {};
          },
          member: const GroupChatMember(
            matrixUserId: '@friend:example.test',
            displayName: '好友甲',
          ),
          selfMatrixUserId: '@me:example.test',
          friendContact: friendContact(),
          onOpenFriendContact: (_) => openedFriend = true,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();

    expect(openedFriend, isTrue);
    expect(lookups, 0, reason: '好友不需要反查接口');
  });

  testWidgets('自己不可点击（无导航、无反查）', (tester) async {
    var lookups = 0;
    await tester.pumpWidget(
      host(
        tap: () => openGroupMemberProfile(
          tester.element(find.byKey(const Key('trigger'))),
          api: _FakeAddFriendGateway(),
          lookupByMatrixId: (mxid) async {
            lookups++;
            return {};
          },
          member: const GroupChatMember(
            matrixUserId: '@me:example.test',
            displayName: '我',
          ),
          selfMatrixUserId: '@me:example.test',
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();

    expect(lookups, 0);
    expect(find.byType(AddFriendProfilePage), findsNothing);
  });

  testWidgets('反查失败（不存在/拉黑）→ 提示对话框，不进入资料页', (tester) async {
    await tester.pumpWidget(
      host(
        tap: () => openGroupMemberProfile(
          tester.element(find.byKey(const Key('trigger'))),
          api: _FakeAddFriendGateway(),
          lookupByMatrixId: (mxid) async => throw StateError('404'),
          member: const GroupChatMember(
            matrixUserId: '@ghost:example.test',
            displayName: '幽灵',
          ),
          selfMatrixUserId: '@me:example.test',
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();

    expect(find.byType(AddFriendProfilePage), findsNothing);
    expect(find.text('无法获取用户资料'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
  });
}

final class _FakeAddFriendGateway implements AddFriendGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
