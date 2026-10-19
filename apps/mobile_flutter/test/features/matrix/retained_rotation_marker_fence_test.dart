import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:matrix/encryption/encryption.dart';
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
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(olm.init);
  for (final mode in [
    'write failure',
    'owner revoked after write',
    'owner replaced after write',
    'database replaced after write',
    'encryption replaced after write',
    'wrong account',
    'empty account',
    'outer mismatch',
    'inner mismatch',
    'dehydrated markers',
  ]) {
    test('real retained rotation does not promote $mode', () async {
      SharedPreferences.setMockInitialValues({});
      final root = Directory(p.absolute(
          '../../docs/verification/artifacts/2026-10-04/history-anchor-media-ios'));
      final directory = await root.createTemp('rotation-marker-');
      final sessions = SecureSessionStore(_Storage());
      await sessions.selectMatrixAccount(
          RetainedRecoveryIdentityFixture.endpoint.toString(),
          RetainedRecoveryIdentityFixture.user);
      final fixture = RetainedRecoveryIdentityFixture(
          p.join(directory.path, 'retained.sqlite'),
          await sessions.matrixDatabaseKey(),
          sessions);
      await fixture.openClient(seed: true);
      fixture.wrap();
      await fixture.matrix.currentSessionCredentials();
      final active = fixture.client;
      final encryption = active.encryption!;
      final manager = encryption.olmManager;
      final owners = <RecoveryOperationOwner>[];
      try {
        if (mode == 'empty account') {
          // Exercise the SDK boundary without the application's stricter
          // identity-adoption hook admitting an empty business identity.
          active.onRecoveryIdentityAdopted = null;
          active.onLoginStateChanged.add(LoginState.softLoggedOut);
          await active.init(
              newToken: 'synthetic-empty',
              newHomeserver: RetainedRecoveryIdentityFixture.endpoint,
              newUserID: '',
              newDeviceID: 'RETAINED',
              newDeviceName: 'synthetic-empty');
        }
        if (mode == 'outer mismatch' || mode == 'dehydrated markers') {
          encryption.ourDeviceId = 'DEHYDRATED';
        }
        if (mode == 'inner mismatch' || mode == 'dehydrated markers') {
          manager.ourDeviceId = 'DEHYDRATED';
        }
        final outerBefore = encryption.ourDeviceId;
        final innerBefore = manager.ourDeviceId;
        if (mode == 'write failure') {
          fixture.database.beforeClientUpdate =
              () async => throw StateError('synthetic persistence failure');
        }
        fixture.database.afterClientUpdate = () async {
          final owner = active.recoveryOwner;
          if (owner != null) owners.add(owner);
          switch (mode) {
            case 'owner revoked after write':
              owner?.revoke();
            case 'owner replaced after write':
              active.recoveryOwner = null;
            case 'database replaced after write':
              active.replaceDatabase = true;
            case 'encryption replaced after write':
              active.replacementEncryption = Encryption(client: active);
              active.replaceEncryption = true;
          }
        };
        active.onLoginStateChanged.add(LoginState.softLoggedOut);
        final adoption = active.init(
            newToken: 'synthetic-rotated',
            newHomeserver: RetainedRecoveryIdentityFixture.endpoint,
            newUserID: mode == 'empty account'
                ? ''
                : mode == 'wrong account'
                    ? '@foreign:synthetic.example.test'
                    : RetainedRecoveryIdentityFixture.user,
            newDeviceID: 'ROTATED',
            newDeviceName: 'synthetic-retained');
        if (mode.endsWith('mismatch') ||
            mode == 'dehydrated markers' ||
            mode == 'empty account' ||
            mode == 'wrong account') {
          // The application rejects a foreign broker user before SDK init.
          // At this lower SDK boundary, assert no retained crypto promotion.
          await adoption;
        } else {
          await expectLater(adoption,
              throwsA(anyOf(isA<StateError>(), isA<ClientInitException>())));
        }
        expect(encryption.ourDeviceId, outerBefore);
        expect(manager.ourDeviceId, innerBefore);
      } finally {
        active.replaceDatabase = false;
        active.replaceEncryption = false;
        fixture.database.beforeClientUpdate = null;
        fixture.database.afterClientUpdate = null;
        for (final owner in owners) {
          owner.revoke();
          await owner.drain();
        }
        await active.dispose();
        await directory.delete(recursive: true);
      }
    });
  }
}
