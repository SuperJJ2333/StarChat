import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';

final class FakeAddFriendGateway implements AddFriendGateway {
  FakeAddFriendGateway({this.results = const []});
  List<Map<String, dynamic>> results;
  final queries = <String>[];
  final requestedUserIds = <String>[];

  @override
  Future<Map<String, dynamic>> searchUsers(String query) async {
    queries.add(query);
    return {'items': results};
  }

  @override
  Future<Map<String, dynamic>> contactTags() async => {'items': []};

  @override
  Future<Map<String, dynamic>> requestFriend(String userId,
      {String message = '',
      String? remark,
      List<String> tags = const [],
      String momentsPermission = 'DEFAULT'}) async {
    requestedUserIds.add(userId);
    return {'id': 'req-1', 'status': 'PENDING'};
  }
}

Map<String, dynamic> _user(String id, String username, String nickname) => {
      'user_id': id,
      'username': username,
      'nickname': nickname,
      'avatar_url': null,
      'matrix_user_id': '@$id:test',
      'relationship_state': 'NONE',
    };

Future<void> _pumpPage(
    WidgetTester tester, FakeAddFriendGateway gateway) async {
  await tester.pumpWidget(CupertinoApp(home: AddFriendPage(api: gateway)));
  await tester.pump();
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(CupertinoSearchTextField), text);
  // 越过 300ms 防抖窗口。
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('queries shorter than two characters never hit the gateway',
      (tester) async {
    final gateway = FakeAddFriendGateway();
    await _pumpPage(tester, gateway);

    await _type(tester, 'a');

    expect(gateway.queries, isEmpty);
    expect(find.byKey(const Key('add-friend-hint')), findsOneWidget);
    expect(find.textContaining('至少 2 个字符'), findsOneWidget);
  });

  testWidgets('debounced search renders avatar, nickname and 畅聊号',
      (tester) async {
    final gateway = FakeAddFriendGateway(results: [
      _user('u-alice', 'alice', '艾莉丝'),
    ]);
    await _pumpPage(tester, gateway);

    await _type(tester, 'alice');

    expect(gateway.queries, ['alice']);
    expect(find.byKey(const Key('add-friend-u-alice')), findsOneWidget);
    expect(find.text('艾莉丝'), findsOneWidget);
    expect(find.text('畅聊号：alice'), findsOneWidget);
  });

  testWidgets('empty results show the not-found hint', (tester) async {
    final gateway = FakeAddFriendGateway(results: []);
    await _pumpPage(tester, gateway);

    await _type(tester, 'nobody');

    expect(find.text('未找到匹配的用户'), findsOneWidget);
  });

  testWidgets('BUG 2：搜索行不再提供快捷发送；点击行进入用户资料页', (tester) async {
    final gateway = FakeAddFriendGateway(results: [
      _user('u-alice', 'alice', '艾莉丝'),
    ]);
    await _pumpPage(tester, gateway);

    await _type(tester, 'alice');

    // 快捷添加按钮已移除：行上只有状态文字，点击不直接发请求。
    expect(find.text('添加'), findsOneWidget);
    await tester.tap(find.byKey(const Key('add-friend-u-alice')));
    await tester.pumpAndSettle();
    expect(gateway.requestedUserIds, isEmpty, reason: '点击行/状态不再直接发送好友请求');

    // 点击行进入用户资料页（BUG 2：资料 → 添加到通讯录 → 申请页）。
    expect(find.text('用户资料'), findsOneWidget);
    expect(find.text('艾莉丝'), findsOneWidget);
    expect(find.text('添加到通讯录'), findsOneWidget);
    final actionRect = tester.getRect(find.byKey(const Key('add-friend-profile-add')));
    final labelRect = tester.getRect(find.text('添加到通讯录'));
    expect((actionRect.center - labelRect.center).distance, lessThan(2));
    expect(actionRect.contains(labelRect.bottomRight), isTrue);
  });
}
