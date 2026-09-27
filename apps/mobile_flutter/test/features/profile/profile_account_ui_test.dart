import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/profile/profile_page.dart';
import 'profile_controller_test.dart' show FakeProfileGateway, FakeAvatarSource;

class FailingProfileGateway implements ProfileGateway {
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
  testWidgets('fixed labels and editable values fit 320px with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ProfileController(
        gateway: FakeProfileGateway(), avatarSource: FakeAvatarSource());
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(CupertinoApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!),
        home: ProfileDetailsPage(controller: controller)));
    await tester.tap(find.text('个性签名'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(CupertinoTextField));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('个性签名'), findsOneWidget);
    for (final field in find.byType(CupertinoTextField).evaluate()) {
      expect(
          tester.getSize(find.byWidget(field.widget)).width, greaterThan(100));
    }
  });
  testWidgets(
      'failed signature save keeps full draft across authoritative reload',
      (tester) async {
    final controller = ProfileController(
        gateway: FailingProfileGateway(), avatarSource: FakeAvatarSource());
    addTearDown(controller.dispose);
    await controller.load();
    final original = controller.state.profile!.signature;
    await tester.pumpWidget(
        CupertinoApp(home: ProfileDetailsPage(controller: controller)));
    await tester.tap(find.text('个性签名'));
    await tester.pumpAndSettle();
    final field = find.byType(CupertinoTextField);
    final draft = List.filled(20, '👨‍👩‍👧‍👦').join();
    await tester.enterText(field, draft);
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(tester.widget<CupertinoTextField>(field).controller!.text, draft);
    expect(find.text('资料保存失败，请重试'), findsOneWidget);
    await controller.load();
    expect(controller.state.profile!.signature, original);
    expect(tester.widget<CupertinoTextField>(field).controller!.text, draft);
  });
  testWidgets(
      'profile labels remain fixed after separate editing with no counters',
      (tester) async {
    final controller = ProfileController(
        gateway: FakeProfileGateway(), avatarSource: FakeAvatarSource());
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(
        CupertinoApp(home: ProfileDetailsPage(controller: controller)));
    expect(tester.getTopLeft(find.text('畅聊号')).dy,
        lessThan(tester.getTopLeft(find.text('昵称')).dy));
    await tester.tap(find.text('昵称'));
    await tester.pumpAndSettle();
    final field = find.byType(CupertinoTextField);
    await tester.enterText(field, '');
    await tester.pump();
    expect(find.text('昵称'), findsOneWidget);
    expect(find.textContaining(RegExp(r'\d+/\d+')), findsNothing);
    await tester.enterText(field, 'new nickname');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('昵称'), findsOneWidget);
    expect(find.text('个性签名'), findsOneWidget);
    expect(controller.state.profile!.nickname, 'new nickname');
  });
}
