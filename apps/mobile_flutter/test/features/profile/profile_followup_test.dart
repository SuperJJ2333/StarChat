import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/profile/profile_page.dart';
import 'package:liuhetong_mobile/ui/components/wechat_list_tile.dart';
import 'profile_controller_test.dart' show FakeProfileGateway, FakeAvatarSource;

final class FailedSaveGateway implements ProfileGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<ProfileData> loadProfile() => FakeProfileGateway().loadProfile();
  @override
  Future<ProfileData> updateProfile(
          {String? nickname, String? signature, String? nudgeSuffix}) async =>
      throw StateError('offline');
}

void main() {
  Future<ProfileController> show(WidgetTester tester,
      {ProfileGateway? gateway}) async {
    final controller = ProfileController(
        gateway: gateway ?? FakeProfileGateway(),
        avatarSource: FakeAvatarSource());
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(
        CupertinoApp(home: ProfileDetailsPage(controller: controller)));
    return controller;
  }

  testWidgets('seven profile rows are ordered with right values and chevrons',
      (tester) async {
    await show(tester);
    const labels = ['头像', '畅聊号', '邮箱', '手机号', '昵称', '个性签名', '拍一拍'];
    double previous = -1;
    for (final label in labels) {
      final tile = find.ancestor(
          of: find.text(label), matching: find.byType(WeChatListTile));
      expect(tile, findsOneWidget, reason: label);
      expect(
          find.descendant(
              of: tile, matching: find.byType(CupertinoListTileChevron)),
          findsOneWidget);
      final y = tester.getTopLeft(tile).dy;
      expect(y, greaterThan(previous));
      previous = y;
    }
    expect(find.byType(CupertinoTextField), findsNothing);
    expect(find.text('保存'), findsNothing);
    for (final value in [
      'alice',
      'al***@example.test',
      'Alice',
      'hello',
      '拍了拍我'
    ]) {
      expect(tester.widget<Text>(find.text(value)).textAlign, TextAlign.right);
    }
  });

  testWidgets('nickname edits alone and returns saved value immediately',
      (tester) async {
    final controller = await show(tester);
    await tester.tap(find.text('昵称'));
    await tester.pumpAndSettle();
    expect(find.text('设置昵称'), findsOneWidget);
    expect(find.byType(CupertinoTextField), findsOneWidget);
    final field =
        tester.widget<CupertinoTextField>(find.byType(CupertinoTextField));
    expect(field.textAlign, TextAlign.right);
    expect(field.maxLength, isNull);
    expect(field.inputFormatters, isNotEmpty);
    await tester.enterText(find.byType(CupertinoTextField), 'New nickname');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('个人信息'), findsOneWidget);
    expect(find.text('New nickname'), findsOneWidget);
    expect(controller.state.profile!.signature, 'hello');
  });

  testWidgets(
      'failed signature save retains full draft while authority refreshes',
      (tester) async {
    final controller = await show(tester, gateway: FailedSaveGateway());
    await tester.tap(find.text('个性签名'));
    await tester.pumpAndSettle();
    expect(find.text('设置个性签名'), findsOneWidget);
    expect(find.byType(CupertinoTextField), findsOneWidget);
    final draft = List.filled(20, '👨‍👩‍👧‍👦').join();
    await tester.enterText(find.byType(CupertinoTextField), draft);
    await tester.tap(find.text('保存'));
    await tester.pump();
    await controller.load();
    await tester.pump();
    expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField))
            .controller!
            .text,
        draft);
    expect(find.textContaining(RegExp(r'\d+/\d+')), findsNothing);
    expect(find.text('资料保存失败，请重试'), findsOneWidget);
  });

  testWidgets('restoring the original after failed edit returns successfully',
      (tester) async {
    final controller = await show(tester, gateway: FailedSaveGateway());
    await tester.tap(find.text('个性签名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField), 'Changed');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(controller.state.status, ProfileStatus.failed);
    await tester.enterText(find.byType(CupertinoTextField), 'hello');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('个人信息'), findsOneWidget);
    expect(controller.state.status, ProfileStatus.ready);
    expect(controller.state.profile!.signature, 'hello');
  });
}
