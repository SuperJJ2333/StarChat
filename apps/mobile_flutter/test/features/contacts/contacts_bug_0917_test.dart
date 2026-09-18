import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/permissions/blocked_contacts.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/features/contacts/request_friend_page.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';

const _contact = ContactSummary(
  userId: 'peer-id',
  username: 'bob',
  nickname: 'Bob',
  matrixUserId: '@bob:test',
);

ContactSummary _contactAt(int index) => ContactSummary(
      userId: 'user-$index',
      username: 'user$index',
      nickname: 'User $index',
      matrixUserId: '@user$index:test',
    );

/// 覆盖左侧所有字母段的通讯录数据源。
final class _Contacts implements ContactsGateway {
  _Contacts({this.blocked = const <String>[]});
  List<String> blocked;
  final blockedCalls = <String>[];
  final unblockedCalls = <String>[];
  final createdTags = <String>[];

  @override
  Future<Map<String, dynamic>> blockList() async => {
        'items': [
          for (final id in blocked) {'id': 'block-$id', 'user_id': id},
        ],
      };

  @override
  Future<void> blockContact(String userId) async {
    blockedCalls.add(userId);
    blocked = [...blocked, userId];
  }

  @override
  Future<void> unblockContact(String userId) async {
    unblockedCalls.add(userId);
    blocked = blocked.where((id) => id != userId).toList();
  }

  @override
  Future<List<ContactSummary>> listContacts() async =>
      [for (var i = 0; i < 26; i++) _contactAt(i)];

  @override
  Future<ContactSummary?> fetchFriendDetail(String userId) async => null;
  @override
  Future<Map<String, dynamic>> contactTags() async => {'items': const []};
  @override
  Future<Map<String, dynamic>> createContactTag(String name) async {
    createdTags.add(name);
    return {'id': 'tag-$name', 'name': name};
  }

  @override
  Future<Map<String, dynamic>> renameContactTag(String id, String name) async =>
      {};
  @override
  Future<void> deleteContactTag(String id) async {}
  @override
  Future<void> deleteContactTags(List<String> ids) async {}
  @override
  Future<ContactDetails> updateContactDetails(ContactDetails contact,
          {required String? remark,
          required List<String> tags,
          required String momentsPermission}) async =>
      contact;
  @override
  Future<void> deleteContact(String userId) async {}
}

final class _AddFriend implements AddFriendGateway {
  final createdTags = <String>[];
  @override
  Future<Map<String, dynamic>> contactTags() async => {
        'items': [
          {'id': 'tag-1', 'name': '同事'},
        ],
      };
  @override
  Future<Map<String, dynamic>> createContactTag(String name) async {
    createdTags.add(name);
    return {'id': 'tag-2', 'name': name};
  }

  @override
  Future<Map<String, dynamic>> searchUsers(String query) async =>
      {'items': const []};
  @override
  Future<Map<String, dynamic>> requestFriend(String userId,
          {String message = '',
          String? remark,
          List<String> tags = const [],
          String momentsPermission = 'DEFAULT'}) async =>
      {'id': 'req-1'};
}

void main() {
  setUp(() => blockedContacts.clear());

  testWidgets('BUG-09 a tag created while adding a friend is persisted',
      (tester) async {
    final api = _AddFriend();
    await tester.pumpWidget(CupertinoApp(
      home: RequestFriendPage(
        api: api,
        userId: 'peer-id',
        username: 'bob',
        nickname: 'Bob',
      ),
    ));
    await tester.pump();

    await tester.enterText(
        find.byKey(const Key('request-friend-new-tag')), '球友');
    await tester.tap(find.byKey(const Key('request-friend-add-tag')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 新建的标签必须落到服务端标签表，否则通讯录「标签」页里看不到它。
    expect(api.createdTags, ['球友']);
    expect(find.byKey(const Key('request-friend-tag-球友')), findsOneWidget);
  });

  testWidgets('BUG-09 a rejected tag creation reports an error and keeps state',
      (tester) async {
    final api = _FailingAddFriend();
    await tester.pumpWidget(CupertinoApp(
      home: RequestFriendPage(
        api: api,
        userId: 'peer-id',
        username: 'bob',
        nickname: 'Bob',
      ),
    ));
    await tester.pump();

    await tester.enterText(
        find.byKey(const Key('request-friend-new-tag')), '球友');
    await tester.tap(find.byKey(const Key('request-friend-add-tag')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 错误提示在表单底部，滚动到可见位置后再断言。
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();

    expect(find.byKey(const Key('request-friend-error')), findsOneWidget);
    expect(find.byKey(const Key('request-friend-tag-球友')), findsNothing);
  });

  testWidgets('BUG-10 the blacklist switch reflects the persisted server state',
      (tester) async {
    final api = _Contacts(blocked: const ['peer-id']);
    await tester.pumpWidget(CupertinoApp(
      home: ContactMorePage(api: api, contact: _contact.toDetails()),
    ));
    await tester.pump();
    await tester.pump();

    expect(
        tester
            .widget<CupertinoSwitch>(
                find.byKey(const Key('contact-block-switch')))
            .value,
        isTrue);
  });

  testWidgets('BUG-10 blocking and unblocking both take effect immediately',
      (tester) async {
    final api = _Contacts();
    await tester.pumpWidget(CupertinoApp(
      home: ContactMorePage(api: api, contact: _contact.toDetails()),
    ));
    await tester.pump();
    await tester.pump();

    final switchFinder = find.byKey(const Key('contact-block-switch'));
    expect(tester.widget<CupertinoSwitch>(switchFinder).value, isFalse);

    // 加入黑名单：确认框后立即生效，并同步全局投影（聊天发送门读它）。
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.blockedCalls, ['peer-id']);
    expect(tester.widget<CupertinoSwitch>(switchFinder).value, isTrue);
    expect(blockedContacts.isBlocked('peer-id'), isTrue);

    // 移出黑名单：同样是双向可用的真实操作。
    await tester.tap(switchFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.unblockedCalls, ['peer-id']);
    expect(tester.widget<CupertinoSwitch>(switchFinder).value, isFalse);
    expect(blockedContacts.isBlocked('peer-id'), isFalse);
  });

  testWidgets('BUG-03 the A-Z index keeps the design letter height and is centered',
      (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(CupertinoApp(
      home: ContactsPage(
          onOpenRoom: (_, {anchorEventId}) async {},
          pendingFriendRequests: ValueNotifier<int>(0), api: _Contacts()),
    ));
    await tester.pumpAndSettle();

    final index = find.byKey(const Key('contact-index'));
    const labels = 28; // ★ + A-Z + #
    // 字母按设计值 18pt 排布，不随屏幕高度被拉伸铺满整列。
    expect(
      tester.getSize(index).height,
      WeChatDimensions.contactIndexLetterHeight * labels,
    );
    // 整块垂直居中：上下留白不小于呼吸间距，索引不会顶到导航栏/底栏。
    final indexBox = tester.getRect(index);
    final listBox = tester.getRect(find.byType(ListView).first);
    expect(indexBox.top - listBox.top,
        greaterThanOrEqualTo(WeChatDimensions.contactIndexLetterHeight));
    expect(listBox.bottom - indexBox.bottom,
        greaterThanOrEqualTo(WeChatDimensions.contactIndexLetterHeight));
  });
}

final class _FailingAddFriend implements AddFriendGateway {
  @override
  Future<Map<String, dynamic>> contactTags() async => {'items': const []};
  @override
  Future<Map<String, dynamic>> createContactTag(String name) async =>
      throw StateError('offline');
  @override
  Future<Map<String, dynamic>> searchUsers(String query) async =>
      {'items': const []};
  @override
  Future<Map<String, dynamic>> requestFriend(String userId,
          {String message = '',
          String? remark,
          List<String> tags = const [],
          String momentsPermission = 'DEFAULT'}) async =>
      {'id': 'req-1'};
}
