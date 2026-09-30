import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const badge = MethodChannel('chatflow/badge');

  testWidgets('native room notification cancellation validates opaque room IDs',
      (tester) async {
    expect(Platform.isIOS, isTrue);
    await expectLater(
      badge.invokeMethod<void>('clearConversation', {'roomId': ''}),
      throwsA(isA<PlatformException>()
          .having((error) => error.code, 'code', 'INVALID_ROOM')),
    );
    // Calls the production UNUserNotificationCenter bridge, not a mock channel.
    // Exact matching and preservation of other rooms/calls are tested in Swift.
    expect(
        await badge.invokeMethod<bool>('clearConversation',
            {'roomId': '!notification-test:local.invalid'}),
        isTrue);
    expect(await badge.invokeMethod<bool>('updateCount', {'count': 2}), isTrue);
    expect(await badge.invokeMethod<bool>('clear'), isTrue);
  });
}
