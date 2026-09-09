import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/avatar_url_resolver.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_user_avatar.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';

final class FakeAvatarMediaCapability implements AvatarMediaCapability {
  FakeAvatarMediaCapability(this.resolve);

  final Future<ResolvedAvatarUrl?> Function(Uri? uri, double size) resolve;

  @override
  Future<ResolvedAvatarUrl?> resolveAvatar({
    required Uri? avatarUri,
    required double size,
  }) =>
      resolve(avatarUri, size);
}

void main() {
  testWidgets('same user retains avatar during a non-null URI refresh',
      (tester) async {
    final pending = Completer<ResolvedAvatarUrl?>();
    final avatars = FakeAvatarMediaCapability((uri, _) async =>
        uri?.path == '/old'
            ? const ResolvedAvatarUrl('https://safe/old')
            : pending.future);
    Widget build(String version) => CupertinoApp(
            home: MatrixUserAvatar(
          avatarMedia: avatars,
          nickname: '用户',
          fallbackSeed: 'account:user',
          matrixAvatarUri: Uri.parse('mxc://matrix.test/$version'),
        ));
    await tester.pumpWidget(build('old'));
    await tester.pump();
    await tester.pumpWidget(build('new'));
    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl,
        'https://safe/old');
    pending.complete(const ResolvedAvatarUrl('https://safe/new'));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl,
        'https://safe/new');
  });
  testWidgets('reused avatar never retains another user during resolution',
      (tester) async {
    final pending = Completer<ResolvedAvatarUrl?>();
    final avatars = FakeAvatarMediaCapability((uri, _) async =>
        uri?.path == '/alice'
            ? const ResolvedAvatarUrl('https://safe/alice')
            : pending.future);
    Widget build(String user) => CupertinoApp(
            home: MatrixUserAvatar(
          avatarMedia: avatars,
          nickname: user,
          fallbackSeed: user,
          matrixAvatarUri: Uri.parse('mxc://matrix.test/$user'),
        ));
    await tester.pumpWidget(build('alice'));
    await tester.pump();
    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl,
        'https://safe/alice');
    await tester.pumpWidget(build('bob'));
    expect(
        tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl, isNull);
    pending.complete(null);
    await tester.pump();
  });

  testWidgets('late avatar resolution cannot replace the current generation',
      (tester) async {
    final first = Completer<ResolvedAvatarUrl?>();
    final second = Completer<ResolvedAvatarUrl?>();
    var calls = 0;
    Future<ResolvedAvatarUrl?> resolve(Uri? uri, double size) =>
        ++calls == 1 ? first.future : second.future;
    final avatars = FakeAvatarMediaCapability(resolve);

    await tester.pumpWidget(CupertinoApp(
      home: MatrixUserAvatar(
        avatarMedia: avatars,
        nickname: 'Alice',
        fallbackSeed: 'alice',
        matrixAvatarUri: Uri.parse('mxc://matrix.test/old'),
      ),
    ));
    await tester.pumpWidget(CupertinoApp(
      home: MatrixUserAvatar(
        avatarMedia: avatars,
        nickname: 'Alice',
        fallbackSeed: 'alice',
        matrixAvatarUri: Uri.parse('mxc://matrix.test/new'),
      ),
    ));

    second.complete(const ResolvedAvatarUrl('https://safe/new'));
    await tester.pump();
    first.complete(const ResolvedAvatarUrl('https://safe/old'));
    await tester.pump();

    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl,
        'https://safe/new');
  });
}
