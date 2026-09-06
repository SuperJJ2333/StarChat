import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart';

import 'call_controller_test.dart' as support;

final class DeferredPermissions implements CallPermissionGateway {
  final result = Completer<bool>();
  int requests = 0;

  @override
  Future<bool> request({required bool video}) {
    requests++;
    return result.future;
  }
}

final class DeferredAnswerBackend extends support.FakeCallBackend {
  final answer = Completer<void>();
  Completer<void>? route;
  bool endOnHangup = false;
  Completer<void>? cleanup;
  Completer<void>? outgoing;

  @override
  Future<void> start(String room, String user, CallMediaType type) async {
    starts++;
    await outgoing?.future;
  }

  @override
  Future<void> hangup() async {
    await cleanup?.future;
    await super.hangup();
    if (endOnHangup) events.add(const CallBackendEvent.ended());
  }

  @override
  Future<void> reject() async {
    await cleanup?.future;
    await super.reject();
  }

  @override
  Future<void> accept() async {
    accepts++;
    await answer.future;
  }

  @override
  Future<void> setSpeaker(bool value) async {
    await super.setSpeaker(value);
    await route?.future;
  }
}

void main() {
  late DeferredAnswerBackend backend;
  late CallController controller;
  var disposed = false;

  Future<void> incoming(
      {CallPermissionGateway? permissions,
      CallMediaType type = CallMediaType.audio}) async {
    backend = DeferredAnswerBackend();
    disposed = false;
    controller = CallController(
      backend: backend,
      permissions: permissions ?? support.FakeCallPermissions(),
      alerts: support.RecordingCallAlerts(),
      soundCues: support.RecordingCallSoundCues(),
      connectTimeout: const Duration(seconds: 1),
    );
    backend.events.add(CallBackendEvent.incoming(
      roomId: '!dm:example.test',
      matrixUserId: '@alice:example.test',
      type: type,
    ));
    await Future<void>.delayed(Duration.zero);
  }

  tearDown(() async {
    if (!disposed) controller.dispose();
    await backend.events.close();
  });

  test('answer completion cannot overwrite an early connected event', () async {
    await incoming();
    final accept = controller.accept();
    await Future<void>.delayed(Duration.zero);
    backend.events.add(const CallBackendEvent.connected());
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.phase, CallPhase.connected);
    backend.answer.complete();
    await accept;
    expect(controller.state.phase, CallPhase.connected);
  });

  test('repeated immediate answer requests negotiate only once', () async {
    final permissions = DeferredPermissions();
    await incoming(permissions: permissions);
    final first = controller.accept();
    final second = controller.accept();
    permissions.result.complete(true);
    backend.answer.complete();
    await Future.wait([first, second]);
    expect(permissions.requests, 1);
    expect(backend.accepts, 1);
  });

  test('hangup during permission request does not start answering', () async {
    final permissions = DeferredPermissions();
    await incoming(permissions: permissions);
    final accept = controller.accept();
    await controller.hangup();
    permissions.result.complete(true);
    backend.answer.complete();
    await accept;
    expect(backend.accepts, 0);
    expect(controller.state.phase, CallPhase.ended);
  });

  test('remote end while answering cannot be resurrected', () async {
    await incoming();
    final accept = controller.accept();
    await Future<void>.delayed(Duration.zero);
    backend.events.add(const CallBackendEvent.ended());
    await Future<void>.delayed(Duration.zero);
    backend.answer.complete();
    await accept;
    expect(controller.state.phase, CallPhase.ended);
  });

  test('disposing during permission request prevents answer side effects',
      () async {
    final permissions = DeferredPermissions();
    await incoming(permissions: permissions);
    final accept = controller.accept();
    controller.dispose();
    disposed = true;
    permissions.result.complete(true);
    backend.answer.complete();
    await accept;
    expect(backend.accepts, 0);
    expect(backend.speaker, isNull);
  });

  testWidgets('connection timeout covers answer that never completes',
      (tester) async {
    // Initialize outside fake time so incoming event setup cannot deadlock.
    await tester.runAsync(() => incoming());
    final accept = controller.accept();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(controller.state.phase, CallPhase.failed);
    expect(backend.hangups, 1);
    await tester.runAsync(() async {
      backend.answer.complete();
      await accept;
    });
    expect(controller.state.phase, CallPhase.failed);
  });

  test('video speaker completion cannot resurrect a remotely ended call',
      () async {
    await incoming(type: CallMediaType.video);
    backend.answer.complete();
    await controller.accept();
    backend.route = Completer<void>();
    backend.events.add(const CallBackendEvent.connected());
    await Future<void>.delayed(Duration.zero);
    backend.events.add(const CallBackendEvent.ended());
    await Future<void>.delayed(Duration.zero);
    backend.route!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.phase, CallPhase.ended);
  });

  test('timeout cleanup ended event retains the retryable failure', () async {
    await incoming();
    backend.endOnHangup = true;
    final accept = controller.accept();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    backend.answer.complete();
    await accept;
    expect(controller.state.phase, CallPhase.failed);
    expect(controller.state.message, '接通超时，请重试');
  });

  for (final reject in [false, true]) {
    test('reject=$reject exits UI before pending signaling cleanup', () async {
      await incoming();
      backend.cleanup = Completer<void>();
      final end = reject ? controller.reject() : controller.hangup();
      try {
        expect(controller.state.phase, CallPhase.ended);
        backend.events.add(const CallBackendEvent.connected());
        await Future<void>.delayed(Duration.zero);
        expect(controller.state.phase, CallPhase.ended);
      } finally {
        backend.cleanup!.complete();
        await end;
      }
    });
  }

  test('permission denial preserves incoming session without reject cleanup',
      () async {
    final permissions = DeferredPermissions();
    await incoming(permissions: permissions);
    backend.cleanup = Completer<void>();
    final accept = controller.accept();
    permissions.result.complete(false);
    await Future<void>.delayed(Duration.zero);
    try {
      expect(controller.state.phase, CallPhase.ringing);
      expect(controller.state.message, contains('授权麦克风'));
      expect(backend.rejects, 0);
      expect(backend.accepts, 0);
    } finally {
      backend.cleanup!.complete();
      await accept;
    }
  });

  test('video connected UI does not wait for speaker route', () async {
    await incoming(type: CallMediaType.video);
    backend.answer.complete();
    await controller.accept();
    backend.route = Completer<void>();
    backend.events.add(const CallBackendEvent.connected());
    await Future<void>.delayed(Duration.zero);
    try {
      expect(controller.state.phase, CallPhase.connected);
      expect(controller.state.connectedAt, isNotNull);
    } finally {
      backend.route!.complete();
      await Future<void>.delayed(Duration.zero);
    }
  });

  Future<void> startOutgoing() => controller.start(
        roomId: '!outgoing:example.test',
        matrixUserId: '@alice:example.test',
        type: CallMediaType.audio,
      );

  test('outgoing start completion cannot overwrite early connected', () async {
    await incoming();
    backend.outgoing = Completer<void>();
    final start = startOutgoing();
    await Future<void>.delayed(Duration.zero);
    backend.events.add(const CallBackendEvent.connected());
    await Future<void>.delayed(Duration.zero);
    backend.outgoing!.complete();
    await start;
    expect(controller.state.phase, CallPhase.connected);
  });

  test('outgoing permission completion cannot start a cancelled call',
      () async {
    final permissions = DeferredPermissions();
    await incoming(permissions: permissions);
    final start = startOutgoing();
    await Future<void>.delayed(Duration.zero);
    await controller.hangup();
    permissions.result.complete(true);
    await start;
    expect(backend.starts, 0);
    expect(controller.state.phase, CallPhase.ended);
  });

  test('outgoing backend completion cannot resurrect a cancelled call',
      () async {
    await incoming();
    backend.outgoing = Completer<void>();
    final start = startOutgoing();
    await Future<void>.delayed(Duration.zero);
    await controller.hangup();
    backend.outgoing!.complete();
    await start;
    expect(controller.state.phase, CallPhase.ended);
  });
}
