import 'package:flutter/cupertino.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/contact_profile_sections.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_tile.dart';

void main() {
  testWidgets('Moments author uses the same avatar cache identity as contacts',
      (tester) async {
    final item = MomentItem.fromJson({
      'id': 'post',
      'text': 'Synthetic',
      'created_at': '2026-09-09T00:00:00Z',
      'author': {
        'user_id': 'business-id',
        'username': 'friend',
        'nickname': 'Friend'
      },
    });
    const contact = ContactSummary(
        userId: 'business-id',
        username: 'friend',
        matrixUserId: '@friend:test',
        nickname: 'Friend');
    final cache = ProfileRepository.forTesting(
        accountKey: 'matrix:@viewer:test',
        store: _Store(),
        loadContacts: () async => [contact],
        loadProfile: () async => const ProfileData(
            username: 'viewer',
            nickname: 'Viewer',
            maskedEmail: '',
            fallbackSeed: 'viewer'));
    addTearDown(cache.dispose);
    await cache.preload();
    await tester.pumpWidget(CupertinoApp(
        home: Column(children: [
      WeChatMomentTile(item: item, identityCache: cache),
      FriendIdentityCard(contact: contact.toDetails(), identityCache: cache)
    ])));
    final avatars =
        tester.widgetList<UserAvatar>(find.byType(UserAvatar)).toList();
    expect(avatars, hasLength(2));
    final accountScopedKey =
        cache.resolveIdentity(userId: contact.userId).cacheKey;
    expect(avatars.map((avatar) => avatar.fallbackSeed),
        everyElement(accountScopedKey),
        reason:
            'Feed and friend card must share the account-scoped cache identity');
    expect(accountScopedKey, isNot('friend'),
        reason:
            'A bare username must not retain another account’s avatar override');
    await tester.pumpWidget(const SizedBox());
  });
}

class _Store implements ProfileStore {
  @override
  Future<ProfileSnapshot?> read(String key) async => null;
  @override
  Future<void> write(String key, ProfileSnapshot snapshot) async {}
}
