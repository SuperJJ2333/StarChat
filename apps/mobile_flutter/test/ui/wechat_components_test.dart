import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_message_bubble.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_unread_badge.dart';
import 'package:liuhetong_mobile/ui/chat/group_avatar_mosaic.dart';
import 'package:liuhetong_mobile/ui/finance/wechat_red_packet_card.dart';
import 'package:liuhetong_mobile/ui/components/modern_action_button.dart';
import 'package:liuhetong_mobile/ui/components/immersive_auth_scaffold.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/foundation/avatar_cache.dart';
import 'package:liuhetong_mobile/ui/components/network_status_capsule.dart';

void main() {
  testWidgets('outgoing message uses WeChat green bubble', (tester) async {
    await tester.pumpWidget(const CupertinoApp(
        home: WeChatMessageBubble(
            direction: MessageDirection.outgoing, content: Text('你好'))));
    final box = tester.widget<DecoratedBox>(find.byType(DecoratedBox).last);
    expect((box.decoration as BoxDecoration).color, const Color(0xFF95EC69));
  });
  testWidgets('message row exposes a 40px tappable avatar', (tester) async {
    var avatarTaps = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: WeChatMessageBubble(
          direction: MessageDirection.incoming,
          avatar: const UserAvatar(nickname: 'Bob', fallbackSeed: 'bob'),
          onAvatarTap: () => avatarTaps++,
          content: const Text('你好'),
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(const Key('message-avatar-slot'))),
      const Size.square(40),
    );
    await tester.tap(find.byKey(const Key('message-avatar-slot')));
    expect(avatarTaps, 1);
  });
  testWidgets('message bubble exposes long press and avatar gestures',
      (tester) async {
    var messageLongPresses = 0;
    var avatarDoubleTaps = 0;
    var avatarLongPresses = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: WeChatMessageBubble(
          direction: MessageDirection.incoming,
          avatar: const UserAvatar(nickname: 'Bob', fallbackSeed: 'bob'),
          onLongPress: () => messageLongPresses++,
          onAvatarDoubleTap: () => avatarDoubleTaps++,
          onAvatarLongPress: () => avatarLongPresses++,
          content: const Text('你好'),
        ),
      ),
    );

    await tester.longPress(find.text('你好'));
    await tester.tap(find.byKey(const Key('message-avatar-slot')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('message-avatar-slot')));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const Key('message-avatar-slot')));

    expect(messageLongPresses, 1);
    expect(avatarDoubleTaps, 1);
    expect(avatarLongPresses, 1);
  });
  testWidgets('unread badge caps its label at 99+', (tester) async {
    await tester
        .pumpWidget(const CupertinoApp(home: WeChatUnreadBadge(count: 100)));
    expect(find.text('99+'), findsOneWidget);
  });
  testWidgets('expired red packet displays its authoritative visual state',
      (tester) async {
    await tester.pumpWidget(const CupertinoApp(
        home: WeChatRedPacketCard(
            greeting: '恭喜发财', state: RedPacketVisualState.expired)));
    expect(find.text('已过期'), findsOneWidget);
  });
  testWidgets(
      'modern action button is white bordered icon text with a 44dp target',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: Center(
            child: ModernActionButton(
                icon: CupertinoIcons.person_add,
                label: '添加好友',
                onPressed: () {}))));
    final container = tester.widget<Container>(find.byType(Container).last);
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.color, CupertinoColors.white);
    expect(decoration.border!.top.width, 1);
    expect(tester.getSize(find.byType(ModernActionButton)).height,
        greaterThanOrEqualTo(44));
    expect(find.byIcon(CupertinoIcons.person_add), findsOneWidget);
    expect(find.text('添加好友'), findsOneWidget);
  });
  testWidgets('danger action uses semantic red and reduced motion never scales',
      (tester) async {
    await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: CupertinoApp(
            home: Center(
                child: ModernActionButton(
                    icon: CupertinoIcons.delete,
                    label: '删除',
                    kind: ModernActionKind.danger,
                    onPressed: () {})))));
    final text = tester.widget<Text>(find.text('删除'));
    expect(text.style!.color, CupertinoColors.systemRed);
    await tester.press(find.byType(ModernActionButton));
    await tester.pump();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
  });
  testWidgets(
      'immersive auth scaffold keeps landing background separate from form',
      (tester) async {
    await tester.pumpWidget(
        const CupertinoApp(home: ImmersiveAuthScaffold(child: Text('表单'))));
    final image = tester.widget<Image>(find.byType(Image).first);
    expect((image.image as AssetImage).assetName, 'assets/landing.png');
    expect(image.fit, BoxFit.cover);
    expect(find.text('表单'), findsOneWidget);
  });
  testWidgets('user avatar falls back to a stable initial', (tester) async {
    await tester.pumpWidget(const CupertinoApp(
        home: UserAvatar(nickname: 'Alice', fallbackSeed: 'seed', size: 48)));
    expect(find.text('A'), findsOneWidget);
  });
  test('avatar cache key is user/version/size-specific with fixed retention',
      () {
    expect(
      AvatarCache.cacheKey(
        userId: '@alice:example.com',
        avatarUrl: 'https://cdn.example.com/avatar.png?v=9',
        size: 48,
      ),
      'avatar-@alice:example.com-v=9-48',
    );
    expect(AvatarCache.diskTtl, const Duration(days: 30));
    expect(AvatarCache.maximumMemoryEntries, 200);
  });
  test(
      'avatar provider does not request disk resizing from a standard cache manager',
      () {
    final provider = AvatarCache.buildProvider(
      avatarUrl: 'https://cdn.example.com/avatar.png?v=9',
      cacheKey: 'avatar-@alice:example.com-v=9-48',
    );

    expect(provider.maxWidth, isNull);
    expect(provider.maxHeight, isNull);
  });
  test('avatar cache retains the last successful provider per account', () {
    final provider = AvatarCache.buildProvider(
      avatarUrl: 'https://cdn.example.com/avatar.png?v=10',
      cacheKey: 'avatar-@alice:example.com-v=10-48',
    );

    AvatarCache.rememberSuccessful('@alice:example.com', provider);

    expect(AvatarCache.lastSuccessful('@alice:example.com'), same(provider));
  });
  testWidgets('remote user avatar uses the unified cached image provider',
      (tester) async {
    await tester.pumpWidget(const CupertinoApp(
      home: UserAvatar(
        nickname: 'Alice',
        fallbackSeed: '@alice:example.com',
        avatarUrl: 'https://cdn.example.com/avatar.png?v=9',
        size: 48,
      ),
    ));

    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.image, isA<AvatarCacheImageProvider>());
    expect(image.frameBuilder, isNotNull);
  });
  testWidgets(
      'group mosaic keeps a default avatar tile for members without a remote image',
      (tester) async {
    await tester.pumpWidget(const CupertinoApp(
      home: GroupAvatarMosaic(
        avatars: [
          UserAvatar(
            nickname: '已设置',
            fallbackSeed: 'uploaded',
            avatarUrl: 'https://cdn.example.test/avatar.png',
          ),
          UserAvatar(nickname: '默认', fallbackSeed: 'default'),
        ],
      ),
    ));

    expect(find.byKey(const Key('group-avatar-member-0')), findsOneWidget);
    expect(find.byKey(const Key('group-avatar-member-1')), findsOneWidget);
    expect(find.text('默'), findsOneWidget);
  });
  testWidgets('network capsule is compact and invokes retry', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
        CupertinoApp(home: NetworkStatusCapsule(onRetry: () => retries++)));
    expect(find.text('网络不可用，点击重试'), findsOneWidget);
    await tester.tap(find.byType(NetworkStatusCapsule));
    expect(retries, 1);
  });
}
