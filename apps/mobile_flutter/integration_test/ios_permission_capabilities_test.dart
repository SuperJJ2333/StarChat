import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:permission_handler/permission_handler.dart';

// CI installs this isolated app, grants these permissions using simctl, then
// starts it without uninstalling. Disabled plugin strategies return denied even
// with OS grants, so this exercises real native code rather than a mock channel.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native permission strategies honor actual iOS grants',
      (_) async {
    expect(Platform.isIOS, isTrue);
    for (final permission in [
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
