import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/foundation/avatar_cache.dart';

void main() {
  testWidgets(
      'late frame callback cannot retain previous account image under new identity',
      (tester) async {
    Widget build(String identity) => CupertinoApp(
        home: UserAvatar(
            nickname: identity,
            fallbackSeed: identity,
            avatarUrl: 'https://safe/$identity'));
    await tester.pumpWidget(build('late-old-account'));
    final oldImage = tester.widget<Image>(find.byType(Image));
    final context = tester.element(find.byType(Image));
    await tester.pumpWidget(build('late-new-account'));
    oldImage.frameBuilder!(context, const SizedBox(), 0, true);
    expect(AvatarCache.lastSuccessful('late-new-account'), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('explicit absent avatar does not resurrect retained custom image',
      (tester) async {
    AvatarCache.rememberSuccessful(
        'removed-user',
        MemoryImage(base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')));
    await tester.pumpWidget(const CupertinoApp(
        home: UserAvatar(
      nickname: '用户',
      fallbackSeed: 'removed-user',
      avatarUrl: null,
    )));
    expect(find.byType(Image), findsNothing);
    expect(find.text('用'), findsOneWidget);
  });
}
