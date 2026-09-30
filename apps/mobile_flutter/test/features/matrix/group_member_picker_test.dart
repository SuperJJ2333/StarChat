import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/group_member_picker.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_user_avatar.dart';
import 'package:liuhetong_mobile/features/matrix/avatar_url_resolver.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';

void main() {
  testWidgets('renders a business avatar only with an account cache scope',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: GroupMemberPicker(
        title: '选择成员',
        avatarMedia: _AvatarMedia(),
        avatarCacheKeyForMember: (_) => 'identity:matrix-alice:user-alice',
        members: [
          GroupMemberIdentity(
            matrixUserId: '@alice:test',
            displayName: 'Alice',
            businessUserId: 'user-alice',
            businessAvatarUrl: 'https://example.test/alice.png',
          ),
        ],
      ),
    ));

    expect(find.byType(UserAvatar), findsOneWidget);
    expect(find.byType(MatrixUserAvatar), findsNothing);
    final avatar = tester.widget<UserAvatar>(find.byType(UserAvatar));
    expect(avatar.avatarUrl, 'https://example.test/alice.png');
    expect(avatar.avatarCacheKey, 'identity:matrix-alice:user-alice');
  });

  testWidgets('unscoped business avatar falls back without loading its URL',
      (tester) async {
    await tester.pumpWidget(const CupertinoApp(
      home: GroupMemberPicker(
        title: '选择成员',
        members: [
          GroupMemberIdentity(
            matrixUserId: '@alice:test',
            displayName: 'Alice',
            businessUserId: 'user-alice',
            businessAvatarUrl: 'https://example.test/alice.png',
          ),
        ],
      ),
    ));

    expect(
        tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl, isNull);
  });

  testWidgets('renders an MXC avatar through MatrixUserAvatar', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: GroupMemberPicker(
        title: '选择成员',
        avatarMedia: _AvatarMedia(),
        members: [
          GroupMemberIdentity(
            matrixUserId: '@not-friend:test',
            displayName: '陌生人',
            matrixAvatarUri: Uri.parse('mxc://example.test/media'),
          ),
        ],
      ),
    ));

    expect(find.byType(MatrixUserAvatar), findsOneWidget);
  });

  testWidgets(
      'does not substitute a directory when joined-member input is empty',
      (tester) async {
    await tester.pumpWidget(const CupertinoApp(
      home: GroupMemberPicker(title: '选择成员', members: []),
    ));

    expect(find.text('群成员尚未加载，请稍后再试'), findsOneWidget);
  });
}

final class _AvatarMedia implements AvatarMediaCapability {
  @override
  Future<ResolvedAvatarUrl?> resolveAvatar({
    required Uri? avatarUri,
    required double size,
  }) async =>
      null;
}
