import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/chat_identity_cache.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';

void main() {
  test('hydrates the prior account avatar metadata before a network refresh',
      () async {
    final store = MemoryChatIdentityStore();
    await store.write(
      'matrix:@alice:example.test',
      ChatIdentitySnapshot(
        profile: const ProfileData(
          username: 'alice',
          nickname: 'Alice',
          maskedEmail: '',
          fallbackSeed: 'alice-seed',
          avatarUrl: 'https://cdn.example.test/alice-v2.jpg',
        ),
        contacts: const [
          ContactSummary(
            userId: 'bob-id',
            username: 'bob',
            matrixUserId: '@bob:example.test',
            nickname: 'Bob',
            avatarUrl: 'https://cdn.example.test/bob-v3.jpg',
          ),
        ],
      ),
    );

    final cache = ChatIdentityCache.forTesting(
      accountKey: 'matrix:@alice:example.test',
      store: store,
    );

    await cache.hydrate();

    expect(cache.profile?.avatarUrl, 'https://cdn.example.test/alice-v2.jpg');
    expect(
      cache.contactsByMatrixId['@bob:example.test']?.avatarUrl,
      'https://cdn.example.test/bob-v3.jpg',
    );
    expect(cache.wasHydratedFromDisk, isTrue);
  });
}

final class MemoryChatIdentityStore implements ChatIdentityStore {
  final values = <String, ChatIdentitySnapshot>{};

  @override
  Future<ChatIdentitySnapshot?> read(String accountKey) async =>
      values[accountKey];

  @override
  Future<void> write(String accountKey, ChatIdentitySnapshot snapshot) async {
    values[accountKey] = snapshot;
  }
}
