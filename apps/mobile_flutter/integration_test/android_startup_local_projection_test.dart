import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:olm/olm.dart' as olm;
import 'package:path/path.dart' as p;
import '../test/core/startup_local_projection_entry_test.dart' as scenario;
import '../test/support/retained_recovery_identity_fixture.dart';
import '../test/features/matrix/room_key_share_session_test.dart' as key_share;

class _SyntheticSecureStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final scenarios = <Map<String, Object>>[];
  scenario.registerStartupProjectionEntryTests(report: (data) {
    scenarios.add(data);
    binding.reportData = {
      'scenarios': scenarios,
      'completed_scenarios': scenarios.length
    };
  });
  testWidgets('native retained rotation keeps the Olm database after reopen',
      (_) async {
    expect(Platform.isAndroid, isTrue);
    await olm.init();
    final directory =
        await Directory.systemTemp.createTemp('native-retained-rotation-');
    final sessions = SecureSessionStore(_SyntheticSecureStore());
    await sessions.selectMatrixAccount(
        RetainedRecoveryIdentityFixture.endpoint.toString(),
        RetainedRecoveryIdentityFixture.user);
    final fixture = RetainedRecoveryIdentityFixture(
        p.join(directory.path, 'retained.sqlite'),
        await sessions.matrixDatabaseKey(),
        sessions);
    var opened = false;
    try {
      await fixture.openClient(seed: true);
      opened = true;
      await fixture.seedHistory();
      fixture.wrap();
      fixture.responseDevice = 'ROTATED';
      await fixture.renew();
      await fixture.expectRotatedOlmPersistence();
      await key_share.verifyRoomKeyShareScenario('roundtrip');
      await key_share
          .verifyRoomKeyShareScenario('legacy missing authorization');
      await key_share.verifyRoomKeyShareScenario('precommit revocation');
      binding.reportData = {
        ...?binding.reportData,
        'retained_rotation_olm_reopen_verified': true,
        'room_key_share_roundtrip_verified': true
      };
    } finally {
      if (opened) {
        await fixture.client.recoveryOwner?.drain();
        await fixture.client.dispose();
      }
      await directory.delete(recursive: true);
    }
  });
}
