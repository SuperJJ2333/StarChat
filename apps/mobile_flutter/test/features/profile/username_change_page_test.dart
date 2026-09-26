import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/username_gateway.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/profile/username_change_page.dart';
import 'profile_controller_test.dart' show FakeAvatarSource, FakeProfileGateway;

final class UsernameFixture implements UsernameGateway {
  @override
  int sessionEpoch = 1;
  var policy = const UsernameChangePolicy(username: 'alice1', canChange: true);
  int keyCount = 0, writes = 0;
  bool failFirstWrite = false, holdAvailability = false;
  final queries = <String>[];
  final keys = <String>[];
  final answers = <String, Completer<bool>>{};
  @override
  String newIdempotencyKey() => 'key-${++keyCount}';
  @override
  Future<UsernameChangePolicy> loadUsernameChangePolicy() async => policy;
  @override
  Future<bool> usernameAvailable(String username) {
    queries.add(username);
    return holdAvailability
        ? (answers[username] = Completer<bool>()).future
        : Future.value(true);
  }

  @override
  Future<UsernameChangeReceipt> changeUsername(String username,
      {required String idempotencyKey}) async {
    keys.add(idempotencyKey);
    writes++;
    if (failFirstWrite && writes == 1) throw StateError('unknown response');
    return UsernameChangeReceipt(username: username, changed: true);
  }
}

void main() {
  Future<ProfileController> show(
      WidgetTester tester, UsernameFixture gateway) async {
    final controller = ProfileController(
        gateway: FakeProfileGateway(), avatarSource: FakeAvatarSource());
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(CupertinoApp(
        home: CupertinoPageScaffold(
            child: Builder(
                builder: (context) => CupertinoButton(
                    child: const Text('open'),
                    onPressed: () => Navigator.push(
                        context,
                        CupertinoPageRoute(
                            builder: (_) => UsernameChangePage(
                                gateway: gateway,
                                controller: controller))))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets(
      'authoritative current username replaces stale profile before editing',
      (tester) async {
    final gateway = UsernameFixture()
      ..policy =
          const UsernameChangePolicy(username: 'server-name', canChange: false);
    final controller = await show(tester, gateway);
    expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField))
            .controller!
            .text,
        'server-name');
    expect(controller.state.profile!.username, 'server-name');
    expect(controller.state.profile!.fallbackSeed, 'seed');
  });
  testWidgets('invalid format does not query availability', (tester) async {
    final gateway = UsernameFixture();
    await show(tester, gateway);
    for (final value in ['short', '123456', 'Alice 名', 'Älice-x']) {
      await tester.enterText(find.byType(CupertinoTextField), value);
      await tester.pump(const Duration(milliseconds: 400));
      expect(gateway.queries, isEmpty);
    }
  });
  testWidgets('older availability result cannot replace latest draft result',
      (tester) async {
    final gateway = UsernameFixture()..holdAvailability = true;
    await show(tester, gateway);
    await tester.enterText(find.byType(CupertinoTextField), 'First-Name');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(CupertinoTextField), 'Second-Name');
    await tester.pump(const Duration(milliseconds: 400));
    gateway.answers['Second-Name']!.complete(true);
    await tester.pump();
    gateway.answers['First-Name']!.complete(false);
    await tester.pump();
    expect(find.text('该畅聊号可以使用'), findsOneWidget);
    expect(find.text('该畅聊号已被使用，请换一个'), findsNothing);
  });
  testWidgets(
      'retry after unknown write response reuses key and preserves draft',
      (tester) async {
    final gateway = UsernameFixture()..failFirstWrite = true;
    final controller = await show(tester, gateway);
    await tester.enterText(find.byType(CupertinoTextField), 'Alice-New');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('修改失败，请重试'), findsOneWidget);
    expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField))
            .controller!
            .text,
        'Alice-New');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(gateway.keys, ['key-1', 'key-1']);
    expect(controller.state.profile!.username, 'Alice-New');
    expect(controller.state.profile!.fallbackSeed, 'seed');
  });
}
