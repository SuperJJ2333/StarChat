import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_call_adapter.dart';

void main() {
  test(
      'incoming direct call accepts exact two-party membership without local m.direct metadata',
      () {
    expect(
      isVerifiedDirectParticipantSet(
        const {'@alice:example.test', '@bob:example.test'},
        localUserId: '@bob:example.test',
        remoteUserId: '@alice:example.test',
      ),
      isTrue,
    );
  });

  test('incoming direct call rejects groups and participant mismatch', () {
    expect(
      isVerifiedDirectParticipantSet(
        const {
          '@alice:example.test',
          '@bob:example.test',
          '@mallory:example.test',
        },
        localUserId: '@bob:example.test',
        remoteUserId: '@alice:example.test',
      ),
      isFalse,
    );
    expect(
      isVerifiedDirectParticipantSet(
        const {'@alice:example.test', '@mallory:example.test'},
        localUserId: '@bob:example.test',
        remoteUserId: '@alice:example.test',
      ),
      isFalse,
    );
  });

  test(
      'incoming caller is derived from exact room membership without m.direct metadata',
      () {
    expect(
      resolveIncomingRemoteParticipant(
        const {'@alice:example.test', '@bob:example.test'},
        localUserId: '@bob:example.test',
      ),
      '@alice:example.test',
    );
    expect(
      resolveIncomingRemoteParticipant(
        const {'@alice:example.test', '@bob:example.test'},
        localUserId: '@bob:example.test',
        advertisedRemoteUserId: '@mallory:example.test',
      ),
      isNull,
    );
  });
}
