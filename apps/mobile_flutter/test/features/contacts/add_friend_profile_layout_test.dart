import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/add_friend_profile_page.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/contact_profile_sections.dart';
import 'package:liuhetong_mobile/features/contacts/request_friend_page.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'add_friend_search_test.dart' show FakeAddFriendGateway;

void main() {
  testWidgets('user profile visual fixture', (tester) async {
    final output = Platform.environment['PROFILE_UI_CAPTURE'];
    if (output == null) return;
    await tester.runAsync(() async {
      final font = FontLoader('Fixture');
      font.addFont(Future.value(ByteData.sublistView(
          File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync())));
      await font.load();
    });
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(CupertinoApp(
        theme: const CupertinoThemeData(
            brightness: Brightness.light,
            textTheme: CupertinoTextThemeData(
                navTitleTextStyle: TextStyle(
                    fontFamily: 'Fixture',
                    fontSize: 17,
                    color: CupertinoColors.black),
                actionTextStyle: TextStyle(fontFamily: 'Fixture', fontSize: 17),
                textStyle: TextStyle(
                    fontFamily: 'Fixture',
                    fontSize: 17,
                    color: CupertinoColors.black))),
        home: RepaintBoundary(
            key: const Key('profile-capture'),
            child: AddFriendProfilePage(
                api: FakeAddFriendGateway(),
                userId: 'fixture-alice',
                username: 'alice',
                nickname: '艾莉丝',
                relationshipState: 'NONE'))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('profile-capture')));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(output).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
        'user profile matches friend header bounds at 320px scale $scale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget host(Widget child) => CupertinoApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: child);
      await tester.pumpWidget(host(const CupertinoPageScaffold(
          child: SafeArea(
              child: FriendIdentityCard(
                  contact: ContactDetails(
                      userId: 'alice',
                      username: 'alice_long_account_name',
                      matrixUserId: '@alice:test',
                      nickname: '艾莉丝的长昵称'))))));
      final friendAvatar = tester.getRect(find.byType(UserAvatar));
      final friendName = tester.getRect(find.text('艾莉丝的长昵称'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(host(AddFriendProfilePage(
          api: FakeAddFriendGateway(),
          userId: 'alice',
          username: 'alice_long_account_name',
          nickname: '艾莉丝的长昵称',
          relationshipState: 'NONE')));
      final avatar = tester.getRect(find.byType(UserAvatar));
      final name = tester.getRect(find.text('艾莉丝的长昵称'));
      expect(avatar.size, const Size(72, 72));
      expect(avatar.left, friendAvatar.left);
      expect(name.left, friendName.left);
      expect(name.left, greaterThan(avatar.right));
      expect(tester.takeException(), isNull);
      final action =
          tester.getRect(find.byKey(const Key('add-friend-profile-add')));
      final label = tester.getRect(find.text('添加到通讯录'));
      expect(action.contains(label.topLeft), isTrue);
      expect(action.contains(label.bottomRight), isTrue);
    });
  }
  testWidgets(
      'eligible profile has one action and opens request form without sending',
      (tester) async {
    final gateway = FakeAddFriendGateway();
    await tester.pumpWidget(CupertinoApp(
        home: AddFriendProfilePage(
            api: gateway,
            userId: 'alice',
            username: 'alice',
            nickname: '艾莉丝',
            relationshipState: 'NONE')));
    expect(find.byType(CupertinoButton), findsOneWidget);
    expect(find.text('发消息'), findsNothing);
    expect(find.text('语音通话'), findsNothing);
    expect(find.text('视频通话'), findsNothing);
    await tester.tap(find.byKey(const Key('add-friend-profile-add')));
    await tester.pumpAndSettle();
    expect(find.byType(RequestFriendPage), findsOneWidget);
    expect(gateway.requestedUserIds, isEmpty);
  });
  for (final state in [
    'SELF',
    'FRIEND',
    'OUTGOING_PENDING',
    'INCOMING_PENDING'
  ]) {
    testWidgets('$state cannot request friendship', (tester) async {
      final gateway = FakeAddFriendGateway();
      await tester.pumpWidget(CupertinoApp(
          home: AddFriendProfilePage(
              api: gateway,
              userId: 'alice',
              username: 'alice',
              nickname: '艾莉丝',
              relationshipState: state)));
      expect(find.text('添加到通讯录'), findsNothing);
      expect(
          tester
              .widget<CupertinoButton>(
                  find.byKey(const Key('add-friend-profile-add')))
              .onPressed,
          isNull);
      expect(gateway.requestedUserIds, isEmpty);
    });
  }
}
