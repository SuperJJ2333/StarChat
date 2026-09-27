import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_error.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';
import 'package:liuhetong_mobile/features/matrix/local_identity_preflight.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_security_logger.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/session_store_test.dart' show MemorySecureKeyValueStore;
import 'matrix_client_factory_test.dart' show LogoutTrackingClient;

const _homeserverText = 'https://matrix.test';
final _homeserver = Uri.parse(_homeserverText);
const _supportDirectory = '/support';

/// 真实设备上 SQLCipher 库里的会话行。
///
/// `user_id` / `device_id` 由 SDK 的 `updateClient()` 写回磁盘，覆盖安装、杀进程
/// 重启后仍然存在；`fingerprint` 代表该库里保留的 Olm(Ed25519) 身份。
final class FakeMatrixDatabase {
  FakeMatrixDatabase({
    this.userId,
    this.deviceId,
    this.loggedIn = false,
    this.fingerprint,
  });

  String? userId;
  String? deviceId;
  String? fingerprint;
  bool loggedIn;
  bool failSync = false;

  /// 服务端在首次 `m.login.token` 登录时分配的账号与 device。
  String? nextLoginUserId;
  String? nextLoginDeviceId;
  int disposals = 0;
  int syncs = 0;
}

/// 沙盒里的加密库文件。路径由账号 scope 派生，因此 A/B 两个账号天然各自持有
/// 独立的库、独立的 SQLCipher key 与独立的 MatrixLocalBinding。
final class FakeMatrixSandbox {
  FakeMatrixSandbox({this.server});

  http.Client? server;
  final databases = <String, FakeMatrixDatabase>{};
  final openedPaths = <String>[];
  final opens = <({String path, String cipher})>[];
  final deletedPaths = <String>[];
  final ciphers = <String, String>{};

  /// 与 `MatrixClientFactory._databasePath` 完全一致的路径推导。
  static String pathForScope(String scope) => p.join(
        _supportDirectory,
        scope.isEmpty
            ? 'liuhetong_matrix.sqlite'
            : 'liuhetong_matrix_$scope.sqlite',
      );

  FakeMatrixDatabase forScope(String scope) =>
      databases.putIfAbsent(pathForScope(scope), FakeMatrixDatabase.new);

  Future<Client> open({
    required String clientName,
    required String databasePath,
    required String cipher,
  }) async {
    openedPaths.add(databasePath);
    opens.add((path: databasePath, cipher: cipher));
    ciphers.putIfAbsent(databasePath, () => cipher);
    final database =
        databases.putIfAbsent(databasePath, FakeMatrixDatabase.new);
    return FakeMatrixClient(database, httpClient: server);
  }

  Future<void> dispose(Client client) => client.dispose();

  Future<void> delete(String path) async {
    deletedPaths.add(path);
    databases.remove(path);
  }
}

/// Mirrors the in-memory SDK fixture without weakening production's disk
/// preflight. A populated fake DB carries its fixture fingerprint as pickle.
final class _SandboxIdentityReader implements MatrixLocalIdentityReader {
  const _SandboxIdentityReader(this.sandbox);

  final FakeMatrixSandbox sandbox;

  @override
  Future<bool> exists(String databasePath) async =>
      sandbox.databases.containsKey(databasePath);

  @override
  Future<MatrixLocalIdentityRecord> read(
      String databasePath, String cipher) async {
    final db = sandbox.databases[databasePath];
    if (db == null) throw StateError('Fake Matrix database is missing');
    final savedCipher = sandbox.ciphers[databasePath];
    if (savedCipher != null && savedCipher != cipher) {
      throw StateError('Fake Matrix cipher mismatch');
    }
    return MatrixLocalIdentityRecord(
      hasRetainedData: db.loggedIn ||
          db.userId != null ||
          db.deviceId != null ||
          db.fingerprint != null,
      matrixUserId: db.userId,
      deviceId: db.deviceId,
      olmAccount: db.fingerprint,
    );
  }
}

/// 把 `Client.init()`/`login()` 采纳的新身份写回持久库，与 SDK 行为一致。
final class FakeMatrixClient extends LogoutTrackingClient {
  FakeMatrixClient(FakeMatrixDatabase db, {super.httpClient})
      : db = db,
        super(
          'liuhetong_mobile',
          loggedIn: db.loggedIn,
          matrixUserId: db.userId,
          matrixDeviceId: db.deviceId,
        );

  final FakeMatrixDatabase db;

  void _persistObservedIdentity() {
    db
      ..userId = matrixUserId
      ..deviceId = matrixDeviceId
      ..loggedIn = loggedIn;
  }

  @override
  Future<void> init({
    String? newToken,
    DateTime? newTokenExpiresAt,
    String? newRefreshToken,
    Uri? newHomeserver,
    String? newUserID,
    String? newDeviceName,
    String? newDeviceID,
    String? newOlmAccount,
    bool waitForFirstSync = true,
    bool waitUntilLoadCompletedLoaded = true,
    void Function()? onMigration,
  }) async {
    await super.init(
      newToken: newToken,
      newTokenExpiresAt: newTokenExpiresAt,
      newRefreshToken: newRefreshToken,
      newHomeserver: newHomeserver,
      newUserID: newUserID,
      newDeviceName: newDeviceName,
      newDeviceID: newDeviceID,
      newOlmAccount: newOlmAccount,
      waitForFirstSync: waitForFirstSync,
      waitUntilLoadCompletedLoaded: waitUntilLoadCompletedLoaded,
      onMigration: onMigration,
    );
    matrixUserId = newUserID ?? matrixUserId;
    matrixDeviceId = newDeviceID ?? matrixDeviceId;
    loggedIn = true;
    if (newUserID != null) {
      db.fingerprint ??= 'fingerprint:$newUserID';
    }
    _persistObservedIdentity();
  }

  /// 首次登录：库里没有会话，由 SDK 自己发起 `m.login.token`，服务端在这里
  /// 分配账号与 device。返回的身份必须与 `nextLoginUserId/DeviceId` 一致，
  /// 因为登录流程会校验 `matrix.userId == 业务绑定的 Matrix 账号`。
  @override
  Future<LoginResponse> login(
    String type, {
    AuthenticationIdentifier? identifier,
    String? password,
    String? token,
    String? deviceId,
    String? initialDeviceDisplayName,
    bool? refreshToken,
    String? user,
    String? medium,
    String? address,
  }) async {
    final response = LoginResponse(
      accessToken: 'first-login-access-token',
      deviceId: db.nextLoginDeviceId ?? db.deviceId ?? 'device-first',
      userId: db.userId ?? db.nextLoginUserId ?? '@a:test',
    );
    // 真实 SDK 的 login() 内部会 init() 并保存新 token；fake 直接落到同样的字段。
    accessToken = response.accessToken;
    matrixUserId = response.userId;
    matrixDeviceId = response.deviceId;
    loggedIn = true;
    // 真实 SDK 在首次登录时建立 Olm 身份；此后它随本地库保留，只在本地库被
    // 销毁时才重新生成。fake 必须体现这一点，否则"首次登录成功"这个场景里
    // 根本不存在可校验的 E2EE continuity。
    db.fingerprint ??= 'fingerprint:${response.userId}';
    _persistObservedIdentity();
    return response;
  }

  @override
  Future<void> dispose({bool closeDatabase = true}) async {
    db.disposals++;
    await super.dispose(closeDatabase: closeDatabase);
  }

  @override
  Future<SyncUpdate> sync({
    String? filter,
    String? since,
    bool? fullState,
    PresenceType? setPresence,
    int? timeout,
  }) async {
    db.syncs++;
    if (db.failSync) {
      throw MatrixException.fromJson(
        const {'errcode': 'M_UNKNOWN', 'error': 'temporary failure'},
      );
    }
    return SyncUpdate(nextBatch: 'next');
  }
}

/// 单设备策略下的服务端：客户端请求保留 device-OLD，服务端返回权威 device-NEW。
final class TokenLoginServer {
  TokenLoginServer({required this.userId, required this.deviceId});

  String userId;
  String deviceId;
  String accessToken = 'rotated-access-token';
  Future<void> Function()? beforeRespond;
  int requests = 0;
  final List<String> requestedDeviceIds = [];

  http.Client get client => MockClient((request) async {
        if (!request.url.path.endsWith('/login')) {
          return http.Response('{}', 404);
        }
        requests++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requestedDeviceIds.add(body['device_id']?.toString() ?? '');
        await beforeRespond?.call();
        return http.Response(
          jsonEncode({
            'access_token': accessToken,
            'refresh_token': 'rotated-refresh-token',
            'expires_in_ms': 60000,
            'device_id': deviceId,
            'user_id': userId,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
}

/// 与 `main.dart` 相同的装配方式。
Future<MatrixClientFactory> buildFactory({
  required SecureSessionStore store,
  required FakeMatrixSandbox sandbox,
  String Function()? databaseGenerationFactory,
  MatrixSecurityLogger? securityLogger,
  MatrixDiagnosticHasher? diagnosticHasher,
}) async {
  // This suite models an existing encrypted database in memory. Production
  // preflight rightly refuses retained bytes without their Keychain cipher.
  await store.matrixDatabaseKey();
  return MatrixClientFactory(
    sessionStore: store,
    homeserver: _homeserver,
    supportDirectoryPath: () async => _supportDirectory,
    opener: sandbox.open,
    disposer: sandbox.dispose,
    databaseDeleter: sandbox.delete,
    clientMigrator: (_, __) async {},
    fingerprintReader: (client) => (client as FakeMatrixClient).db.fingerprint,
    localIdentityPreflight: MatrixLocalIdentityPreflight(
      reader: _SandboxIdentityReader(sandbox),
      fingerprintReader: (_, pickle) async => pickle,
    ),
    databaseGenerationFactory:
        databaseGenerationFactory ?? () => 'generation-a',
    securityLogger: securityLogger,
    diagnosticHasher: diagnosticHasher,
  );
}

MatrixSdkE2eeClient buildMatrix({
  required Client client,
  required MatrixClientFactory factory,
  Duration lifecycleDrainTimeout = const Duration(seconds: 5),
  MatrixSecurityLogger? securityLogger,
  MatrixDiagnosticHasher? diagnosticHasher,
}) =>
    MatrixSdkE2eeClient(
      client,
      homeserver: _homeserver,
      suspendClient: factory.suspend,
      resumeClient: factory.create,
      selectClientAccount: factory.selectAccount,
      clearClientData: factory.clearLocalChatData,
      readContinuityMetadata: factory.continuityMetadata,
      rotateDeviceBinding: factory.rotateDeviceBinding,
      lifecycleDrainTimeout: lifecycleDrainTimeout,
      securityLogger: securityLogger,
      diagnosticHasher: diagnosticHasher,
    );

MatrixLocalBinding bindingFor({
  String userId = '@a:test',
  required String deviceId,
  String fingerprint = 'fingerprint-a',
  String generation = 'generation-a',
}) =>
    MatrixLocalBinding(
      version: 2,
      matrixUserId: userId,
      deviceId: deviceId,
      homeserver: _homeserverText,
      databaseGeneration: generation,
      ed25519Fingerprint: fingerprint,
    );

final class FakeLoginBusiness implements DualDomainBusinessGateway {
  FakeLoginBusiness({this.grantUserId = '@a:test'});

  final String grantUserId;
  String? boundMatrixUserId;
  bool sessionActive = true;
  int logouts = 0;
  int grants = 0;

  @override
  Future<void> loginBusiness({
    required String username,
    required String password,
    required String deviceKey,
    required String deviceName,
  }) async {
    sessionActive = true;
  }

  @override
  Future<MatrixLoginGrant> issueMatrixLoginToken() async {
    grants++;
    return MatrixLoginGrant(
      loginToken: 'login-token-$grants',
      homeserver: _homeserverText,
      expiresIn: 60,
      matrixUserId: grantUserId,
    );
  }

  @override
  Future<String?> currentMatrixUserId() async =>
      sessionActive ? boundMatrixUserId : null;

  @override
  Future<void> bindMatrixUserId(String matrixUserId) async {
    boundMatrixUserId = matrixUserId;
  }

  @override
  Future<void> logoutBusiness() async {
    logouts++;
    sessionActive = false;
    boundMatrixUserId = null;
  }
}

final class HeldSasRequest implements MatrixSasRequestHandle {
  HeldSasRequest(this.hold);
  final Future<void> Function() hold;

  @override
  Future<void> accept() => hold();
  @override
  Future<void> confirmSas() async {}
  @override
  Future<void> continueSas() async {}
  @override
  Future<void> reject() async {}
  @override
  void dispose() {}
}

Future<void> expectLoginSucceeds(DualDomainLoginService service) async {
  try {
    await service.login('alice', 'password');
  } on LoginStageException catch (error) {
    fail('login failed at ${error.diagnosticCode}: ${error.message}');
  } on BusinessApiException catch (error) {
    fail('login failed with ${error.code}: ${error.message}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'server-rotated device id completes login against an existing persisted binding',
      () async {
    // iPhone 上已经登录过账号 A（binding=device-OLD，库里也是 device-OLD）。
    // 另一台设备登录 A 后，服务端单设备策略顶掉了 device-OLD。用户在本机重登时
    // 服务端返回权威 device-NEW —— 这是可恢复的轮换，不是身份损坏。
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    final server = TokenLoginServer(userId: '@a:test', deviceId: 'device-NEW');
    final sandbox = FakeMatrixSandbox(server: server.client);
    final database = sandbox.forScope('')
      ..userId = '@a:test'
      ..deviceId = 'device-OLD'
      ..loggedIn = true
      ..fingerprint = 'fingerprint-a';
    await store.saveMatrixBinding(bindingFor(deviceId: 'device-OLD'));
    final factory = await buildFactory(store: store, sandbox: sandbox);
    final matrix =
        buildMatrix(client: await factory.create(), factory: factory);

    await matrix.loginWithToken(
      loginToken: 'one-time-token',
      homeserver: _homeserver,
      deviceId: 'device-OLD',
    );

    expect(server.requestedDeviceIds, ['device-OLD'],
        reason: '保留身份刷新必须先请求原 device id');
    expect(database.deviceId, 'device-NEW');
    expect(matrix.deviceId, 'device-NEW');
    expect(matrix.credentialsInvalid, isFalse);
    expect(matrix.isLoggedIn, isTrue);
    expect(matrix.debugHasActiveClient, isTrue);
    expect(sandbox.deletedPaths, isEmpty, reason: 'device 轮换不得删除聊天记录或本地库');
    final binding = await store.matrixBinding();
    expect(binding?.deviceId, 'device-NEW');
    expect(binding?.matrixUserId, '@a:test', reason: '迁移只允许改写 device id');
    expect(binding?.homeserver, _homeserverText);
    expect(binding?.databaseGeneration, 'generation-a');
    expect(binding?.ed25519Fingerprint, 'fingerprint-a');
  });

  test(
      'a rotation whose Olm identity changed is rejected without touching the binding',
      () async {
    // binding 记录 fingerprint-a，而本机库里的 Olm(Ed25519) 身份已经是
    // fingerprint-b：这是真正的密码学身份错配，绝不是可恢复的服务端轮换。
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    final sandbox = FakeMatrixSandbox();
    sandbox.forScope('')
      ..userId = '@a:test'
      ..deviceId = 'device-OLD'
      ..loggedIn = true
      ..fingerprint = 'fingerprint-b';
    await store.saveMatrixBinding(bindingFor(deviceId: 'device-OLD'));
    final factory = await buildFactory(store: store, sandbox: sandbox);
    await expectLater(
      factory.create(),
      throwsA(isA<MatrixLocalIdentityPreflightException>().having(
          (error) => error.cause,
          'cause',
          MatrixLocalIdentityCause.fingerprintMismatch)),
    );

    final binding = await store.matrixBinding();
    expect(binding?.deviceId, 'device-OLD', reason: '被拒绝的轮换不得改写 binding');
    expect(binding?.ed25519Fingerprint, 'fingerprint-a');
  });

  test('a rotation to a different Matrix user is rejected', () async {
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    // 服务端返回了另一个账号——token 没有证明本机保留身份的归属。
    final server = TokenLoginServer(userId: '@b:test', deviceId: 'device-NEW');
    final sandbox = FakeMatrixSandbox(server: server.client);
    sandbox.forScope('')
      ..userId = '@a:test'
      ..deviceId = 'device-OLD'
      ..loggedIn = true
      ..fingerprint = 'fingerprint-a';
    await store.saveMatrixBinding(bindingFor(deviceId: 'device-OLD'));
    final factory = await buildFactory(store: store, sandbox: sandbox);
    final matrix =
        buildMatrix(client: await factory.create(), factory: factory);

    await expectLater(
      matrix.loginWithToken(
        loginToken: 'one-time-token',
        homeserver: _homeserver,
        deviceId: 'device-OLD',
      ),
      throwsStateError,
    );

    final binding = await store.matrixBinding();
    expect(binding?.matrixUserId, '@a:test');
    expect(binding?.deviceId, 'device-OLD');
    expect(sandbox.forScope('').deviceId, 'device-OLD',
        reason: '拒绝后不得留下已被轮换的本地库');
  });

  test('rotateDeviceBinding rejects every rotation it cannot verify', () async {
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    final sandbox = FakeMatrixSandbox();
    final database = sandbox.forScope('')
      ..userId = '@a:test'
      ..deviceId = 'device-NEW'
      ..loggedIn = true
      ..fingerprint = 'fingerprint-a';
    await store.saveMatrixBinding(bindingFor(deviceId: 'device-OLD'));
    final factory = await buildFactory(store: store, sandbox: sandbox);
    final client = await factory.create() as FakeMatrixClient;

    // (1) 调用方声称的"轮换前 device"与 binding 不符：无法证明这是同一次轮换。
    await expectLater(
      factory.rotateDeviceBinding(
        client,
        expectedUserId: '@a:test',
        previousDeviceId: 'device-OTHER',
        nextDeviceId: 'device-NEW',
      ),
      throwsA(isA<MatrixDeviceBindingRotationRejected>()),
    );
    // (2) 账号不符。
    await expectLater(
      factory.rotateDeviceBinding(
        client,
        expectedUserId: '@b:test',
        previousDeviceId: 'device-OLD',
        nextDeviceId: 'device-NEW',
      ),
      throwsA(isA<MatrixDeviceBindingRotationRejected>()),
    );
    // (3) client 的最终 device 并不是服务端返回的那个。
    client.matrixDeviceId = 'device-UNEXPECTED';
    await expectLater(
      factory.rotateDeviceBinding(
        client,
        expectedUserId: '@a:test',
        previousDeviceId: 'device-OLD',
        nextDeviceId: 'device-NEW',
      ),
      throwsA(isA<MatrixDeviceBindingRotationRejected>()),
    );
    // (4) fingerprint 不一致。
    client.matrixDeviceId = 'device-NEW';
    database.fingerprint = 'fingerprint-b';
    await expectLater(
      factory.rotateDeviceBinding(
        client,
        expectedUserId: '@a:test',
        previousDeviceId: 'device-OLD',
        nextDeviceId: 'device-NEW',
      ),
      throwsA(isA<MatrixDeviceBindingRotationRejected>()),
    );

    expect((await store.matrixBinding())?.deviceId, 'device-OLD',
        reason: '四次拒绝都不得改写 binding');
  });

  test('a store already rotated by an older build is repaired on resume',
      () async {
    // build 2121 的遗留态：SDK 已经把权威 device id 写进本地库，但 binding 还是
    // 旧的。没有这条修复路径，这类用户升级后每次登录都会失败（L04/L07 死锁）。
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    final sandbox = FakeMatrixSandbox();
    sandbox.forScope('')
      ..userId = '@a:test'
      ..deviceId = 'device-NEW'
      ..loggedIn = true
      ..fingerprint = 'fingerprint-a';
    await store.saveMatrixBinding(bindingFor(deviceId: 'device-OLD'));
    final factory = await buildFactory(store: store, sandbox: sandbox);
    final matrix =
        buildMatrix(client: await factory.create(), factory: factory);

    await matrix.suspend();

    expect(
        matrix.debugSuspendedContinuity, MatrixSuspendedContinuity.validated);
    final binding = await store.matrixBinding();
    expect(binding?.deviceId, 'device-NEW');
    expect(binding?.matrixUserId, '@a:test');
    expect(binding?.databaseGeneration, 'generation-a');
    expect(binding?.ed25519Fingerprint, 'fingerprint-a');

    // 之后必须可以正常 resume 并继续使用。
    await matrix.sync();
    expect(matrix.debugHasActiveClient, isTrue);
  });

  test('an unverifiable store still closes safely but never claims continuity',
      () async {
    // 同样的"库已轮换、binding 未轮换"形状，但 Olm 身份不一致：
    // 允许安全关闭，绝不允许被当成已验证的连续性。
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    final sandbox = FakeMatrixSandbox();
    final database = sandbox.forScope('')
      ..userId = '@a:test'
      ..deviceId = 'device-NEW'
      ..loggedIn = true
      ..fingerprint = 'fingerprint-b';
    await store.saveMatrixBinding(bindingFor(deviceId: 'device-OLD'));
    final factory = await buildFactory(store: store, sandbox: sandbox);
    // Model an SDK client already open before this version's pre-init gate.
    final matrix =
        buildMatrix(client: FakeMatrixClient(database), factory: factory);

    await matrix.suspend();

    expect(matrix.debugHasActiveClient, isFalse);
    expect(matrix.debugSuspendedContinuity, MatrixSuspendedContinuity.unknown);
    expect((await store.matrixBinding())?.deviceId, 'device-OLD',
        reason: '无法验证时不得自动改写 binding');
    await expectLater(
        matrix.sync(), throwsA(isA<MatrixLocalIdentityPreflightException>()));
    expect(matrix.debugHasActiveClient, isFalse);
  });

  test('switching accounts opens each account database, key and binding',
      () async {
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    final sandbox = FakeMatrixSandbox();
    // 两个账号在本机都有历史：各自的库、各自的 SQLCipher key、各自的 binding。
    await store.selectMatrixAccount(_homeserverText, '@a:test');
    final scopeA = await store.matrixStorageScope();
    sandbox.forScope(scopeA)
      ..userId = '@a:test'
      ..deviceId = 'device-A'
      ..loggedIn = true
      ..fingerprint = 'fingerprint-a';
    await store.saveMatrixBinding(bindingFor(deviceId: 'device-A'));
    final cipherA = await store.matrixDatabaseKey();

    await store.selectMatrixAccount(_homeserverText, '@b:test');
    final scopeB = await store.matrixStorageScope();
    sandbox.forScope(scopeB)
      ..userId = '@b:test'
      ..deviceId = 'device-B'
      ..loggedIn = true
      ..fingerprint = 'fingerprint-b';
    await store.saveMatrixBinding(bindingFor(
      userId: '@b:test',
      deviceId: 'device-B',
      fingerprint: 'fingerprint-b',
      generation: 'generation-b',
    ));
    final cipherB = await store.matrixDatabaseKey();
    await store.selectMatrixAccount(_homeserverText, '@a:test');

    expect(scopeA, isNot(scopeB));
    expect(cipherA, isNot(cipherB));
    final factory = await buildFactory(store: store, sandbox: sandbox);
    final matrix =
        buildMatrix(client: await factory.create(), factory: factory);
    expect(matrix.deviceId, 'device-A');

    await matrix.selectAccount('@b:test', _homeserver);

    expect(await store.matrixStorageScope(), scopeB);
    expect(matrix.userId, '@b:test');
    expect(matrix.deviceId, 'device-B');
    expect(matrix.credentialsInvalid, isTrue,
        reason: '恢复出来的 token 必须先经 broker 刷新');
    expect(sandbox.forScope(scopeA).disposals, greaterThanOrEqualTo(1),
        reason: 'A 的库必须先关闭');
    expect(sandbox.forScope(scopeB).disposals, 0);
    expect(sandbox.ciphers[FakeMatrixSandbox.pathForScope(scopeB)], cipherB);
    expect((await store.matrixBinding())?.deviceId, 'device-B');
    expect(sandbox.deletedPaths, isEmpty, reason: '切账号不得删除任何账号的聊天记录');

    // A → B → A：回到 A 必须复用 A 自己的库、key 与 binding。
    final opensBeforeReturn = sandbox.opens.length;
    await matrix.selectAccount('@a:test', _homeserver);

    expect(await store.matrixStorageScope(), scopeA);
    expect(matrix.userId, '@a:test');
    expect(matrix.deviceId, 'device-A');
    expect(sandbox.forScope(scopeB).disposals, greaterThanOrEqualTo(1));
    final reopened = sandbox.opens[opensBeforeReturn];
    expect(reopened.path, FakeMatrixSandbox.pathForScope(scopeA));
    expect(reopened.cipher, cipherA, reason: '每个账号必须使用自己的 SQLCipher key');
    expect((await store.matrixBinding())?.deviceId, 'device-A');
    expect((await store.matrixBinding())?.matrixUserId, '@a:test');
    expect(sandbox.deletedPaths, isEmpty);
  });

  test('suspend closes the client even when continuity metadata cannot be read',
      () async {
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    final sandbox = FakeMatrixSandbox();
    final database = sandbox.forScope('')
      ..userId = '@a:test'
      ..deviceId = 'device-OLD'
      ..loggedIn = true;
    final factory = await buildFactory(store: store, sandbox: sandbox);
    final matrix = MatrixSdkE2eeClient(
      FakeMatrixClient(database),
      homeserver: _homeserver,
      suspendClient: factory.suspend,
      resumeClient: factory.create,
      readContinuityMetadata: (_) async =>
          throw StateError('Matrix client does not match the local binding'),
    );

    await matrix.suspend();

    expect(database.disposals, 1, reason: 'continuity 读取失败绝不能阻止关闭');
    expect(matrix.debugHasActiveClient, isFalse);
  });

  test(
      'suspend closes the client on drain timeout combined with a metadata error',
      () async {
    final database = FakeMatrixDatabase(
        userId: '@a:test', deviceId: 'device-OLD', loggedIn: true);
    final client = FakeMatrixClient(database);
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    final factory =
        await buildFactory(store: store, sandbox: FakeMatrixSandbox());
    var continuityReads = 0;
    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: _homeserver,
      suspendClient: factory.suspend,
      resumeClient: factory.create,
      // 第一次读取（注册订阅时）成功；挂起时的读取失败。
      readContinuityMetadata: (_) async {
        if (continuityReads++ == 0) {
          return const MatrixClientContinuityMetadata(
            isLoggedIn: true,
            userId: '@a:test',
            deviceId: 'device-OLD',
            ed25519Fingerprint: 'fingerprint-a',
            databaseGeneration: 'generation-a',
          );
        }
        throw StateError('unreadable');
      },
      lifecycleDrainTimeout: const Duration(milliseconds: 20),
    );
    final hold = Completer<void>();
    final source = StreamController<MatrixSasRequestHandle>.broadcast();
    late MatrixSasRequestHandle handle;
    await matrix.subscribeSasRequests(
      testSource: () => source.stream,
      onData: (request) => handle = request,
    );
    source.add(HeldSasRequest(() => hold.future));
    await Future<void>.delayed(Duration.zero);
    final operation = handle.accept();
    await Future<void>.delayed(Duration.zero);

    await matrix.suspend();

    expect(database.disposals, 1);
    expect(matrix.debugHasActiveClient, isFalse);
    hold.complete();
    await operation.then<void>((_) {}, onError: (Object _) {});
    await source.close();
  });

  test('a failed login attempt stays retryable and never wedges the next login',
      () async {
    // 第一次登录：token 轮换后被写入磁盘的 device-NEW 与旧 binding 不一致，
    // 随后的同步又失败。失败清理必须真正关闭 client；第二次登录必须能重新
    // resume 已经持久化为 device-NEW 的库，而不是被残留的半挂起态拖成 L04/L07。
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    final server = TokenLoginServer(userId: '@a:test', deviceId: 'device-NEW');
    final sandbox = FakeMatrixSandbox(server: server.client);
    sandbox.forScope('')
      ..userId = '@a:test'
      ..deviceId = 'device-OLD'
      ..loggedIn = true
      ..fingerprint = 'fingerprint-a'
      ..failSync = true;
    await store.saveMatrixBinding(bindingFor(deviceId: 'device-OLD'));
    final factory = await buildFactory(store: store, sandbox: sandbox);
    final business = FakeLoginBusiness();
    final matrix =
        buildMatrix(client: await factory.create(), factory: factory);
    final service = DualDomainLoginService(
      business: business,
      matrix: matrix,
      deviceKey: () => 'device-key',
      retainedHomeserver: _homeserver,
    );

    await expectLater(
      service.login('alice', 'password'),
      throwsA(isA<LoginStageException>()
          .having((error) => error.diagnosticCode, 'stage', 'L05')),
    );
    expect(matrix.debugHasActiveClient, isFalse,
        reason: '失败清理必须真正关闭 client，不能留下半挂起态');

    sandbox.forScope('').failSync = false;
    await expectLoginSucceeds(service);

    expect(matrix.isLoggedIn, isTrue);
    expect(matrix.credentialsInvalid, isFalse);
    expect(sandbox.deletedPaths, isEmpty);
  });

  test(
      'same account remote login rotates the device and reaches the chat session',
      () async {
    // 验收场景：账号 A 已在设备 1 登录 → 本机（设备 2）重登 A。
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    final server = TokenLoginServer(userId: '@a:test', deviceId: 'device-NEW');
    final sandbox = FakeMatrixSandbox(server: server.client);
    final database = sandbox.forScope('')
      ..userId = '@a:test'
      ..deviceId = 'device-OLD'
      ..loggedIn = true
      ..fingerprint = 'fingerprint-a';
    await store.saveMatrixBinding(bindingFor(deviceId: 'device-OLD'));
    final factory = await buildFactory(store: store, sandbox: sandbox);
    final business = FakeLoginBusiness();
    var completedSessions = 0;
    final matrix =
        buildMatrix(client: await factory.create(), factory: factory);
    final cipherBefore = sandbox.ciphers.values.single;
    // 模拟启动时的会话失效挂起（服务端已把本机顶下线）。
    await matrix.suspend();
    final service = DualDomainLoginService(
      business: business,
      matrix: matrix,
      deviceKey: () => 'device-key',
      retainedHomeserver: _homeserver,
      completeMatrixSession: () async {
        completedSessions++;
        final credentials = await matrix.currentSessionCredentials();
        expect(credentials.deviceId, 'device-NEW');
      },
    );

    await expectLoginSucceeds(service);

    expect(completedSessions, 1);
    expect(server.requests, 1);
    expect(business.boundMatrixUserId, '@a:test');
    expect(server.requestedDeviceIds, ['device-OLD']);
    expect(database.deviceId, 'device-NEW');
    expect(matrix.credentialsInvalid, isFalse);
    expect(matrix.isLoggedIn, isTrue);
    expect(sandbox.ciphers.values.single, cipherBefore,
        reason: '轮换不得更换 SQLCipher key 或重建本地库');
    expect(sandbox.deletedPaths, isEmpty, reason: '不删除聊天记录、不删除库、不重建 E2EE 身份');
  });

  test(
      'account selection onto an older build-rotated store never wedges at L07',
      () async {
    // 2121 的 L07：目标账号的本地库已经被服务端轮换写新，binding 还是旧的。
    // 此前 selectAccount 会在 resume 的 continuity 校验上抛错，account_storage
    // 阶段永久失败；修复后必须按密码学锚点补齐 device id 并正常切过去。
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    final sandbox = FakeMatrixSandbox();
    await store.selectMatrixAccount(_homeserverText, '@a:test');
    final scopeA = await store.matrixStorageScope();
    sandbox.forScope(scopeA)
      ..userId = '@a:test'
      ..deviceId = 'device-A'
      ..loggedIn = true
      ..fingerprint = 'fingerprint-a';
    await store.saveMatrixBinding(bindingFor(deviceId: 'device-A'));

    await store.selectMatrixAccount(_homeserverText, '@b:test');
    final scopeB = await store.matrixStorageScope();
    sandbox.forScope(scopeB)
      ..userId = '@b:test'
      ..deviceId = 'device-B-new'
      ..loggedIn = true
      ..fingerprint = 'fingerprint-b';
    await store.saveMatrixBinding(bindingFor(
      userId: '@b:test',
      deviceId: 'device-B-old',
      fingerprint: 'fingerprint-b',
      generation: 'generation-b',
    ));
    await store.matrixDatabaseKey();
    await store.selectMatrixAccount(_homeserverText, '@a:test');
    final factory = await buildFactory(store: store, sandbox: sandbox);
    final matrix =
        buildMatrix(client: await factory.create(), factory: factory);

    await matrix.selectAccount('@b:test', _homeserver);

    expect(matrix.userId, '@b:test');
    expect(matrix.deviceId, 'device-B-new');
    final bindingB = await store.matrixBinding();
    expect(bindingB?.deviceId, 'device-B-new');
    expect(bindingB?.matrixUserId, '@b:test');
    expect(bindingB?.databaseGeneration, 'generation-b',
        reason: '补齐 device id 不得更换本地库代号');
    expect(bindingB?.ed25519Fingerprint, 'fingerprint-b');
    expect(matrix.credentialsInvalid, isTrue,
        reason: '恢复出来的 token 仍需 broker 刷新');
    expect(sandbox.deletedPaths, isEmpty);
  });

  test(
      'end-to-end login of a fresh account selects storage, logs in, completes and syncs',
      () async {
    // DualDomainLoginService + MatrixSdkE2eeClient + MatrixClientFactory +
    // SecureSessionStore 的真实装配：本机知道账号 A 的存储槽，但还没有 Matrix 身份。
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    final server = TokenLoginServer(userId: '@a:test', deviceId: 'device-1');
    final sandbox = FakeMatrixSandbox(server: server.client);
    await store.selectMatrixAccount(_homeserverText, '@a:test');
    final scope = await store.matrixStorageScope();
    sandbox.forScope(scope).nextLoginDeviceId = 'device-1';
    final factory = await buildFactory(store: store, sandbox: sandbox);
    final business = FakeLoginBusiness();
    var completedSessions = 0;
    final matrix =
        buildMatrix(client: await factory.create(), factory: factory);
    final service = DualDomainLoginService(
      business: business,
      matrix: matrix,
      deviceKey: () => 'device-key',
      retainedHomeserver: _homeserver,
      completeMatrixSession: () async {
        completedSessions++;
        final credentials = await matrix.currentSessionCredentials();
        expect(credentials.deviceId, 'device-1');
      },
    );

    await expectLoginSucceeds(service);

    expect(completedSessions, 1);
    expect(business.boundMatrixUserId, '@a:test');
    expect(server.requests, 1,
        reason: '首次登录先验 broker token 的 raw MXID，再允许 SDK 建立身份');
    expect(matrix.userId, '@a:test');
    expect(matrix.deviceId, 'device-1');
    expect(matrix.isLoggedIn, isTrue);
    expect(matrix.credentialsInvalid, isFalse);
    expect((await store.matrixBinding())?.deviceId, 'device-1');
    expect((await store.matrixBinding())?.matrixUserId, '@a:test');
    expect((await store.matrixBinding())?.ed25519Fingerprint, isNotNull,
        reason: '首次登录必须建立可校验的 E2EE continuity');
    expect(sandbox.deletedPaths, isEmpty);
    expect(sandbox.openedPaths, isNotEmpty);
  });

  test('lifecycle diagnostics hash identity instead of logging raw values',
      () async {
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    final server = TokenLoginServer(userId: '@a:test', deviceId: 'device-NEW');
    final sandbox = FakeMatrixSandbox(server: server.client);
    sandbox.forScope('')
      ..userId = '@a:test'
      ..deviceId = 'device-OLD'
      ..loggedIn = true
      ..fingerprint = 'fingerprint-a';
    await store.saveMatrixBinding(bindingFor(deviceId: 'device-OLD'));
    final lines = <String>[];
    final logger = MatrixSecurityLogger(
      traceId: () => 'trace-lifecycle',
      sink: lines.add,
    );
    final hasher = MatrixDiagnosticHasher(await store.diagnosticSalt());
    final factory = await buildFactory(
      store: store,
      sandbox: sandbox,
      securityLogger: logger,
      diagnosticHasher: hasher,
    );
    final matrix = buildMatrix(
      client: await factory.create(),
      factory: factory,
      securityLogger: logger,
      diagnosticHasher: hasher,
    );

    await matrix.loginWithToken(
      loginToken: 'one-time-token',
      homeserver: _homeserver,
      deviceId: 'device-OLD',
    );
    await matrix.suspend();

    final joined = lines.join('\n');
    expect(lines, isNotEmpty);
    expect(joined, contains('E2EE_DEVICE_ROTATION_BINDING_MIGRATED'));
    expect(joined, contains('E2EE_LIFECYCLE_SUSPEND_BEGIN'));
    expect(joined, contains('E2EE_LIFECYCLE_SUSPEND_COMPLETED'));
    expect(joined, contains('"identity"'), reason: '需要可按哈希关联的身份字段');
    for (final raw in [
      '@a:test',
      'device-OLD',
      'device-NEW',
      'fingerprint-a',
      'rotated-access-token',
      'rotated-refresh-token',
      'one-time-token',
      'generation-a',
    ]) {
      expect(joined, isNot(contains(raw)), reason: '日志中不得出现原始值 $raw');
    }
    expect(
      lines
          .map((line) => (jsonDecode(line) as Map<String, dynamic>)['trace_id'])
          .toSet(),
      {'trace-lifecycle'},
    );
  });

  test(
      'serialized lifecycle: a concurrent suspend never leaves half-open state',
      () async {
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    final server = TokenLoginServer(userId: '@a:test', deviceId: 'device-NEW');
    final gate = Completer<void>();
    server.beforeRespond = () => gate.future;
    final sandbox = FakeMatrixSandbox(server: server.client);
    sandbox.forScope('')
      ..userId = '@a:test'
      ..deviceId = 'device-OLD'
      ..loggedIn = true
      ..fingerprint = 'fingerprint-a';
    await store.saveMatrixBinding(bindingFor(deviceId: 'device-OLD'));
    final factory = await buildFactory(store: store, sandbox: sandbox);
    final matrix = buildMatrix(
      client: await factory.create(),
      factory: factory,
      lifecycleDrainTimeout: const Duration(milliseconds: 20),
    );

    final login = matrix.loginWithToken(
      loginToken: 'one-time-token',
      homeserver: _homeserver,
      deviceId: 'device-OLD',
    );
    await Future<void>.delayed(Duration.zero);
    final suspend = matrix.suspend();
    gate.complete();
    await login.then<void>((_) {}, onError: (Object _) {});
    await suspend;

    expect(matrix.debugHasActiveClient, isFalse,
        reason: '前台/后台生命周期竞争后不得留下半开 client');

    // 竞争之后必须仍然可以正常登录（不能被残留状态卡死）。
    server.beforeRespond = null;
    await matrix.loginWithToken(
      loginToken: 'retry-token',
      homeserver: _homeserver,
      deviceId: 'device-NEW',
    );
    expect(matrix.isLoggedIn, isTrue);
    expect(matrix.deviceId, 'device-NEW');
  });
}
