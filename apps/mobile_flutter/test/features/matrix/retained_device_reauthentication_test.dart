import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/encryption.dart';
import 'package:matrix/encryption/olm_manager.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'matrix_client_factory_test.dart' show LogoutTrackingClient;

class RetainedOlm extends Fake implements OlmManager {
  int uploads = 0;
  bool succeed = true;
  @override
  Future<bool> uploadKeys(
      {bool uploadDeviceKeys = false,
      int? oldKeyCount = 0,
      bool updateDatabase = true,
      bool? unusedFallbackKey = false,
      String? dehydratedDeviceAlgorithm,
      String? dehydratedDevicePickleKey,
      int retry = 1}) async {
    expect(uploadDeviceKeys, isTrue);
    uploads++;
    return succeed;
  }
}

class RetainedEncryption extends Fake implements Encryption {
  @override
  final RetainedOlm olmManager = RetainedOlm();
  @override
  String? get pickledOlmAccount => 'existing-sealed-account';
}

class RetainedDevice extends LogoutTrackingClient {
  RetainedDevice(http.Client httpClient)
      : super('retained',
            loggedIn: false,
            matrixUserId: '@a:test',
            matrixDeviceId: 'original-device',
            httpClient: httpClient);
  @override
  final RetainedEncryption encryption = RetainedEncryption();
}

void main() {
  test(
      'suspended invalid credentials survive disk-token reopen and reauthenticate',
      () async {
    var logins = 0;
    final transport = MockClient((request) async {
      expect(request.url.path, endsWith('/login'));
      expect(jsonDecode(request.body)['device_id'], 'original-device');
      logins++;
      return http.Response(
          jsonEncode({
            'access_token': 'new-token',
            'user_id': '@a:test',
            'device_id': 'original-device'
          }),
          200,
          headers: {'content-type': 'application/json'});
    });
    final invalid = RetainedDevice(transport);
    invalid.onLoginStateChanged.add(LoginState.softLoggedOut);
    final reopened = RetainedDevice(transport)..loggedIn = true;
    final matrix = MatrixSdkE2eeClient(invalid,
        homeserver: Uri.parse('https://matrix.example'),
        suspendClient: (_) async {},
        resumeClient: () async => reopened,
        readContinuityMetadata: (client) async =>
            MatrixClientContinuityMetadata(
                isLoggedIn: client.isLogged(),
                userId: client.userID,
                deviceId: client.deviceID,
                ed25519Fingerprint: 'original-fingerprint',
                databaseGeneration: 'original-db'));
    await matrix.suspend();
    expect(matrix.credentialsInvalid, isTrue);
    await matrix.loginWithToken(
        loginToken: 'grant',
        homeserver: Uri.parse('https://matrix.example'),
        deviceId: 'original-device');
    expect(logins, 1);
    expect(reopened.encryption.olmManager.uploads, 1);
    expect(matrix.credentialsInvalid, isFalse);
    expect(reopened.logoutCalls, 0);
  });
  for (final succeeds in [true, false]) {
    test(
        'soft logout restores existing public device keys; upload success=$succeeds',
        () async {
      var tokenLogins = 0;
      final client = RetainedDevice(MockClient((request) async {
        expect(request.url.path, endsWith('/login'));
        expect(jsonDecode(request.body)['device_id'], 'original-device');
        tokenLogins++;
        return http.Response(
            jsonEncode({
              'access_token': 'new-token',
              'user_id': '@a:test',
              'device_id': 'original-device'
            }),
            200,
            headers: {'content-type': 'application/json'});
      }));
      client.encryption.olmManager.succeed = succeeds;
      client.onLoginStateChanged.add(LoginState.softLoggedOut);
      final matrix = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://matrix.example'),
          readContinuityMetadata: (_) async =>
              const MatrixClientContinuityMetadata(
                  isLoggedIn: true,
                  userId: '@a:test',
                  deviceId: 'original-device',
                  ed25519Fingerprint: 'original-fingerprint',
                  databaseGeneration: 'original-db'));
      expect(matrix.credentialsInvalid, isTrue);
      final operation = matrix.loginWithToken(
          loginToken: 'grant',
          homeserver: Uri.parse('https://matrix.example'),
          deviceId: 'original-device');
      if (succeeds) {
        await operation;
      } else {
        await expectLater(operation, throwsStateError);
      }
      expect(tokenLogins, 1);
      expect(client.encryption.olmManager.uploads, 1);
      expect(matrix.credentialsInvalid, !succeeds);
      expect(client.logoutCalls, 0);
    });
  }
}
