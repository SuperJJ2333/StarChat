import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/client_init_exception.dart';
import 'package:olm/olm.dart' as olm;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/retained_recovery_identity_fixture.dart';

class _Storage implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(olm.init);
  for (final scenario in [
    'startup',
    'held first continuity',
    'held rotation',
    'same device',
    'post-persistence failure',
    'late foreign user',
    'corrupt binding',
    'provisional credentials',
    'provisional credentials without preserve'
  ]) {
    test('real retained SDK $scenario preserves original encrypted history',
        () async {
      SharedPreferences.setMockInitialValues({});
      final root = Directory(p.absolute(
          '../../docs/verification/artifacts/2026-10-04/history-anchor-media-ios'));
      final directory = await root.createTemp('task2-continuity-');
      final sessions = SecureSessionStore(_Storage());
      await sessions.selectMatrixAccount(
          RetainedRecoveryIdentityFixture.endpoint.toString(),
          RetainedRecoveryIdentityFixture.user);
      final fixture = RetainedRecoveryIdentityFixture(
          p.join(directory.path, 'retained.sqlite'),
          await sessions.matrixDatabaseKey(),
          sessions,
          preserveStoreOnInvalidToken: !scenario.endsWith('without preserve'));
      await fixture.openClient(seed: true);
      await fixture.seedHistory();
      final fingerprint = fixture.client.fingerprintKey;
      await fixture.client.dispose();
      await fixture.openClient();
      fixture.wrap();
      try {
        if (scenario == 'startup') await fixture.expectHistory();
        if (scenario == 'held first continuity') {
          final owner = fixture.client.recoveryOwner!;
          fixture.database.hold = true;
          final write = owner.write(
              () => fixture.database.storeRecoveryRecord('held', {'v': 1}));
          await fixture.database.entered.future;
          try {
            await expectLater(fixture.matrix.currentSessionCredentials(),
                throwsA(isA<TimeoutException>()));
            expect(owner.active, isFalse);
            expect(identical(fixture.client.recoveryOwner, owner), isTrue);
            expect(fixture.closes, 0);
            expect(() => owner.write(() async {}), throwsStateError);
          } finally {
            fixture.database.release.complete();
            await write;
          }
          await fixture.expectHistory();
        }
        if (scenario == 'held rotation') await fixture.rotateAfterHeldWrite();
        if (scenario == 'same device') {
          await fixture.renew();
          expect(fixture.client.deviceID, 'RETAINED');
          await fixture.expectHistory();
        }
        if (scenario == 'post-persistence failure') {
          fixture.responseDevice = 'ROTATED';
          fixture.failUpload = true;
          await expectLater(
              fixture.renew(),
              throwsA(isA<Exception>().having((error) => error.toString(),
                  'HTTP failure', 'Exception: http error response')));
          expect(fixture.client.deviceID, 'ROTATED');
          expect(
              (await fixture.database.getClient(
                  RetainedRecoveryIdentityFixture.clientName))?['device_id'],
              'ROTATED');
          expect(fixture.client.encryption!.olmManager.ourDeviceId, 'ROTATED');
          expect(fixture.client.fingerprintKey == fingerprint, isTrue);
          fixture.failUpload = false;
          await fixture.renew();
          expect((await sessions.matrixBinding())?.deviceId, 'ROTATED');
          await fixture.expectHistory();
        }
        if (scenario == 'corrupt binding') {
          await fixture.matrix.currentSessionCredentials();
          final binding = (await sessions.matrixBinding())!;
          await sessions.saveMatrixBinding(MatrixLocalBinding(
              version: 2,
              matrixUserId: binding.matrixUserId,
              deviceId: binding.deviceId,
              homeserver: binding.homeserver,
              databaseGeneration: binding.databaseGeneration,
              ed25519Fingerprint: 'synthetic-corrupt-fingerprint'));
          await expectLater(fixture.factory.continuityMetadata(fixture.client),
              throwsStateError);
          expect(fixture.client.fingerprintKey == fingerprint, isTrue);
          await sessions.saveMatrixBinding(binding);
        }
        if (scenario == 'late foreign user') {
          await fixture.matrix.currentSessionCredentials();
          final owner = fixture.client.recoveryOwner!;
          final before = jsonEncode(await fixture.database
              .getClient(RetainedRecoveryIdentityFixture.clientName));
          fixture.responseUser = '@foreign:synthetic.example.test';
          fixture.loginEntered = Completer<void>();
          fixture.loginRelease = Completer<void>();
          final rejected = expectLater(fixture.renew(), throwsStateError);
          await fixture.loginEntered!.future;
          await expectLater(fixture.matrix.suspend(), throwsStateError);
          expect(fixture.closes, 0);
          fixture.loginRelease!.complete();
          await rejected;
          expect(owner.active, isFalse);
          expect(fixture.client.userID, RetainedRecoveryIdentityFixture.user);
          expect(
              jsonEncode(await fixture.database
                      .getClient(RetainedRecoveryIdentityFixture.clientName)) ==
                  before,
              isTrue);
          fixture.loginEntered = fixture.loginRelease = null;
          fixture.responseUser = RetainedRecoveryIdentityFixture.user;
          await fixture.renew();
        }
        if (scenario.startsWith('provisional credentials')) {
          await fixture.matrix.currentSessionCredentials();
          final active = fixture.client;
          final owner = active.recoveryOwner!;
          final before = (
            token: active.accessToken,
            expiry: active.accessTokenExpiresAt,
            user: active.userID,
            device: active.deviceID,
            name: active.deviceName,
            endpoint: active.homeserver,
            batch: active.prevBatch,
            id: active.id,
            group: active.groupCallSessionId
          );
          final durable = jsonEncode(await fixture.database
              .getClient(RetainedRecoveryIdentityFixture.clientName));
          fixture.database.hold = true;
          final write = owner.write(
              () => fixture.database.storeRecoveryRecord('held', {'v': 1}));
          await fixture.database.entered.future;
          active.onLoginStateChanged.add(LoginState.softLoggedOut);
          final retainedOlm = active.encryption!.pickledOlmAccount;
          try {
            await expectLater(
                active.init(
                    newToken: 'synthetic-provisional',
                    newRefreshToken: 'synthetic-provisional-refresh',
                    newTokenExpiresAt: DateTime.utc(2050),
                    newHomeserver:
                        Uri.parse('https://other.synthetic.example.test'),
                    newUserID: '@other:synthetic.example.test',
                    newDeviceID: 'OTHER',
                    newOlmAccount: 'synthetic-provisional-pickle',
                    newDeviceName: 'provisional-device'),
                throwsA(isA<ClientInitException>().having(
                    (error) => error.olmAccount == retainedOlm,
                    'retained retry identity',
                    true)));
            expect(
                (
                      token: active.accessToken,
                      expiry: active.accessTokenExpiresAt,
                      user: active.userID,
                      device: active.deviceID,
                      name: active.deviceName,
                      endpoint: active.homeserver,
                      batch: active.prevBatch,
                      id: active.id,
                      group: active.groupCallSessionId
                    ) ==
                    before,
                isTrue);
            expect(
                jsonEncode(await fixture.database.getClient(
                        RetainedRecoveryIdentityFixture.clientName)) ==
                    durable,
                isTrue);
            expect(active.fingerprintKey == fingerprint, isTrue);
            expect(owner.active, isFalse);
          } finally {
            fixture.database.release.complete();
            await write;
          }
          await fixture.renew();
        }
        await fixture.matrix.suspend();
        await fixture.renew();
        expect(fixture.client.fingerprintKey == fingerprint, isTrue);
        await fixture.expectHistory();
        await fixture.matrix.selectAccount(RetainedRecoveryIdentityFixture.user,
            RetainedRecoveryIdentityFixture.endpoint);
        await fixture.renew();
        expect(fixture.client.fingerprintKey == fingerprint, isTrue);
        await fixture.expectHistory();
      } finally {
        await fixture.client.recoveryOwner?.drain();
        await fixture.client.dispose();
        await directory.delete(recursive: true);
      }
    });
  }
}
