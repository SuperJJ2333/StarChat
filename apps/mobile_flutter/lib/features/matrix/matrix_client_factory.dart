import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';

import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/matrix_local_binding.dart';
import '../../core/session_store.dart';
import 'matrix_e2ee_client.dart';
import 'matrix_security_logger.dart';

typedef MatrixClientOpener = Future<Client> Function({
  required String clientName,
  required String databasePath,
  required String cipher,
});
typedef MatrixClientDisposer = Future<void> Function(Client client);
typedef MatrixDatabaseDeleter = Future<void> Function(String path);
typedef MatrixClientMigrator = Future<void> Function(
    Client client, Uri homeserver);

/// 同一数据库路径上的初始化串行化（按路径加锁，而非一把全局锁）。
///
/// **为什么必须有**：`Client.init()` 会打开 SQLite/SQLCipher 库并写入
/// `box_client`（token/credentials）。同一进程里若两个工厂并发对**同一个**
/// 文件执行「打开 + SDK 初始化 + 持久化凭据」，两个连接会互相踩到对方的
/// 写入事务，表现为
/// `constraint failed (code 1811)` + `INSERT OR REPLACE INTO box_client (k, v)`
/// 这类非确定性失败。
///
/// 锁覆盖**整段**序列（打开数据库 → SDK 初始化 → 凭据持久化 → 返回 client），
/// 只锁路径生成是不够的。不同数据库路径之间互不阻塞；队列排空后条目会被移除，
/// 不会无限增长。
final class _DatabaseInitLocks {
  _DatabaseInitLocks._();

  static final Map<String, Future<void>> _tails = <String, Future<void>>{};

  static Future<T> run<T>(String path, Future<T> Function() operation) {
    final previous = _tails[path] ?? Future<void>.value();
    final completer = Completer<void>();
    final tail = completer.future;
    _tails[path] = tail;

    return previous.then((_) async {
      try {
        return await operation();
      } finally {
        if (!completer.isCompleted) completer.complete();
        // 只有仍是队尾时才清理，避免移除后来者排上的新尾巴。
        if (identical(_tails[path], tail)) _tails.remove(path);
      }
    });
  }

  @visibleForTesting
  static int get pendingPathCount => _tails.length;
}

final class MatrixClientFactory {
  MatrixClientFactory({
    required this.sessionStore,
    required this.homeserver,
    Future<String> Function()? supportDirectoryPath,
    MatrixClientOpener? opener,
    MatrixClientDisposer? disposer,
    MatrixDatabaseDeleter? databaseDeleter,
    MatrixClientMigrator? clientMigrator,
    String? Function(Client client)? fingerprintReader,
    String Function()? databaseGenerationFactory,
    MatrixSecurityLogger? securityLogger,
    this.diagnosticHasher,
  })  : supportDirectoryPath = supportDirectoryPath ?? _defaultSupportPath,
        opener = opener ?? _openPersistentClient,
        disposer = disposer ?? _disposeClient,
        databaseDeleter = databaseDeleter ?? _deleteDatabase,
        clientMigrator = clientMigrator ?? _migrateHomeserver,
        fingerprintReader = fingerprintReader ?? _readFingerprint,
        databaseGenerationFactory =
            databaseGenerationFactory ?? _newDatabaseGeneration,
        securityLogger = securityLogger ??
            MatrixSecurityLogger.create(sink: (line) => debugPrint(line));

  static const clientName = 'liuhetong_mobile';
  static const databaseFileName = 'liuhetong_matrix.sqlite';

  /// 当前仍有初始化队列的数据库路径数（仅测试观察：证明确实按路径串行，
  /// 且队列排空后不残留条目）。
  @visibleForTesting
  static int get debugPendingInitLockCount =>
      _DatabaseInitLocks.pendingPathCount;

  final SecureSessionStore sessionStore;
  final Uri homeserver;
  final Future<String> Function() supportDirectoryPath;
  final MatrixClientOpener opener;
  final MatrixClientDisposer disposer;
  final MatrixDatabaseDeleter databaseDeleter;
  final MatrixClientMigrator clientMigrator;
  final String? Function(Client client) fingerprintReader;
  final String Function() databaseGenerationFactory;
  final MatrixSecurityLogger securityLogger;
  final MatrixDiagnosticHasher? diagnosticHasher;
  String? _unboundDatabaseGeneration;

  MatrixDiagnosticIdentity? _identity({
    String? matrixUserId,
    String? deviceId,
    String? previousDeviceId,
    String? databaseGeneration,
    String? fingerprint,
  }) =>
      diagnosticHasher?.of(
        matrixUserId: matrixUserId,
        deviceId: deviceId,
        previousDeviceId: previousDeviceId,
        databaseGeneration: databaseGeneration,
        fingerprint: fingerprint,
      );

  Future<String> _databasePath(String directory) async {
    final scope = await sessionStore.matrixStorageScope();
    return p.join(directory,
        scope.isEmpty ? databaseFileName : 'liuhetong_matrix_$scope.sqlite');
  }

  Future<void> selectAccount(String selectedHomeserver, String userId) async {
    if (selectedHomeserver != homeserver.toString()) {
      throw StateError('Matrix account homeserver mismatch');
    }
    await sessionStore.selectMatrixAccount(selectedHomeserver, userId);
    _unboundDatabaseGeneration = null;
  }

  Future<Client> create() async {
    final directory = await supportDirectoryPath();
    final databasePath = await _databasePath(directory);
    // 串行化必须在路径确定之后、打开数据库之前开始，并覆盖「打开 +
    // SDK 初始化（含 box_client 凭据写入）+ 迁移」的完整窗口。
    return _DatabaseInitLocks.run(databasePath, () async {
      if (await sessionStore.matrixClearPending()) {
        await _completePendingClear(databasePath);
      }
      final cipher = await sessionStore.matrixDatabaseKey();
      final client = await opener(
        clientName: clientName,
        databasePath: databasePath,
        cipher: cipher,
      );
      try {
        await clientMigrator(client, homeserver);
        return client;
      } catch (_) {
        await disposer(client);
        rethrow;
      }
    });
  }

  Future<MatrixClientContinuityMetadata> continuityMetadata(
      Client client) async {
    final binding = await sessionStore.matrixBinding();
    if (!client.isLogged() &&
        client.userID == null &&
        client.deviceID == null) {
      // A store without any session cannot honor a surviving binding: the
      // encrypted material the binding describes was destroyed out-of-band
      // (on iOS the Keychain scope/registry/binding outlive the sandbox
      // across reinstall while the database file does not). Keeping the
      // stale binding would reject every future login for this account
      // (L07), so reset it and adopt the empty store as a fresh identity.
      if (binding != null) {
        await sessionStore.clearMatrixBinding();
      }
      return MatrixClientContinuityMetadata(
        isLoggedIn: false,
        userId: null,
        deviceId: null,
        ed25519Fingerprint: null,
        databaseGeneration: _unboundDatabaseGeneration ??=
            databaseGenerationFactory(),
      );
    }
    final userId = client.userID;
    final deviceId = client.deviceID;
    final fingerprint = fingerprintReader(client);
    if (userId == null ||
        deviceId == null ||
        fingerprint == null ||
        fingerprint.isEmpty) {
      securityLogger.record(
        stage: MatrixSecurityStage.continuity,
        outcome: MatrixSecurityOutcome.failure,
        eventCode: MatrixSecurityCode.continuityIdentityUnavailable,
        identity: _identity(matrixUserId: userId, deviceId: deviceId),
      );
      throw StateError('Matrix continuity identity is unavailable');
    }
    final expectedHomeserver = homeserver.toString();
    if (binding == null) {
      final generation =
          _unboundDatabaseGeneration ??= databaseGenerationFactory();
      await sessionStore.saveMatrixBinding(MatrixLocalBinding(
        version: 2,
        matrixUserId: userId,
        deviceId: deviceId,
        homeserver: expectedHomeserver,
        databaseGeneration: generation,
        ed25519Fingerprint: fingerprint,
      ));
      return MatrixClientContinuityMetadata(
        isLoggedIn: client.isLogged(),
        userId: userId,
        deviceId: deviceId,
        ed25519Fingerprint: fingerprint,
        databaseGeneration: generation,
      );
    }
    final generation = binding.databaseGeneration;
    if (binding.matrixUserId != userId ||
        binding.homeserver != expectedHomeserver) {
      // 账号或 homeserver 不一致：这不是 device 轮换，而是真正的身份错配。
      securityLogger.record(
        stage: MatrixSecurityStage.continuity,
        outcome: MatrixSecurityOutcome.failure,
        eventCode: MatrixSecurityCode.continuityBindingMismatch,
        identity: _identity(
          matrixUserId: userId,
          deviceId: deviceId,
          previousDeviceId: binding.deviceId,
          databaseGeneration: generation,
        ),
      );
      throw StateError('Matrix client does not match the local binding');
    }
    if (binding.ed25519Fingerprint == null) {
      // Legacy v1 binding: record the identity this store actually holds.
      await sessionStore.saveMatrixBinding(MatrixLocalBinding(
        version: 2,
        matrixUserId: binding.matrixUserId,
        deviceId: deviceId,
        homeserver: binding.homeserver,
        databaseGeneration: binding.databaseGeneration,
        ed25519Fingerprint: fingerprint,
      ));
    } else if (binding.ed25519Fingerprint != fingerprint) {
      // Olm(Ed25519) 身份不同 = 真正的密码学身份错配，必须失败关闭。
      securityLogger.record(
        stage: MatrixSecurityStage.continuity,
        outcome: MatrixSecurityOutcome.failure,
        eventCode: MatrixSecurityCode.continuityFingerprintMismatch,
        identity: _identity(
          matrixUserId: userId,
          deviceId: deviceId,
          previousDeviceId: binding.deviceId,
          databaseGeneration: generation,
          fingerprint: fingerprint,
        ),
      );
      throw StateError('Matrix client does not match the local binding');
    } else if (binding.deviceId != deviceId) {
      // 只差 device id：单设备登录策略下服务端权威轮换。账号、homeserver、
      // Ed25519 fingerprint、databaseGeneration 全部一致，说明本地密码学身份
      // 没有变化，变化的只是服务端设备标签。补齐它，把 binding 与本机库对齐。
      securityLogger.record(
        stage: MatrixSecurityStage.deviceRotation,
        outcome: MatrixSecurityOutcome.success,
        eventCode: MatrixSecurityCode.deviceRotationDetected,
        identity: _identity(
          matrixUserId: userId,
          deviceId: deviceId,
          previousDeviceId: binding.deviceId,
          databaseGeneration: generation,
        ),
      );
      await sessionStore.adoptMatrixDeviceId(
        expectedUserId: userId,
        expectedHomeserver: expectedHomeserver,
        nextDeviceId: deviceId,
        ed25519Fingerprint: fingerprint,
      );
      securityLogger.record(
        stage: MatrixSecurityStage.deviceRotation,
        outcome: MatrixSecurityOutcome.success,
        eventCode: MatrixSecurityCode.deviceRotationBindingMigrated,
        identity: _identity(
          matrixUserId: userId,
          deviceId: deviceId,
          databaseGeneration: generation,
        ),
      );
    }
    return MatrixClientContinuityMetadata(
      isLoggedIn: client.isLogged(),
      userId: userId,
      deviceId: deviceId,
      ed25519Fingerprint: fingerprint,
      databaseGeneration: generation,
    );
  }

  /// 采纳一次由服务端 token 登录证明过的权威 device id 轮换。
  ///
  /// 调用方（[MatrixSdkE2eeClient.loginWithToken]）已经确认：
  /// server response 的 `user_id` 等于本机保留身份、token 登录成功、`device_id`
  /// 非空。这里再独立复核 client 的最终状态与 fingerprint，然后原子迁移 binding。
  /// 任何一项不成立都抛 [MatrixDeviceBindingRotationRejected]，并保留原 binding。
  Future<void> rotateDeviceBinding(
    Client client, {
    required String expectedUserId,
    required String previousDeviceId,
    required String nextDeviceId,
  }) async {
    final userId = client.userID;
    final deviceId = client.deviceID;
    final fingerprint = fingerprintReader(client);
    final identity = _identity(
      matrixUserId: userId,
      deviceId: deviceId,
      previousDeviceId: previousDeviceId,
    );
    if (userId != expectedUserId ||
        deviceId != nextDeviceId ||
        previousDeviceId.isEmpty ||
        nextDeviceId.isEmpty ||
        previousDeviceId == nextDeviceId ||
        fingerprint == null ||
        fingerprint.isEmpty) {
      securityLogger.record(
        stage: MatrixSecurityStage.deviceRotation,
        outcome: MatrixSecurityOutcome.failure,
        eventCode: MatrixSecurityCode.deviceRotationBindingRejected,
        identity: identity,
      );
      throw const MatrixDeviceBindingRotationRejected('unverified-client');
    }
    try {
      final migrated = await sessionStore.rotateMatrixDeviceBinding(
        expectedUserId: expectedUserId,
        expectedHomeserver: homeserver.toString(),
        previousDeviceId: previousDeviceId,
        nextDeviceId: nextDeviceId,
        ed25519Fingerprint: fingerprint,
      );
      securityLogger.record(
        stage: MatrixSecurityStage.deviceRotation,
        outcome: MatrixSecurityOutcome.success,
        eventCode: migrated == null
            // 还没有 binding：首次绑定由 continuityMetadata 建立，轮换无处可迁。
            ? MatrixSecurityCode.deviceRotationDetected
            : MatrixSecurityCode.deviceRotationBindingMigrated,
        identity: identity,
      );
    } on MatrixDeviceBindingRotationRejected {
      securityLogger.record(
        stage: MatrixSecurityStage.deviceRotation,
        outcome: MatrixSecurityOutcome.failure,
        eventCode: MatrixSecurityCode.deviceRotationBindingRejected,
        identity: identity,
      );
      rethrow;
    }
  }

  /// Closes the active handle while retaining the encrypted database, its key,
  /// and all local Olm/Megolm sessions for a later [create].
  Future<void> suspend(Client client) => disposer(client);

  Future<void> clearLocalChatData(Client? client) async {
    final directory = await supportDirectoryPath();
    final databasePath = await _databasePath(directory);
    await sessionStore.markMatrixClearPending();
    if (client != null) {
      // Explicit local clear is entirely local. SDK logout may issue an
      // unbounded homeserver request, so it must not delay deletion of this
      // device's SQLCipher store, device binding, or local keys.
      await disposer(client);
    }
    await _completePendingClear(databasePath);
  }

  Future<void> _completePendingClear(String databasePath) async {
    await databaseDeleter(databasePath);
    await sessionStore.clearMatrixIdentity();
    _unboundDatabaseGeneration = null;
    await sessionStore.clearMatrixClearPending();
  }

  static Future<String> _defaultSupportPath() async =>
      (await getApplicationSupportDirectory()).path;

  static Future<void> _disposeClient(Client client) => client.dispose();

  static Future<void> _deleteDatabase(String path) async {
    final databaseFactory = createDatabaseFactoryFfi(
      ffiInit: SQfLiteEncryptionHelper.ffiInit,
    );
    await databaseFactory.deleteDatabase(path);
  }

  static String? _readFingerprint(Client client) =>
      client.encryption?.fingerprintKey;

  static String _newDatabaseGeneration() => base64UrlEncode(
        List<int>.generate(24, (_) => Random.secure().nextInt(256)),
      );

  /// Retains the encrypted local database, sessions and room history while
  /// replacing only the persisted Matrix server endpoint.
  static Future<void> _migrateHomeserver(Client client, Uri homeserver) async {
    if (!client.isLogged() || client.homeserver == homeserver) return;
    final token = client.accessToken;
    final userId = client.userID;
    final deviceId = client.deviceID;
    final deviceName = client.deviceName;
    if (token == null ||
        userId == null ||
        deviceId == null ||
        deviceName == null) {
      return;
    }
    // The SDK has already initialized this persistent client. Re-initializing
    // would reject a logged-in client and can discard in-memory E2EE state.
    // Update only the endpoint record that the next sync consumes.
    client.homeserver = homeserver;
    final persistedClient = await client.database?.getClient(client.clientName);
    await client.database?.updateClient(
      homeserver.toString(),
      token,
      client.accessTokenExpiresAt,
      persistedClient?.tryGet<String>('refresh_token'),
      userId,
      deviceId,
      deviceName,
      client.prevBatch,
      client.encryption?.pickledOlmAccount,
    );
  }

  static Future<Client> _openPersistentClient({
    required String clientName,
    required String databasePath,
    required String cipher,
  }) async {
    final databaseFactory = createDatabaseFactoryFfi(
      ffiInit: SQfLiteEncryptionHelper.ffiInit,
    );
    final encryption = SQfLiteEncryptionHelper(
      factory: databaseFactory,
      path: databasePath,
      cipher: cipher,
    );
    await encryption.ensureDatabaseFileEncrypted();
    final client = Client(
      clientName,
      preserveStoreOnInvalidToken: true,
      // 弱网发送及时反馈（2026-09-19）：SDK 发送重试窗口从 1 分钟调紧到 20s，
      // 与 RoomTimelineController.sendDispatchTimeout 对齐——网络类失败在
      // ~20s 内转为红叹号（waitingNetwork，恢复后自动重发），而不是让
      // 房间发送队列的队首悬挂一分钟。上传大媒体的极端慢链路会提前失败
      // 并在恢复后自动重传（字节已在 cacheOutgoingMedia 落盘）。
      sendTimelineEventTimeout: const Duration(seconds: 20),
      // Broker-only login gate advertises token (and legacy password) flows;
      // declaring the token type here keeps checkHomeserver from rejecting the
      // homeserver when the legacy password advertisement is dropped.
      supportedLoginTypes: const {
        AuthenticationTypes.password,
        AuthenticationTypes.token,
      },
      verificationMethods: {
        KeyVerificationMethod.emoji,
        KeyVerificationMethod.numbers,
      },
      databaseBuilder: (_) async {
        final database = await databaseFactory.openDatabase(
          databasePath,
          options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey),
        );
        final matrixDatabase = MatrixSdkDatabase(
          clientName,
          database: database,
          sqfliteFactory: databaseFactory,
        );
        return initializeDatabase(matrixDatabase, database.close);
      },
    );
    return initializeClient(client);
  }

  @visibleForTesting
  static Future<Client> initializeClient(Client client) async {
    try {
      // Restore the encrypted local account and rooms before painting. The SDK
      // starts its first sync itself; a slow network must not hide cached data.
      await client.init(waitForFirstSync: false);
      return client;
    } catch (_) {
      await client.dispose();
      rethrow;
    }
  }

  @visibleForTesting
  static Future<MatrixSdkDatabase> initializeDatabase(
      MatrixSdkDatabase database, Future<void> Function() close) async {
    try {
      await database.open();
      return database;
    } catch (_) {
      await close();
      rethrow;
    }
  }
}
