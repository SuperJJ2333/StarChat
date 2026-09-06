import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart';
import 'package:liuhetong_mobile/features/matrix/call_ui_manager.dart';
import 'package:liuhetong_mobile/features/matrix/call_notifications.dart';

import 'call_controller_test.dart' as support;

final class Permissions implements CallPermissionGateway {
  bool allowed = false;
  final requests = <bool>[];
  @override
  Future<bool> request({required bool video}) async {
    requests.add(video);
    return allowed;
  }
}

void main() {
  for (final type in CallMediaType.values) {
    testWidgets('$type incoming denial preserves answer, reject and settings',
        (tester) async {
      final permissions = Permissions();
      final backend = support.FakeCallBackend();
      final controller = CallController(
          backend: backend,
          permissions: permissions,
          alerts: support.RecordingCallAlerts(),
          soundCues: support.RecordingCallSoundCues());
      final key = GlobalKey<NavigatorState>();
      final notifications = RecordingNotifications();
      var resumed = false;
      final manager = CallUiManager(
          navigatorKey: key,
          notifications: notifications,
          isAppResumed: () => resumed)
        ..attach(controller);
      await tester.pumpWidget(
          CupertinoApp(navigatorKey: key, home: const Text('home')));
      backend.events.add(CallBackendEvent.incoming(
          roomId: '!dm:test', matrixUserId: '@peer:test', type: type));
      await tester.pump();
      expect(permissions.requests, isEmpty);
      expect(notifications.incoming, 1);
      await controller.accept();
      expect(controller.state.phase, CallPhase.ringing);
      expect(backend.rejects, 0);
      expect(backend.accepts, 0);
      expect(permissions.requests, [type == CallMediaType.video]);
      expect(notifications.incoming, 2,
          reason: 'denial retains an actionable background notification');
      resumed = true;
      manager.handleAppResumed();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('call-control-answer')), findsOneWidget);
      expect(find.byKey(const Key('call-control-reject')), findsOneWidget);
      expect(find.byKey(const Key('call-permission-settings')), findsOneWidget);
      expect(find.textContaining('授权'), findsOneWidget);
      permissions.allowed = true;
      await controller.accept();
      expect(backend.accepts, 1);
      expect(controller.state.phase, CallPhase.connecting);
      expect(controller.state.message, isNull);
      await controller.hangup();
      await tester.pump(const Duration(seconds: 3));
      await manager.detach();
      controller.dispose();
      await backend.events.close();
    });
  }
}

final class RecordingNotifications implements CallNotificationGateway {
  int incoming = 0;
  @override
  Future<void> showIncoming(
      {required String callerName,
      bool video = false,
      bool ring = true,
      bool fullScreenIntent = true}) async {
    incoming++;
  }

  @override
  Future<void> hideIncoming() async {}
  @override
  Future<void> showOngoing({required String title, bool video = false}) async {}
  @override
  Future<void> hideOngoing() async {}
}
