import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/foundation/avatar_cache.dart';

void main() {
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
