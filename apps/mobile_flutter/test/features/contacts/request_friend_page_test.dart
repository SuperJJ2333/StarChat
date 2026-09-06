import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/contacts/request_friend_page.dart';

final class FakeGateway implements AddFriendGateway, ProfileGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<ProfileData> loadProfile() async => const ProfileData(
      username: 'alice',
      nickname: '艾丽',
      maskedEmail: '',
      fallbackSeed: 'alice');
  FakeAddRequestRecorder? recorder;

  @override
  Future<Map<String, dynamic>> searchUsers(String query) async => {'items': []};

  @override
  Future<Map<String, dynamic>> requestFriend(
    String userId, {
    String message = '',
    String? remark,
    List<String> tags = const [],
    String momentsPermission = 'DEFAULT',
  }) async {
    recorder?.calls.add((
      userId: userId,
      message: message,
      remark: remark,
      tags: tags,
      momentsPermission: momentsPermission,
    ));
    return {'id': 'req-1', 'status': 'PENDING', 'duplicate': false};
  }

  @override
  Future<Map<String, dynamic>> contactTags() async => {
        'items': [
          {'id': 't1', 'name': '同事'},
          {'id': 't2', 'name': '球友'},
        ],
      };
}

final class FakeAddRequestRecorder {
  final calls = <({
    String userId,
    String message,
    String? remark,
    List<String> tags,
    String momentsPermission,
  })>[];
}

/// 固定步进推进帧：加载中的网络头像会持续调度帧，pumpAndSettle 会超时。
Future<void> _settle(WidgetTester tester, [int ms = 120]) async {
  await tester.pump();
  await tester.pump(Duration(milliseconds: ms));
}

Future<void> _pump(WidgetTester tester, FakeGateway gateway) async {
  await tester.pumpWidget(CupertinoApp(
    home: RequestFriendPage(
      api: gateway,
      userId: 'u-bob',
      username: 'bob',
      nickname: '波仔',
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _scrollToSubmit(WidgetTester tester) async {
  var scrolls = 0;
  while (find.byKey(const Key('request-friend-submit')).evaluate().isEmpty &&
      scrolls < 12) {
    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await _settle(tester, 60);
    scrolls++;
  }
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  testWidgets('renders target identity, existing tags and default permission',
      (tester) async {
    final recorder = FakeAddRequestRecorder();
    final gateway = FakeGateway()..recorder = recorder;
    await _pump(tester, gateway);

    expect(find.textContaining('波仔'), findsWidgets);
    expect(find.textContaining('畅聊号：bob'), findsOneWidget);
    expect(find.byKey(const Key('request-friend-tag-同事')), findsOneWidget);
    expect(find.byKey(const Key('request-friend-tag-球友')), findsOneWidget);
    expect(find.text('不让他看我的朋友圈和状态'), findsOneWidget);

    await _scrollToSubmit(tester);
    await tester.tap(find.byKey(const Key('request-friend-submit')));
    await _settle(tester, 300);

    expect(recorder.calls, hasLength(1));
    expect(recorder.calls.single.userId, 'u-bob');
    expect(recorder.calls.single.momentsPermission, 'DEFAULT');
    expect(recorder.calls.single.message, '你好，我是alice');
  });

  testWidgets('greeting, remark, tags and permission flow into the request',
      (tester) async {
    final recorder = FakeAddRequestRecorder();
    final gateway = FakeGateway()..recorder = recorder;
    await _pump(tester, gateway);

    await tester.enterText(
        find.byKey(const Key('request-friend-greeting')), '我是小王，加个好友');
    await tester.enterText(
        find.byKey(const Key('request-friend-remark')), '项目老王');
    await tester.tap(find.byKey(const Key('request-friend-tag-球友')));
    await _settle(tester);

    var scrolls = 0;
    while (find.text('不看他的朋友圈和状态').evaluate().isEmpty && scrolls < 12) {
      await tester.drag(find.byType(ListView), const Offset(0, -160));
      await _settle(tester, 60);
      scrolls++;
    }
    await tester.tap(find.text('不看他的朋友圈和状态'));
    await _settle(tester);

    var scrolls2 = 0;
    while (find.byKey(const Key('request-friend-submit')).evaluate().isEmpty &&
        scrolls2 < 12) {
      await tester.drag(find.byType(ListView), const Offset(0, -160));
      await _settle(tester, 60);
      scrolls2++;
    }
    await tester.tap(find.byKey(const Key('request-friend-submit')));
    await _settle(tester, 300);

    final call = recorder.calls.single;
    expect(call.message, '我是小王，加个好友');
    expect(call.remark, '项目老王');
    expect(call.tags, ['球友']);
    expect(call.momentsPermission, 'HIDE_THEIRS');
    expect(find.text('申请已发送'), findsOneWidget);
  });

  testWidgets('hide switches combine and chat only is mutually exclusive',
      (tester) async {
    final recorder = FakeAddRequestRecorder();
    await _pump(tester, FakeGateway()..recorder = recorder);
    await tester.scrollUntilVisible(find.text('默认允许'), 140,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('不看他的朋友圈和状态'));
    await tester.tap(find.text('不让他看我的朋友圈和状态'));
    await tester.tap(find.text('不看他的朋友圈和状态'));
    await tester.pump();
    expect(
        tester
            .widgetList<CupertinoSwitch>(find.byType(CupertinoSwitch))
            .every((s) => s.value),
        isTrue);
    await tester.ensureVisible(find.text('仅聊天'));
    await tester.tap(find.text('仅聊天'));
    await tester.pump();
    expect(find.byType(CupertinoSwitch), findsNothing);
    await tester.tap(find.text('默认允许'));
    await tester.pump();
    await _scrollToSubmit(tester);
    await tester.ensureVisible(find.byKey(const Key('request-friend-submit')));
    await tester.tap(find.byKey(const Key('request-friend-submit')));
    await _settle(tester, 300);
    expect(recorder.calls.single.momentsPermission, 'HIDE_BOTH');
  });

  testWidgets('new tags can be created inline and selected', (tester) async {
    final recorder = FakeAddRequestRecorder();
    final gateway = FakeGateway()..recorder = recorder;
    await _pump(tester, gateway);

    await tester.enterText(
        find.byKey(const Key('request-friend-new-tag')), '客户');
    await tester.tap(find.byKey(const Key('request-friend-add-tag')));
    await _settle(tester);

    expect(find.byKey(const Key('request-friend-tag-客户')), findsOneWidget);
  });
}
