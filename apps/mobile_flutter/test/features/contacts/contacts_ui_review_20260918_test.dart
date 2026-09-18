import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/features/contacts/friend_request_review_page.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';
import 'package:liuhetong_mobile/ui/theme/wechat_theme.dart';

/// 2026-09-18 UI 评审（用户四项要求）：
/// 1. 好友列表背景色 + 好友之间的渐隐分割线（低于朋友圈实心分割线，两端渐隐）；
/// 2. 通讯录顶部入口「新的朋友 / 群聊 / 标签」文字与 icon 垂直/水平对齐；
/// 3. 「新的朋友」请求行昵称与招呼内容都与头像对齐；
/// 4. 「通过朋友验证」页「打开聊天」有品牌底色、「已添加」有醒目文字背景。
void main() {
  testWidgets('需求2 通讯录入口行文字与 icon 垂直居中且与好友行同一水平网格',
      (tester) async {
    await _pumpContacts(tester);

    for (final entry in const [
      ('新的朋友', CupertinoIcons.person_add_solid),
      ('群聊', CupertinoIcons.person_3_fill),
      ('标签', CupertinoIcons.tag_fill),
    ]) {
      final label = tester.getRect(find.text(entry.$1));
      final icon = tester.getRect(find.byIcon(entry.$2));
      expect(
        (label.center.dy - icon.center.dy).abs(),
        lessThan(1),
        reason: '${entry.$1} 文案必须与 icon 垂直居中（实测差值 '
            '${(label.center.dy - icon.center.dy).abs().toStringAsFixed(1)}dp）',
      );
      expect(label.left, greaterThan(icon.right),
          reason: '${entry.$1} 文案必须排在 icon 右侧');
    }

    // 同一水平网格：入口行文案左边界 == 好友行昵称左边界。
    expect(
      tester.getRect(find.text('新的朋友')).left,
      tester.getRect(find.text('Amy')).left,
      reason: '入口行与好友行必须共用同一水平网格',
    );
  });

  testWidgets('需求1 好友列表使用 surfaceElevated 背景色并按组画渐隐分割线',
      (tester) async {
    await _pumpContacts(tester);

    final surfaces = find.byKey(const Key('wechat-contact-elevated-surface'));
    expect(surfaces, findsNWidgets(3), reason: '每个好友行都要有自己的背景色');
    for (final surface in tester.widgetList<ColoredBox>(surfaces)) {
      expect(surface.color, WeChatColors.lightElevated);
    }

    // A 组内 3 位好友 → 好友之间 2 条分割线；组末不画（分组标题已分隔）。
    expect(find.byKey(const Key('wechat-contact-divider')), findsNWidgets(2));
    // 三个入口行同样使用共享渐隐分割线（与好友行全局统一）。
    expect(find.byKey(const Key('wechat-list-divider')), findsNWidgets(3));

    final decoration = _dividerDecoration(
        tester, find.byKey(const Key('wechat-contact-divider')).first);
    final gradient = decoration.gradient! as LinearGradient;
    expect(gradient.begin, Alignment.centerLeft);
    expect(gradient.end, Alignment.centerRight);
    expect(gradient.stops, const [0.0, 0.18, 0.82, 1.0]);
    // 两端完全透明；中部不透明度低于朋友圈实心分割线（1.0）。
    expect(gradient.colors.first.a, 0);
    expect(gradient.colors.last.a, 0);
    expect(gradient.colors[1].a, 0.5);
    expect(gradient.colors[1].a, lessThan(1));
    // 渐变色源仍是 divider token（浅色 #D9D9D9）。
    expect(gradient.colors[1].r, closeTo(217 / 255, 0.01));
    expect(gradient.colors[1].g, closeTo(217 / 255, 0.01));
    expect(gradient.colors[1].b, closeTo(217 / 255, 0.01));
  });

  testWidgets('需求1 深色下好友行取 darkElevated 且分割线使用深色 token',
      (tester) async {
    await _pumpContacts(tester, brightness: Brightness.dark);

    for (final surface in tester.widgetList<ColoredBox>(
        find.byKey(const Key('wechat-contact-elevated-surface')))) {
      expect(surface.color, WeChatColors.darkElevated);
    }
    final gradient = _dividerDecoration(
            tester, find.byKey(const Key('wechat-contact-divider')).first)
        .gradient! as LinearGradient;
    expect(gradient.colors.first.a, 0);
    expect(gradient.colors.last.a, 0);
    expect(gradient.colors[1].a, 0.5);
    expect(gradient.colors[1].r, closeTo(44 / 255, 0.01));
    expect(gradient.colors[1].g, closeTo(44 / 255, 0.01));
    expect(gradient.colors[1].b, closeTo(44 / 255, 0.01));
  });

  testWidgets('需求3 新的朋友请求行昵称与招呼内容都与头像垂直对齐', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.light),
      home: FriendRequestsPage(
        api: await _api(requests: [_incomingRequest]),
        pendingRequests: ValueNotifier<int>(0),
      ),
    ));
    await tester.pumpAndSettle();

    final nickname = tester.getRect(find.text('Bob'));
    final greeting = tester.getRect(find.text('我是Bob，很高兴认识你'));
    final avatar = tester.getRect(find.byType(UserAvatar).first);

    // 头像按设计尺寸渲染（此前被 28dp 的 leading 盒子压扁）。
    expect(avatar.width, WeChatDimensions.contactAvatar);
    expect(avatar.height, WeChatDimensions.contactAvatar);

    // 两行文案贴合头像垂直居中：行距不能被行高撑满到两端贴边。
    expect(
      greeting.top - nickname.bottom,
      lessThanOrEqualTo(8),
      reason: '昵称与招呼内容之间的行距被撑开为 '
          '${(greeting.top - nickname.bottom).toStringAsFixed(1)}dp',
    );
    expect(
      (nickname.top + greeting.bottom) / 2,
      closeTo(avatar.center.dy, 1.5),
      reason: '两行文案的整体垂直中心必须与头像中心对齐',
    );
    expect(nickname.left, greaterThan(avatar.right));
  });

  testWidgets('需求4 通过朋友验证页打开聊天有品牌底色，已添加有醒目文字背景',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.light),
      home: FriendRequestReviewPage(
        request: {..._incomingRequest, 'status': 'ACCEPTED'},
        onAccept: () async {},
        onReject: () async {},
        onOpenAccepted: () async {},
      ),
    ));
    await tester.pumpAndSettle();

    final openChat = tester.widget<CupertinoButton>(find
        .ancestor(
            of: find.text('打开聊天'),
            matching: find.byType(CupertinoButton))
        .first);
    expect(openChat.color, WeChatColors.brandPrimary,
        reason: '「打开聊天」必须按 UI_DESIGN.md 使用品牌填充色');

    final status = tester.widget<Container>(
        find.byKey(const Key('friend-request-status')));
    final background = (status.decoration! as BoxDecoration).color!;
    expect(background.a, greaterThan(0.05),
        reason: '「已添加」必须有可见的文字背景色');
    expect(background, WeChatColors.brandTint);

    final label = tester.widget<Text>(find.text('已添加'));
    expect(label.style!.color, WeChatColors.brandPrimary);
    expect(label.style!.fontWeight, FontWeight.w600);
  });
}

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

final _incomingRequest = <String, dynamic>{
  'id': 'req-1',
  'user_id': 'bob',
  'username': 'bob',
  'nickname': 'Bob',
  'avatar_url': null,
  'matrix_user_id': '@bob:test',
  'message': '我是Bob，很高兴认识你',
  'status': 'PENDING',
  'direction': 'INCOMING',
  'requested_at': '2026-09-18T00:00:00+00:00',
};

Map<String, dynamic> _friend(String id, String nickname) => {
      'user_id': id,
      'username': id,
      'nickname': nickname,
      'matrix_user_id': '@$id:test',
      'avatar_url': null,
      'tags': const <String>[],
      'starred': false,
    };

/// A 组 3 位好友，保证「好友之间」的分割线数量可精确断言。
List<Map<String, dynamic>> _contacts() =>
    [_friend('amy', 'Amy'), _friend('ann', 'Ann'), _friend('ava', 'Ava')];

Future<void> _pumpContacts(WidgetTester tester,
    {Brightness brightness = Brightness.light}) async {
  tester.view.physicalSize = const Size(393, 852);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final pending = ValueNotifier<int>(0);
  addTearDown(pending.dispose);
  await tester.pumpWidget(CupertinoApp(
    theme: WeChatTheme.build(brightness),
    home: ContactsPage(
      api: await _api(contacts: _contacts()),
      onOpenRoom: (_, {anchorEventId}) async {},
      pendingFriendRequests: pending,
    ),
  ));
  await tester.pumpAndSettle();
}

BoxDecoration _dividerDecoration(WidgetTester tester, Finder divider) =>
    tester
        .widget<DecoratedBox>(find.descendant(
            of: divider, matching: find.byType(DecoratedBox)))
        .decoration as BoxDecoration;

Future<BusinessApiClient> _api({
  List<Map<String, dynamic>>? contacts,
  List<Map<String, dynamic>>? requests,
}) async {
  final store = SecureSessionStore(_MemoryStore());
  await store.saveSession(accessToken: 'a', refreshToken: 'r');
  return BusinessApiClient(
    baseUri: Uri.parse('https://business.example'),
    sessionStore: store,
    client: MockClient((request) async {
      final path = request.url.path;
      final body = path.endsWith('/friends/requests')
          ? <String, dynamic>{'items': requests ?? const []}
          : path.endsWith('/friends')
              ? <String, dynamic>{'items': contacts ?? const []}
              : <String, dynamic>{'items': const []};
      return http.Response(jsonEncode(body), 200, headers: _jsonHeaders);
    }),
  );
}

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
