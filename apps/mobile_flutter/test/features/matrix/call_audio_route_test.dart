import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart';

import 'call_controller_test.dart' as support;

final class RouteBackend extends support.FakeCallBackend {
  final routesAtMediaStart = <bool?>[];

  @override
  Future<void> start(String room, String user, CallMediaType type) async {
    routesAtMediaStart.add(speaker);
    await super.start(room, user, type);
  }

  @override
  Future<void> accept() async {
    routesAtMediaStart.add(speaker);
    await super.accept();
  }
}

void main() {
  test('incoming answer preserves an explicit speaker choice', () async {
    final backend = RouteBackend();
    final controller = CallController(
      backend: backend,
      permissions: support.FakeCallPermissions(),
      alerts: support.RecordingCallAlerts(),
    );
    addTearDown(controller.dispose);
    addTearDown(backend.events.close);
    backend.events.add(const CallBackendEvent.incoming(
      roomId: '!dm:example.test',
      matrixUserId: '@alice:example.test',
      type: CallMediaType.audio,
    ));
    await Future<void>.delayed(Duration.zero);
    await controller.toggleSpeaker();
    await controller.accept();
    expect(backend.routesAtMediaStart, [true]);
  });

  test('denied microphone permission does not touch the audio route', () async {
    final backend = RouteBackend();
    final controller = CallController(
      backend: backend,
      permissions: support.FakeCallPermissions()..allowed = false,
      alerts: support.RecordingCallAlerts(),
    );
    addTearDown(controller.dispose);
    addTearDown(backend.events.close);
    await controller.start(
      roomId: '!dm:example.test',
      matrixUserId: '@alice:example.test',
      type: CallMediaType.audio,
    );
    expect(backend.speaker, isNull);
    expect(backend.routesAtMediaStart, isEmpty);
  });

  for (final type in CallMediaType.values) {
    for (final incoming in [false, true]) {
      test('$type incoming=$incoming applies route before media starts',
          () async {
        final backend = RouteBackend()..speaker = true;
        final controller = CallController(
          backend: backend,
          permissions: support.FakeCallPermissions(),
          alerts: support.RecordingCallAlerts(),
        );
        addTearDown(controller.dispose);
        addTearDown(backend.events.close);
        if (incoming) {
          backend.events.add(CallBackendEvent.incoming(
            roomId: '!dm:example.test',
            matrixUserId: '@alice:example.test',
            type: type,
          ));
          await Future<void>.delayed(Duration.zero);
          await controller.accept();
        } else {
          await controller.start(
            roomId: '!dm:example.test',
            matrixUserId: '@alice:example.test',
            type: type,
          );
        }
        expect(backend.routesAtMediaStart, [false],
            reason: 'SDK speaker-first default or previous call must not leak');
        expect(controller.state.speaker, isFalse);
        expect(backend.muted, isNull, reason: 'routing must not mute capture');
        backend.events.add(const CallBackendEvent.connected());
        await Future<void>.delayed(Duration.zero);
        expect(backend.speaker, type == CallMediaType.video);
        expect(controller.state.speaker, backend.speaker);
      });
    }
  }
}
