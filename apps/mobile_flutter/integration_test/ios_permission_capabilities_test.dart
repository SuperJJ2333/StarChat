import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:permission_handler/permission_handler.dart';

// CI starts this isolated app, grants permissions after its READY handshake,
// then acknowledges the fixture. Disabled plugin strategies return denied even
// with OS grants, so this exercises real native code rather than a mock channel.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native permission strategies honor actual iOS grants',
      (_) async {
    expect(Platform.isIOS, isTrue);
    // flutter test reinstalls the app before launch. The host must grant the
    // permissions after that installation, then acknowledge this handshake.
    const fixture = String.fromEnvironment('PERMISSION_FIXTURE_ID');
    expect(fixture, isNotEmpty);
    final ready = File('${Directory.systemTemp.path}/permission-fixture-$fixture');
    if (await ready.exists()) await ready.delete();
    debugPrint('PERMISSION_FIXTURE_READY:$fixture');
    await (() async {
      while (!await ready.exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    })().timeout(const Duration(seconds: 60));
    if (!const bool.fromEnvironment('SIMULATOR_CAMERA_SUPPORTED')) {
      // simctl versions without camera fixtures cannot prove its TCC state.
      // Camera remains mandatory in the Pod hook and signed IPA method gates.
      debugPrint(
          'Camera runtime grant unavailable in this simulator; device prompt validation remains pending.');
    }
    for (final permission in [
      if (const bool.fromEnvironment('SIMULATOR_CAMERA_SUPPORTED'))
        Permission.camera,
      Permission.microphone,
      Permission.photos,
      Permission.photosAddOnly,
    ]) {
      expect(await permission.status, PermissionStatus.granted,
          reason: '$permission must read the pre-granted native authorization');
      expect(await permission.request(), PermissionStatus.granted,
          reason: '$permission must use the native strategy, not the stub');
    }
  });
}
