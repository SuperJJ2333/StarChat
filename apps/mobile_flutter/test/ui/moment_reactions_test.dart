import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_tile.dart';

MomentItem post({bool liked = false}) => MomentItem.fromJson({
      'id': 'post',
      'text': 'Body',
      'created_at': '2026-09-09T00:00:00Z',
      'author': {'user_id': 'owner', 'nickname': 'Owner'},
      'viewer_has_liked': liked,
      'like_users': [
        {'user_id': 'friend', 'nickname': 'Friend'}
      ],
      'comments': [
        {
          'id': 'one',
          'text': 'First comment',
          'author': {'user_id': 'self', 'nickname': 'Me'},
          'created_at': '2026-09-08T10:00:00Z'
        },
        {
          'id': 'two',
          'text': 'Reply text',
          'author': {'user_id': 'friend', 'nickname': 'Friend'},
          'parent_author': {'user_id': 'self', 'nickname': 'Me'}
        },
      ],
    });

void main() {
  testWidgets('reactions group has rounded dark panel, avatars and dividers',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(home: WeChatMomentTile(item: post())));
    expect(find.byKey(const Key('moment-reactions')), findsOneWidget);
    expect(find.byType(UserAvatar), findsNWidgets(4));
    expect(find.byKey(const Key('moment-likes-divider')), findsOneWidget);
    expect(find.byKey(const Key('moment-comment-divider-two')), findsOneWidget);
    final box = tester
        .widget<Container>(find.byKey(const Key('moment-reactions')))
        .decoration! as BoxDecoration;
    expect(box.color, const Color(0xff333333));
    expect(box.borderRadius, isNotNull);
  });
  testWidgets(
      'comment profile targets, selection and time survive narrow large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final people = <String>[];
    final comments = <String>[];
    await tester.pumpWidget(CupertinoApp(
        home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: SingleChildScrollView(
                child: WeChatMomentTile(
                    item: post(),
                    detailMode: true,
                    selectedCommentId: 'one',
                    onPersonTap: (person) => people.add(person.userId),
                    onCommentTap: (comment) => comments.add(comment.id))))));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('moment-comment-name-one')));
    await tester.tap(find.byKey(const Key('moment-comment-avatar-one')));
    await tester.tap(find.byKey(const Key('moment-comment-parent-two')));
    await tester.tap(find.byKey(const Key('moment-liker-friend')));
    expect(people, ['self', 'self', 'self', 'friend']);
    expect(comments, isEmpty);
    await tester.tap(find.text('First comment'));
    expect(comments, ['one']);
    final selected = tester
        .widget<Container>(find.byKey(const Key('moment-comment-surface-one')));
    expect(selected.color, const Color(0xff292929));
    expect(selected.padding, const EdgeInsets.all(14));
    expect(find.byKey(const Key('moment-comment-time-one')), findsOneWidget);
    expect(find.byKey(const Key('moment-comment-time-two')), findsNothing);
  });

  testWidgets(
      'like feedback animates only a new like and respects reduced motion',
      (tester) async {
    Future<void> show(bool liked, {bool reduced = false}) =>
        tester.pumpWidget(CupertinoApp(
            home: MediaQuery(
                data: MediaQueryData(disableAnimations: reduced),
                child: WeChatMomentTile(item: post(liked: liked)))));
    double scale() => tester
        .widget<Transform>(find.byKey(const Key('moment-like-scale')))
        .transform
        .storage[0];
    await show(true);
    expect(scale(), 1);
    await show(false);
    await show(true);
    await tester.pump(const Duration(milliseconds: 120));
    expect(scale(), greaterThan(1));
    await tester.pump(const Duration(milliseconds: 580));
    expect(scale(), 1);
    await show(false);
    await show(true, reduced: true);
    await tester.pump(const Duration(milliseconds: 120));
    expect(scale(), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
  testWidgets('feed and detail visual fixture', (tester) async {
    final output = Platform.environment['MOMENT_UI_CAPTURE'];
    if (output == null) return;
    await tester.runAsync(() async {
      final font = FontLoader('Fixture');
      font.addFont(Future.value(ByteData.sublistView(
          File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync())));
      await font.load();
      final icons = FontLoader('packages/cupertino_icons/CupertinoIcons');
      icons.addFont(rootBundle
          .load('packages/cupertino_icons/assets/CupertinoIcons.ttf'));
      await icons.load();
    });
    tester.view.physicalSize = const Size(780, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(CupertinoApp(
        theme: const CupertinoThemeData(
            brightness: Brightness.dark,
            textTheme: CupertinoTextThemeData(
                textStyle: TextStyle(
                    fontFamily: 'Fixture',
                    color: Color(0xffeeeeee),
                    fontSize: 15))),
        home: RepaintBoundary(
            key: const Key('capture'),
            child: ColoredBox(
                color: const Color(0xff202020),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                          child: Column(children: [
                        const SizedBox(height: 30),
                        const Text('Feed'),
                        const SizedBox(height: 16),
                        WeChatMomentTile(item: post())
                      ])),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(children: [
                        const SizedBox(height: 30),
                        const Text('Detail'),
                        const SizedBox(height: 16),
                        WeChatMomentTile(
                            item: post(),
                            detailMode: true,
                            selectedCommentId: 'one')
                      ])),
                    ])))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boundary = tester
        .renderObject<RenderRepaintBoundary>(find.byKey(const Key('capture')));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(output).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  });
}
