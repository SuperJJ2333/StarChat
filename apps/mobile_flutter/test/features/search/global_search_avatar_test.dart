import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/avatar_url_resolver.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_user_avatar.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/search/global_search_avatar.dart';
import 'package:liuhetong_mobile/features/search/global_search_models.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';

final class _UnavailableAvatarMedia implements AvatarMediaCapability {
  final requested = <Uri?>[];

  @override
  Future<ResolvedAvatarUrl?> resolveAvatar({
    required Uri? avatarUri,
    required double size,
  }) async {
    requested.add(avatarUri);
    return null;
  }
}

final class _MemoryProfileStore implements ProfileStore {
  ProfileSnapshot? value;

  @override
  Future<ProfileSnapshot?> read(String accountKey) async => value;

  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {
    value = snapshot;
  }
}

void main() {
  testWidgets('direct avatar uses current account identity and stable fallback',
      (tester) async {
    final cache = ProfileRepository.forTesting(
      accountKey: 'matrix:@owner:test',
      store: _MemoryProfileStore(),
    );
    final media = _UnavailableAvatarMedia();
    final room = GlobalSearchRoomResult(
      roomId: '!direct:test',
      displayName: '好友',
      isDirect: true,
      directPeerId: '@friend:test',
      matrixAvatarUri: Uri.parse('mxc://test/old-peer'),
    );
    await tester.pumpWidget(CupertinoApp(
      home: Center(
        child: SearchRoomAvatar(
          room: room,
          avatarMedia: media,
          identityCache: cache,
          size: 40,
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('好'), findsOneWidget);
    expect(tester.getSize(find.byType(SearchRoomAvatar)), const Size(40, 40));
    expect(
      tester
          .widget<MatrixUserAvatar>(find.byType(MatrixUserAvatar))
          .matrixAvatarUri,
      Uri.parse('mxc://test/old-peer'),
    );

    await cache.applyUpdatedContact(const ContactSummary(
      userId: 'friend',
      username: 'friend',
      matrixUserId: '@friend:test',
      nickname: '新昵称',
      avatarUrl: 'https://cdn.test/current-avatar.png',
    ));
    await tester.pump();
    final updated =
        tester.widget<MatrixUserAvatar>(find.byType(MatrixUserAvatar));
    expect(updated.matrixAvatarUri, isNull);
    expect(updated.fallbackAvatarUrl, 'https://cdn.test/current-avatar.png');
    expect(updated.fallbackSeed, startsWith('identity:'));
    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl,
        'https://cdn.test/current-avatar.png');
    expect(media.requested, contains(Uri.parse('mxc://test/old-peer')));

    await tester.pumpWidget(const SizedBox());
    cache.dispose();
  });

  testWidgets('missing media and members keep a 40dp local fallback',
      (tester) async {
    await tester.pumpWidget(const CupertinoApp(
      home: Center(
        child: SearchRoomAvatar(
          room: GlobalSearchRoomResult(
            roomId: '!empty:test',
            displayName: '空群',
            isDirect: false,
          ),
          size: 40,
        ),
      ),
    ));
    expect(find.byType(UserAvatar), findsOneWidget);
    expect(tester.getSize(find.byType(SearchRoomAvatar)), const Size(40, 40));
    expect(find.text('空'), findsOneWidget);
  });

  testWidgets('direct room without a peer ID keeps its own fallback seed',
      (tester) async {
    final cache = ProfileRepository.forTesting(
      accountKey: 'matrix:@owner:test',
      store: _MemoryProfileStore(),
    );
    await tester.pumpWidget(CupertinoApp(
      home: Center(
        child: SearchRoomAvatar(
          room: const GlobalSearchRoomResult(
            roomId: '!unresolved:test',
            displayName: '待解析会话',
            isDirect: true,
          ),
          identityCache: cache,
          size: 40,
        ),
      ),
    ));
    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).fallbackSeed,
        '!unresolved:test');
    await tester.pumpWidget(const SizedBox());
    cache.dispose();
  });
}
