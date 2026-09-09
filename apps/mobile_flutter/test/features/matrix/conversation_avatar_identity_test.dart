import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';
import 'package:flutter/painting.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/ui/foundation/avatar_cache.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_avatar_identity.dart';

class IdentityStore extends Fake implements ProfileStore {
  ProfileSnapshot? snapshot;
  @override
  Future<ProfileSnapshot?> read(String accountKey) async => snapshot;
  @override
  Future<void> write(String accountKey, ProfileSnapshot value) async {
    snapshot = value;
  }
}

void main() {
  test(
      'removing a contact avatar clears the same retained identity used by pages',
      () async {
    var url = 'https://example.test/avatar';
    final repository = ProfileRepository.forTesting(
        accountKey: 'test',
        store: IdentityStore(),
        loadProfile: () async => const ProfileData(
            username: 'owner',
            nickname: 'Owner',
            maskedEmail: '',
            fallbackSeed: 'owner'),
        loadContacts: () async => [
              ContactSummary(
                  userId: 'u1',
                  username: 'friend',
                  matrixUserId: '@friend:test',
                  avatarUrl: url.isEmpty ? null : url)
            ]);
    addTearDown(repository.dispose);
    await repository.preload();
    AvatarCache.rememberSuccessful('friend', MemoryImage(Uint8List(0)));
    url = '';
    await repository.refresh();
    expect(AvatarCache.lastSuccessful('friend'), isNull);
  });
  const friend = ContactDetails(
      userId: 'u1',
      username: 'friend',
      matrixUserId: '@friend:test',
      avatarUrl: 'https://example.test/avatar');
  test('messages reuse contact avatar and cache seed even when Matrix is stale',
      () {
    final value = conversationAvatarIdentity(
        matrixUserId: friend.matrixUserId,
        matrixAvatar: Uri.parse('mxc://test/old'),
        contact: friend);
    expect(value.seed, friend.username);
    expect(value.profileUrl, friend.avatarUrl);
    expect(value.uri.toString(), friend.avatarUrl);
  });
  test('missing Matrix avatar does not hide a known custom avatar', () {
    final value = conversationAvatarIdentity(
        matrixUserId: friend.matrixUserId, contact: friend);
    expect(value.profileUrl, friend.avatarUrl);
  });
  test('own group tile shares the profile avatar identity', () {
    const profile = ProfileData(
        username: 'owner',
        nickname: 'Owner',
        maskedEmail: '',
        fallbackSeed: 'owner-seed',
        avatarUrl: 'https://example.test/own');
    final value = conversationAvatarIdentity(
        matrixUserId: '@owner:test', ownProfile: profile);
    expect(value.seed, profile.fallbackSeed);
    expect(value.profileUrl, profile.avatarUrl);
  });
  test('explicitly removed business avatar cannot resurrect stale Matrix media',
      () {
    const removed = ContactDetails(
        userId: 'u1', username: 'friend', matrixUserId: '@friend:test');
    expect(
        conversationAvatarIdentity(
                matrixUserId: removed.matrixUserId,
                matrixAvatar: Uri.parse('mxc://test/old'),
                contact: removed)
            .uri,
        isNull);
  });
  test('unknown Matrix members retain their Matrix media and identity', () {
    final uri = Uri.parse('mxc://test/unknown');
    final value = conversationAvatarIdentity(
        matrixUserId: '@unknown:test', matrixAvatar: uri);
    expect(value.uri, uri);
    expect(value.seed, '@unknown:test');
    expect(value.profileUrl, isNull);
  });
}
