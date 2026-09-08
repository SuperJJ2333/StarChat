import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/ui/theme/theme_controller.dart';
import 'package:matrix/matrix.dart';

final class _ThemeStore implements ThemePreferenceStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
}

void main() {
  test('suspend drains delayed initialization before next session handler',
      () async {
    final scope = AppHomeStartupScope();
    final release = Completer<void>();
    final started = Completer<void>();
    final writes = <String>[];
    scope.open();
    final first = scope.run((generation) async {
      started.complete();
      await release.future;
      if (!scope.isCurrent(generation)) return;
      writes.add('old handler');
    });
    await started.future;
    var closed = false;
    final closing = scope.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    expect(scope.open, throwsStateError);
    release.complete();
    await first;
    await closing;
    scope.open();
    await scope.run((generation) async {
      if (scope.isCurrent(generation)) writes.add('new handler');
    });
    expect(writes, ['new handler']);
    await scope.close();
  });

  testWidgets('immediate AppHome removal cancels late Matrix resource setup',
      (tester) async {
    final matrix = MatrixSdkE2eeClient(
      Client('app-home'),
      homeserver: Uri.parse('https://matrix.test'),
    );
    final blockerStarted = Completer<void>();
    final allowBlocker = Completer<void>();
    final blockerRegistration = matrix.registerVerificationLifecycle(
      open: () async {
        blockerStarted.complete();
        await allowBlocker.future;
      },
      close: () async {},
      revoke: () {},
    );
    await blockerStarted.future;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.test'),
      sessionStore: SecureSessionStore(),
    );

    await tester.pumpWidget(CupertinoApp(
      home: AppHome(
        api: api,
        matrix: matrix,
        onLogout: () async {},
        themeController: ThemeController(store: _ThemeStore()),
      ),
    ));
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    allowBlocker.complete();
    final blocker = await blockerRegistration;
    await blocker.cancel();
    await tester.pump();

    expect(matrix.debugManagedResourceCount, 0);
  });
}
