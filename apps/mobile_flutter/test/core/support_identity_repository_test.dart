import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/support_identity_repository.dart';

void main() {
  test('only a validated support role with a two-to-six-character badge shows',
      () async {
    final gateway = _Gateway(
      responses: [
        const [
          SupportIdentity(
            queryId: 'support-1',
            userId: 'support-1',
            matrixUserId: '@support:example.test',
            badge: '官方客服',
            role: SupportRole.supportAgent,
          ),
          SupportIdentity(
            queryId: 'admin-1',
            userId: 'admin-1',
            matrixUserId: '@admin:example.test',
            badge: '官方客服',
            role: SupportRole.superAdmin,
          ),
          SupportIdentity(
            queryId: 'bad-1',
            userId: 'bad-1',
            matrixUserId: '@bad:example.test',
            badge: '假',
            role: SupportRole.supportAgent,
          ),
        ],
      ],
    );
    final repository = SupportIdentityRepository(gateway);

    await repository.warm(['support-1', 'admin-1', 'bad-1']);

    expect(repository.badgeFor(userId: 'support-1'), '官方客服');
    expect(repository.badgeFor(userId: 'admin-1'), isNull);
    expect(repository.badgeFor(userId: 'bad-1'), isNull);
    expect(repository.badgeFor(displayName: '普通用户 @官方客服'), isNull);
  });

  test('warms distinct identifiers in one request and maps Matrix references',
      () async {
    final gateway = _Gateway(
      responses: [
        const [
          SupportIdentity(
            queryId: '@support:example.test',
            userId: 'support-1',
            matrixUserId: '@support:example.test',
            badge: '财务客服',
            role: SupportRole.financeSupport,
          ),
        ],
      ],
    );
    final repository = SupportIdentityRepository(gateway);

    await repository.warm(['support-1', '@support:example.test', 'support-1']);

    expect(gateway.requests, [
      ['support-1', '@support:example.test'],
    ]);
    expect(repository.badgeFor(matrixUserId: '@support:example.test'), '财务客服');
  });

  test('a failed refresh removes a previous badge instead of reusing it',
      () async {
    final gateway = _Gateway(responses: [
      const [
        SupportIdentity(
          queryId: 'support-1',
          userId: 'support-1',
          matrixUserId: '@support:example.test',
          badge: '官方客服',
          role: SupportRole.supportSupervisor,
        ),
      ],
      null,
    ]);
    final repository = SupportIdentityRepository(gateway);

    await repository.warm(['support-1']);
    expect(repository.badgeFor(userId: 'support-1'), '官方客服');
    await repository.warm(['support-1'], force: true);

    expect(repository.badgeFor(userId: 'support-1'), isNull);
  });

  test('refreshing one alias removes the cached Matrix alias on revocation',
      () async {
    final gateway = _Gateway(responses: [
      const [
        SupportIdentity(
          queryId: 'support-1',
          userId: 'support-1',
          matrixUserId: '@support:example.test',
          badge: '官方客服',
          role: SupportRole.supportAgent,
        ),
      ],
      const [],
    ]);
    final repository = SupportIdentityRepository(gateway);

    await repository.warm(['support-1']);
    expect(repository.badgeFor(matrixUserId: '@support:example.test'), '官方客服');
    await repository.warm(['support-1'], force: true);

    expect(repository.badgeFor(userId: 'support-1'), isNull);
    expect(repository.badgeFor(matrixUserId: '@support:example.test'), isNull);
  });

  test('splits more than one hundred references into bounded requests',
      () async {
    final ids = List.generate(201, (index) => 'user-$index');
    final gateway = _Gateway(responses: [
      const [],
      const [],
      const [
        SupportIdentity(
          queryId: 'user-200', userId: 'user-200', matrixUserId: null,
          badge: '官方客服', role: SupportRole.supportAgent,
        ),
      ],
    ]);
    final repository = SupportIdentityRepository(gateway);

    await repository.warm(ids);

    expect(gateway.requests.map((request) => request.length), [100, 100, 1]);
    expect(repository.badgeFor(userId: 'user-200'), '官方客服');
  });
}

final class _Gateway implements SupportIdentityGateway {
  _Gateway({required this.responses});

  final List<List<SupportIdentity>?> responses;
  final requests = <List<String>>[];

  @override
  Future<List<SupportIdentity>> lookupSupportIdentities(
      List<String> userIds) async {
    requests.add(List.unmodifiable(userIds));
    final response = responses.removeAt(0);
    if (response == null) throw StateError('offline');
    return response;
  }
}
