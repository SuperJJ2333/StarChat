import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/support_identity_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const identity = SupportIdentity(
      queryId: 'support-1',
      userId: 'support-1',
      matrixUserId: '@support:example.test',
      badge: '官方客服',
      role: SupportRole.supportAgent);

  test('stale badges remain during refresh and unchanged data does not notify',
      () async {
    final gateway = _DelayedGateway();
    final repository = SupportIdentityRepository(gateway, ttl: Duration.zero);
    final first = repository.warm(['support-1']);
    await Future<void>.delayed(Duration.zero);
    gateway.responses[0].complete([identity]);
    await first;
    var notifications = 0;
    repository.addListener(() => notifications++);
    final refresh = repository.warm(['support-1']);
    await Future<void>.delayed(Duration.zero);
    expect(repository.badgeFor(userId: 'support-1'), '官方客服');
    gateway.responses[1].complete([identity]);
    await refresh;
    expect(notifications, 0);
  });

  test('same-turn warms batch and overlapping calls share in-flight work',
      () async {
    final gateway = _DelayedGateway();
    final repository = SupportIdentityRepository(gateway);
    final a = repository.warm(['support-1']);
    final b = repository.warm(['support-1', 'other']);
    await Future<void>.delayed(Duration.zero);
    expect(gateway.requests, [
      ['support-1', 'other']
    ]);
    final duplicate = repository.warm(['support-1']);
    gateway.responses.single.complete([identity]);
    await Future.wait([a, b, duplicate]);
    expect(gateway.requests.length, 1);
  });

  test('independent concurrent requests do not invalidate each other',
      () async {
    final gateway = _DelayedGateway();
    final repository = SupportIdentityRepository(gateway);
    final a = repository.warm(['support-1']);
    await Future<void>.delayed(Duration.zero);
    final b = repository.warm(['other']);
    await Future<void>.delayed(Duration.zero);
    gateway.responses[1].complete([]);
    await b;
    gateway.responses[0].complete([identity]);
    await a;
    expect(repository.badgeFor(userId: 'support-1'), '官方客服');
  });

  test(
      'disk cache survives restart and offline lookup but never crosses account',
      () async {
    SharedPreferences.setMockInitialValues({});
    const store = PreferencesSupportIdentitySnapshotStore();
    final first = SupportIdentityRepository(
        _Gateway(responses: [
          [identity]
        ]),
        scope: () async => 'account-a',
        store: store);
    await first.warm(['support-1']);
    first.dispose();
    final restored = SupportIdentityRepository(_Gateway(responses: [null]),
        scope: () async => 'account-a', store: store);
    await restored.warm(['support-1']);
    expect(restored.badgeFor(userId: 'support-1'), '官方客服');
    final other = SupportIdentityRepository(_Gateway(responses: [null]),
        scope: () async => 'account-b', store: store);
    await other.warm(['support-1']);
    expect(other.badgeFor(userId: 'support-1'), isNull);
    restored.clear();
    await Future<void>.delayed(Duration.zero);
    expect(await store.read('account-a'), isEmpty);
  });

  test('clear prevents in-flight result from restoring old account badge',
      () async {
    final gateway = _DelayedGateway();
    final repository = SupportIdentityRepository(gateway);
    final pending = repository.warm(['support-1']);
    await Future<void>.delayed(Duration.zero);
    repository.clear();
    gateway.responses.single.complete([identity]);
    await pending;
    expect(repository.badgeFor(userId: 'support-1'), isNull);
  });

  test('explicit USER response revokes every alias and persisted badge',
      () async {
    SharedPreferences.setMockInitialValues({});
    const store = PreferencesSupportIdentitySnapshotStore();
    final repository = SupportIdentityRepository(
        _Gateway(responses: [
          [identity],
          [
            const SupportIdentity(
                queryId: 'support-1',
                userId: 'support-1',
                matrixUserId: null,
                badge: '官方客服',
                role: SupportRole.user)
          ]
        ]),
        scope: () async => 'account-a',
        store: store);
    await repository.warm(['support-1']);
    await repository.warm(['support-1'], force: true);
    expect(repository.badgeFor(matrixUserId: '@support:example.test'), isNull);
    expect(await store.read('account-a'), isEmpty);
  });

  test('foreground refresh discovers role changes without expiry clearing',
      () async {
    final gateway = _Gateway(responses: [
      [identity],
      []
    ]);
    final repository = SupportIdentityRepository(gateway);
    await repository.warm(['support-1']);
    await repository.refreshKnown();
    expect(repository.badgeFor(userId: 'support-1'), isNull);
    expect(gateway.requests.length, 2);
  });

  test('logout before first hydration deletes the account snapshot', () async {
    SharedPreferences.setMockInitialValues({});
    const store = PreferencesSupportIdentitySnapshotStore();
    await store.write('account-a', [identity]);
    final repository = SupportIdentityRepository(_Gateway(responses: [null]),
        scope: () async => 'account-a', store: store);
    repository.clear();
    await repository.warm(['support-1']);
    expect(repository.badgeFor(userId: 'support-1'), isNull);
    expect(await store.read('account-a'), isEmpty);
  });

  test('missing account during startup is retried after identity binding',
      () async {
    String? scope;
    final gateway = _Gateway(responses: [
      [identity]
    ]);
    final repository =
        SupportIdentityRepository(gateway, scope: () async => scope);
    await repository.warm(['support-1']);
    expect(gateway.requests, isEmpty);
    scope = 'account-a';
    await repository.warm(['support-1']);
    expect(repository.badgeFor(userId: 'support-1'), '官方客服');
  });

  test('late canonical alias response cannot undo a newer USER revocation',
      () async {
    final gateway = _DelayedGateway();
    final repository = SupportIdentityRepository(gateway);
    final older = repository.warm(['support-1']);
    await Future<void>.delayed(Duration.zero);
    final newer = repository.warm(['@support:example.test']);
    await Future<void>.delayed(Duration.zero);
    gateway.responses[1].complete([
      const SupportIdentity(
          queryId: '@support:example.test',
          userId: 'support-1',
          matrixUserId: '@support:example.test',
          badge: null,
          role: SupportRole.user)
    ]);
    await newer;
    gateway.responses[0].complete([identity]);
    await older;
    expect(repository.badgeFor(userId: 'support-1'), isNull);
    expect(repository.badgeFor(matrixUserId: '@support:example.test'), isNull);
  });

  test('late canonical alias response cannot undo a newer empty lookup',
      () async {
    final gateway = _DelayedGateway();
    final repository = SupportIdentityRepository(gateway);
    final older = repository.warm(['support-1']);
    await Future<void>.delayed(Duration.zero);
    final newer = repository.warm(['@support:example.test']);
    await Future<void>.delayed(Duration.zero);
    gateway.responses[1].complete([]);
    await newer;
    gateway.responses[0].complete([identity]);
    await older;
    expect(repository.badgeFor(userId: 'support-1'), isNull);
    expect(repository.badgeFor(matrixUserId: '@support:example.test'), isNull);
  });

  test(
      'unavailable secure storage is best effort and later scope recovery retries',
      () async {
    var unavailable = true;
    final gateway = _Gateway(responses: [
      [identity]
    ]);
    final repository = SupportIdentityRepository(gateway, scope: () async {
      if (unavailable) throw StateError('secure storage unavailable');
      return 'account-a';
    });
    await repository.warm(['support-1']);
    expect(gateway.requests, isEmpty);
    unavailable = false;
    await repository.warm(['support-1']);
    expect(repository.badgeFor(userId: 'support-1'), '官方客服');
  });

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

  test('a failed refresh retains the last verified display badge', () async {
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

    expect(repository.badgeFor(userId: 'support-1'), '官方客服');
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
          queryId: 'user-200',
          userId: 'user-200',
          matrixUserId: null,
          badge: '官方客服',
          role: SupportRole.supportAgent,
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

final class _DelayedGateway implements SupportIdentityGateway {
  final requests = <List<String>>[];
  final responses = <Completer<List<SupportIdentity>>>[];
  @override
  Future<List<SupportIdentity>> lookupSupportIdentities(List<String> ids) {
    requests.add(ids);
    final result = Completer<List<SupportIdentity>>();
    responses.add(result);
    return result.future;
  }
}
