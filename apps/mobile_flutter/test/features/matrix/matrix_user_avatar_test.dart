import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/avatar_url_resolver.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_user_avatar.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:matrix/matrix.dart';

void main() {
  testWidgets('late avatar resolution cannot replace the current generation',
      (tester) async {
    final first = Completer<ResolvedAvatarUrl?>();
    final second = Completer<ResolvedAvatarUrl?>();
    var calls = 0;
    Future<ResolvedAvatarUrl?> resolve(
      Client client,
      Uri? uri,
      double size,
    ) =>
        ++calls == 1 ? first.future : second.future;
    final client = Client('avatar');

    await tester.pumpWidget(CupertinoApp(
      home: MatrixUserAvatar(
        client: client,
        nickname: 'Alice',
        fallbackSeed: 'alice',
        matrixAvatarUri: Uri.parse('mxc://matrix.test/old'),
        resolver: resolve,
      ),
    ));
    await tester.pumpWidget(CupertinoApp(
      home: MatrixUserAvatar(
        client: client,
        nickname: 'Alice',
        fallbackSeed: 'alice',
        matrixAvatarUri: Uri.parse('mxc://matrix.test/new'),
        resolver: resolve,
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
