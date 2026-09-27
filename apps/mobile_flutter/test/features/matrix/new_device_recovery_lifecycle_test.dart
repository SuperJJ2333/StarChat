import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/local_identity_preflight.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';
import 'package:matrix/matrix.dart';

const _home = 'https://matrix.example.test';
const _user = '@alice:matrix.example.test';

Future<MatrixClientContinuityMetadata> _blankMetadata(Client client) async =>
    const MatrixClientContinuityMetadata(
      isLoggedIn: false,
      userId: null,
      deviceId: null,
      ed25519Fingerprint: null,
      databaseGeneration: 'new-generation',
    );

/// The real SDK's Client.login calls init before returning its response.
/// This probe makes that premature local write observable in the test.
final class _NewDeviceLoginProbe extends Client {
  _NewDeviceLoginProbe(http.Client server)
      : super('fresh-login-probe', httpClient: server);

  int sdkLoginCalls = 0;
  int localIdentityWrites = 0;
  int keyUploads = 0;
  String? storedUserId;
  String? storedDeviceId;

  @override
  String? get userID => storedUserId;

  @override
  String? get deviceID => storedDeviceId;

  @override
  Future<
      (
        DiscoveryInformation?,
        GetVersionsResponse,
        List<LoginFlow>,
      )> checkHomeserver(
    Uri homeserverUrl, {
    bool checkWellKnown = true,
    Set<String>? overrideSupportedVersions,
  }) async =>
      (null, GetVersionsResponse(versions: const []), const <LoginFlow>[]);

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
    sdkLoginCalls++;
    final response = LoginResponse(
      accessToken: 'wrong-account-token',
      deviceId: 'wrong-account-device',
      userId: '@mallory:matrix.example.test',
    );
    await init(
      newToken: response.accessToken,
      newHomeserver: Uri.parse(_home),
      newUserID: response.userId,
      newDeviceID: response.deviceId,
      newDeviceName: '畅聊移动端',
    );
    keyUploads++;
    return response;
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
    localIdentityWrites++;
    storedUserId = newUserID;
    storedDeviceId = newDeviceID;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('wrong server MXID cannot initialize or upload a fresh device',
      () async {
    var loginRequests = 0;
    final server = MockClient((request) async {
      if (!request.url.path.endsWith('/login')) {
        return http.Response('{}', 404);
      }
      loginRequests++;
      return http.Response(
        jsonEncode({
          'access_token': 'wrong-account-token',
          'device_id': 'wrong-account-device',
          'user_id': '@mallory:matrix.example.test',
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    final fresh = _NewDeviceLoginProbe(server);
    var continuityReads = 0;
    final matrix = MatrixSdkE2eeClient(
      Client('old'),
      homeserver: Uri.parse(_home),
      suspendClient: (_) async {},
      prepareNewDeviceStorage: (_, __) async {},
      selectClientAccount: (_, __) async {},
      resumeClient: () async => fresh,
      readContinuityMetadata: (client) async {
        if (identical(client, fresh)) continuityReads++;
        return _blankMetadata(client);
      },
    );

    await matrix.confirmNewDeviceRecovery(_user, Uri.parse(_home));
    expect(continuityReads, 1);
    await expectLater(
      matrix.loginWithToken(
          loginToken: 'one-time-token', homeserver: Uri.parse(_home)),
      throwsStateError,
    );
    expect(loginRequests, 1);
    expect(fresh.sdkLoginCalls, 0);
    expect(fresh.localIdentityWrites, 0);
    expect(fresh.keyUploads, 0);
    expect(continuityReads, 2,
        reason: 'selection and fail-closed suspend only, no login binding');
    expect(matrix.debugHasActiveClient, isFalse);
    await expectLater(matrix.syncIfActive(), throwsStateError);
  });

  test('matching server MXID initializes the confirmed fresh device once',
      () async {
    var requests = 0;
    final server = MockClient((request) async {
      requests++;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['device_id'], isNull);
      return http.Response(
        jsonEncode({
          'access_token': 'fresh-access-token',
          'device_id': 'fresh-device',
          'user_id': _user,
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    final fresh = _NewDeviceLoginProbe(server);
    final matrix = MatrixSdkE2eeClient(
      Client('old'),
      homeserver: Uri.parse(_home),
      suspendClient: (_) async {},
      prepareNewDeviceStorage: (_, __) async {},
      selectClientAccount: (_, __) async {},
      resumeClient: () async => fresh,
      readContinuityMetadata: _blankMetadata,
    );

    await matrix.confirmNewDeviceRecovery(_user, Uri.parse(_home));
    await matrix.loginWithToken(
        loginToken: 'one-time-token', homeserver: Uri.parse(_home));
    expect(requests, 1);
    expect(fresh.sdkLoginCalls, 0);
    expect(fresh.localIdentityWrites, 1);
    expect(fresh.storedUserId, _user);
    expect(fresh.storedDeviceId, 'fresh-device');
  });

  test('later blank-scope login still checks MXID before SDK initialization',
      () async {
    var requests = 0;
    final server = MockClient((request) async {
      requests++;
      return http.Response(
        jsonEncode({
          'access_token': 'wrong-account-token',
          'device_id': 'wrong-device',
          'user_id': '@mallory:matrix.example.test',
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    final fresh = _NewDeviceLoginProbe(server);
    final matrix = MatrixSdkE2eeClient(
      Client('old'),
      homeserver: Uri.parse(_home),
      suspendClient: (_) async {},
      selectClientAccount: (_, __) async {},
      resumeClient: () async => fresh,
      readContinuityMetadata: _blankMetadata,
    );

    await matrix.selectAccount(_user, Uri.parse(_home));
    await expectLater(
      matrix.loginWithTokenForExpectedIdentity(
        expectedMatrixUserId: _user,
        loginToken: 'one-time-token',
        homeserver: Uri.parse(_home),
      ),
      throwsStateError,
    );
    expect(requests, 1);
    expect(fresh.sdkLoginCalls, 0);
    expect(fresh.localIdentityWrites, 0);
    expect(fresh.keyUploads, 0);
    expect(matrix.debugHasActiveClient, isFalse);
    await expectLater(matrix.syncIfActive(), throwsStateError);
  });

  test('conclusive preflight becomes a recovery choice without opening SDK',
      () async {
    var resumed = 0;
    final matrix = MatrixSdkE2eeClient(
      Client('old'),
      homeserver: Uri.parse(_home),
      suspendClient: (_) async {},
      selectClientAccount: (_, __) async =>
          throw const MatrixLocalIdentityPreflightException(
              MatrixLocalIdentityCause.fingerprintMismatch,
              canCreateNewDevice: true),
      resumeClient: () async {
        resumed++;
        return Client('new');
      },
      readContinuityMetadata: _blankMetadata,
    );

    await expectLater(matrix.selectAccount(_user, Uri.parse(_home)),
        throwsA(isA<MatrixNewDeviceRecoveryRequired>()));
    expect(resumed, 0);
  });

  test('unreadable preflight cannot offer new-device recovery', () async {
    final matrix = MatrixSdkE2eeClient(
      Client('old'),
      homeserver: Uri.parse(_home),
      suspendClient: (_) async {},
      selectClientAccount: (_, __) async =>
          throw const MatrixLocalIdentityPreflightException(
              MatrixLocalIdentityCause.unreadable),
      resumeClient: () async => Client('new'),
      readContinuityMetadata: _blankMetadata,
    );

    await expectLater(matrix.selectAccount(_user, Uri.parse(_home)),
        throwsA(isA<MatrixLocalIdentityPreflightException>()));
  });

  test('safe startup shell never reads or clears the old binding', () async {
    final safeShell = Client('safe-shell');
    final freshClient = Client('fresh');
    var retainedBinding = 'old-binding';
    var oldBindingReads = 0;
    var selections = 0;
    var resumes = 0;
    final matrix = MatrixSdkE2eeClient(
      safeShell,
      homeserver: Uri.parse(_home),
      suspendClient: (_) async {},
      readContinuityMetadata: (client) async {
        if (identical(client, safeShell)) {
          // main's safe-shell callback must refuse continuity reads before
          // MatrixClientFactory can clear a surviving Keychain binding.
          throw StateError('Safe shell has no trusted local identity');
        }
        oldBindingReads++;
        return _blankMetadata(client);
      },
      prepareNewDeviceStorage: (_, __) async {
        expect(retainedBinding, 'old-binding');
      },
      selectClientAccount: (_, __) async {
        selections++;
        if (selections == 1) {
          throw const MatrixLocalIdentityPreflightException(
              MatrixLocalIdentityCause.fingerprintMismatch,
              canCreateNewDevice: true);
        }
      },
      resumeClient: () async {
        resumes++;
        return freshClient;
      },
    );

    await expectLater(matrix.selectAccount(_user, Uri.parse(_home)),
        throwsA(isA<MatrixNewDeviceRecoveryRequired>()));
    expect(resumes, 0);
    expect(oldBindingReads, 0);
    expect(retainedBinding, 'old-binding');

    await matrix.confirmNewDeviceRecovery(_user, Uri.parse(_home));
    expect(resumes, 1);
    expect(oldBindingReads, 1,
        reason: 'only the fresh client may read continuity metadata');
    expect(retainedBinding, 'old-binding');
  });

  test('confirmed recovery closes old client before archive and fresh resume',
      () async {
    final operations = <String>[];
    final oldClient = Client('old');
    final freshClient = Client('fresh');
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse(_home),
      suspendClient: (_) async => operations.add('suspend'),
      prepareNewDeviceStorage: (homeserver, userId) async {
        expect(homeserver, _home);
        expect(userId, _user);
        operations.add('archive');
      },
      selectClientAccount: (homeserver, userId) async {
        expect(homeserver, _home);
        expect(userId, _user);
        operations.add('select');
      },
      resumeClient: () async {
        operations.add('resume');
        return freshClient;
      },
      readContinuityMetadata: _blankMetadata,
    );

    await matrix.confirmNewDeviceRecovery(_user, Uri.parse(_home));
    expect(operations, ['suspend', 'archive', 'select', 'resume']);
  });

  test('archive failure never selects or opens a fresh client', () async {
    final operations = <String>[];
    final matrix = MatrixSdkE2eeClient(
      Client('old'),
      homeserver: Uri.parse(_home),
      suspendClient: (_) async => operations.add('suspend'),
      prepareNewDeviceStorage: (_, __) async {
        operations.add('archive');
        throw StateError('archive unavailable');
      },
      selectClientAccount: (_, __) async => operations.add('select'),
      resumeClient: () async {
        operations.add('resume');
        return Client('fresh');
      },
      readContinuityMetadata: _blankMetadata,
    );

    await expectLater(matrix.confirmNewDeviceRecovery(_user, Uri.parse(_home)),
        throwsStateError);
    expect(operations, ['suspend', 'archive']);
  });
}
