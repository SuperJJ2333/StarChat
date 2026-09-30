import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/ui/components/wechat_list_tile.dart';

final class FakeAddFriendGateway implements AddFriendGateway {
  FakeAddFriendGateway({this.results = const []});
  List<Map<String, dynamic>> results;
  final queries = <String>[];
  final requestedUserIds = <String>[];

  /// 置为非 null 时下一次搜索抛错（模拟断网/服务端失败）。
  Object? failure;
  Future<Map<String, dynamic>> Function(String query)? search;

  @override
  Future<Map<String, dynamic>> searchUsers(String query) async {
    queries.add(query);
    if (search != null) return search!(query);
    final pending = failure;
    if (pending != null) throw pending;
    return {'items': results};
  }

  @override
  Future<Map<String, dynamic>> contactTags() async => {'items': []};

  @override
  Future<Map<String, dynamic>> createContactTag(String name) async =>
      {'id': 'tag-$name', 'name': name};

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
    final actionRect =
        tester.getRect(find.byKey(const Key('add-friend-profile-add')));
    final labelRect = tester.getRect(find.text('添加到通讯录'));
    expect((actionRect.center - labelRect.center).distance, lessThan(2));
    expect(actionRect.contains(labelRect.bottomRight), isTrue);
  });

  /// 微信级加载模型（2026-09-19 审计）：加好友搜索失败时原先把 `items` 清空，
  /// 于是屏幕上的搜索结果凭空消失，只剩一句错误提示。
  testWidgets('同一查询刷新失败保留已有行并给出提示', (tester) async {
    final gateway = FakeAddFriendGateway(results: [
      _user('u-alice', 'alice', '艾莉丝'),
    ]);
    await _pumpPage(tester, gateway);
    await _type(tester, 'alice');
    expect(find.byKey(const Key('add-friend-u-alice')), findsOneWidget);

    gateway.failure = StateError('offline');
    tester
        .widget<CupertinoSearchTextField>(find.byType(CupertinoSearchTextField))
        .onSubmitted!('alice');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('add-friend-u-alice')), findsOneWidget,
        reason: '失败不得清空上一次成功的搜索结果');
    expect(find.textContaining('搜索失败'), findsOneWidget);
  });

  testWidgets(
      'three discovery channels and complete phone guidance are visible',
      (tester) async {
    final gateway = FakeAddFriendGateway();
    await _pumpPage(tester, gateway);
    expect(
        tester
            .widget<CupertinoSearchTextField>(
                find.byType(CupertinoSearchTextField))
            .placeholder,
        '畅聊号 / 邮箱 / 手机号');
    expect(find.textContaining('邮箱或手机号'), findsOneWidget);
    await _type(tester, '138001');
    expect(gateway.queries, isEmpty);
    expect(find.textContaining('完整的 11 位手机号'), findsOneWidget);
    await _type(tester, '+86 138 0013 8000');
    expect(gateway.queries, ['+86 138 0013 8000']);
  });

  testWidgets('320 character email reaches the authoritative gateway unchanged',
      (tester) async {
    final gateway = FakeAddFriendGateway();
    await _pumpPage(tester, gateway);
    final email = '${'a' * 64}@${'b' * 251}.com';
    expect(email.length, 320);
    await _type(tester, email);
    expect(gateway.queries, [email]);
    expect(
        tester
            .widget<CupertinoSearchTextField>(
                find.byType(CupertinoSearchTextField))
            .controller!
            .text,
        email);
  });

  testWidgets('search input is bounded at the API 320 character limit',
      (tester) async {
    final gateway = FakeAddFriendGateway();
    await _pumpPage(tester, gateway);
    await _type(tester, 'a' * 321);
    expect(gateway.queries, ['a' * 320]);
  });

  testWidgets('replacing the gateway invalidates old account search responses',
      (tester) async {
    final held = Completer<Map<String, dynamic>>();
    final oldGateway = FakeAddFriendGateway()..search = (_) => held.future;
    final newGateway = FakeAddFriendGateway(results: [
      _user('u-new', 'alice', '新账号可见'),
    ]);
    await _pumpPage(tester, oldGateway);
    await tester.enterText(find.byType(CupertinoSearchTextField), 'alice');
    await tester.pump(const Duration(milliseconds: 350));
    await _pumpPage(tester, newGateway);
    await tester.pump(const Duration(milliseconds: 350));
    held.complete({
      'items': [_user('u-old', 'alice', '旧账号可见')]
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('add-friend-u-new')), findsOneWidget);
    expect(find.byKey(const Key('add-friend-u-old')), findsNothing);
  });

  testWidgets(
      'username candidates remain server-authoritative for suffix typos',
      (tester) async {
    final gateway = FakeAddFriendGateway(results: [
      _user('u-target', 'a1111123', '目标'),
    ]);
    await _pumpPage(tester, gateway);
    await _type(tester, 'a1111144');
    expect(gateway.queries, ['a1111144']);
    expect(find.byKey(const Key('add-friend-u-target')), findsOneWidget);
    gateway.results = [];
    await _type(tester, 'a111');
    expect(gateway.queries, ['a1111144', 'a111']);
    expect(find.byKey(const Key('add-friend-u-target')), findsNothing);
  });

  testWidgets('new draft immediately removes old actionable rows',
      (tester) async {
    final gateway = FakeAddFriendGateway(results: [
      _user('u-alice', 'alice', '艾莉丝'),
    ]);
    await _pumpPage(tester, gateway);
    await _type(tester, 'alice');
    await tester.enterText(find.byType(CupertinoSearchTextField), 'bob');
    await tester.pump();
    expect(find.byKey(const Key('add-friend-u-alice')), findsNothing);
    gateway.failure = StateError('offline');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('add-friend-u-alice')), findsNothing);
    expect(find.text('搜索失败，请重试'), findsOneWidget);
  });

  testWidgets(
      'an old row callback cannot open after a new draft invalidates it',
      (tester) async {
    final gateway = FakeAddFriendGateway(results: [
      _user('u-alice', 'alice', '艾莉丝'),
    ]);
    await _pumpPage(tester, gateway);
    await _type(tester, 'alice');
    final open = tester
        .widget<WeChatListTile>(find.byKey(const Key('add-friend-u-alice')))
        .onTap!;
    await tester.enterText(find.byType(CupertinoSearchTextField), 'bob');
    open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('用户资料'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late search completion cannot repopulate a cleared draft',
      (tester) async {
    final held = Completer<Map<String, dynamic>>();
    final gateway = FakeAddFriendGateway()..search = (_) => held.future;
    await _pumpPage(tester, gateway);
    await tester.enterText(find.byType(CupertinoSearchTextField), 'alice');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(find.byType(CupertinoSearchTextField), '');
    await tester.pump();
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    held.complete({
      'items': [_user('u-alice', 'alice', '艾莉丝')]
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('add-friend-u-alice')), findsNothing);
    expect(find.textContaining('至少 2 个字符'), findsOneWidget);
  });

  for (final failLate in [false, true]) {
    testWidgets(
        'late ${failLate ? 'failure' : 'success'} cannot replace a newer search',
        (tester) async {
      final first = Completer<Map<String, dynamic>>();
      final second = Completer<Map<String, dynamic>>();
      final gateway = FakeAddFriendGateway()
        ..search = (query) => query == 'alice' ? first.future : second.future;
      await _pumpPage(tester, gateway);
      await tester.enterText(find.byType(CupertinoSearchTextField), 'alice');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.enterText(find.byType(CupertinoSearchTextField), 'bob');
      await tester.pump(const Duration(milliseconds: 350));
      second.complete({
        'items': [_user('u-bob', 'bob', '鲍勃')]
      });
      await tester.pumpAndSettle();
      if (failLate) {
        first.completeError(StateError('offline'));
      } else {
        first.complete({
          'items': [_user('u-alice', 'alice', '艾莉丝')]
        });
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('add-friend-u-bob')), findsOneWidget);
      expect(find.byKey(const Key('add-friend-u-alice')), findsNothing);
      expect(find.textContaining('搜索失败'), findsNothing);
    });
  }

  testWidgets(
      'submit cancels debounce and shares an in-flight same draft request',
      (tester) async {
    final held = Completer<Map<String, dynamic>>();
    final gateway = FakeAddFriendGateway()..search = (_) => held.future;
    await _pumpPage(tester, gateway);
    await tester.enterText(find.byType(CupertinoSearchTextField), 'alice');
    final submit = tester
        .widget<CupertinoSearchTextField>(find.byType(CupertinoSearchTextField))
        .onSubmitted!;
    submit('alice');
    submit('alice');
    await tester.pump(const Duration(milliseconds: 350));
    expect(gateway.queries, ['alice']);
    held.complete({'items': []});
    await tester.pumpAndSettle();
  });
}
