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
