import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:permission_handler/permission_handler.dart';

// CI installs this app once, grants permissions, then launches it and attaches
// the driver without reinstalling. Disabled plugin strategies return denied even
// with OS grants, so this exercises real native code rather than a mock channel.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native audio and supported camera honor actual iOS grants',
      (_) async {
    expect(Platform.isIOS, isTrue);
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
    ]) {
      expect(await permission.status, PermissionStatus.granted,
          reason: '$permission must read the pre-granted native authorization');
      expect(await permission.request(), PermissionStatus.granted,
          reason: '$permission must use the native strategy, not the stub');
    }
    // simctl grants legacy Photos authorization (version 1). On this runtime,
    // PhotoKit's access-level preflight asks for version 2 and returns unknown.
    // These are diagnostics, not a passing Photos authorization assertion.
    // Pod/IPA checks remain required; first-request Photos UI needs a device.
    debugPrint('Photos device acceptance pending: '
        'readWrite=${await Permission.photos.status}, '
        'addOnly=${await Permission.photosAddOnly.status}');
  });
}
