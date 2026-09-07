import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/ios_call_coordinator.dart';

void main() {
  test('cold answer readiness does not wait for HTTP registration', () async {
    final registration = Completer<void>();
    var ready = false;
    final coordinator = IosCallCoordinator(
      owner: 'current-owner',
      snapshot: () => const IosCallSnapshot(),
      invoke: (method, _) async {
        if (method == 'start') return {'voipToken': 'a' * 64};
        if (method == 'ready') ready = true;
        return null;
      },
      accept: () async {},
      end: () async {},
      mute: (_) async {},
      sync: () async {},
      registerTokens: (_) => registration.future,
    );
    final started = coordinator.start();
    await Future<void>.delayed(Duration.zero);
    expect(ready, true);
    registration.complete();
    await started;
    await coordinator.dispose();
  });
  late DateTime now;
  late IosCallSnapshot state;
  late IosCallCoordinator bridge;
  late List<String> native;
  late int answers;
  late int ends;
  late int syncs;
  late List<bool> mutes;
  setUp(() {
    now = DateTime(2026, 9, 8);
    state = const IosCallSnapshot();
    native = [];
    answers = ends = syncs = 0;
    mutes = [];
    bridge = IosCallCoordinator(
      owner: 'current-owner',
      snapshot: () => state,
      invoke: (method, args) async {
        native.add(method);
        return null;
      },
      accept: () async {
        answers++;
      },
      end: () async {
        ends++;
      },
      mute: (value) async {
        mutes.add(value);
      },
      sync: () async {
        syncs++;
      },
      registerTokens: (_) async {},
      now: () => now,
    );
  });
  Map<String, Object> action(String action, {String id = 'a'}) => {
        'owner': 'current-owner',
        'action': action,
        'callId': id,
        'roomId': '!room:host',
        'at': now.millisecondsSinceEpoch,
      };
  IosCallSnapshot incoming(String id) => IosCallSnapshot(
        callId: id,
        roomId: '!room:host',
        phase: 'ringing',
        incoming: true,
      );
  test(
      'push presentation does not answer; explicit answer waits for same Matrix call',
      () async {
    await bridge.handle('event', action('incoming'));
    await bridge.handle('event', action('answer'));
    expect(answers, 0);
    expect(syncs, greaterThan(0));
    state = incoming('other');
    await bridge.update();
    expect(answers, 0);
    state = incoming('a');
    await bridge.update();
    expect(answers, 1);
    await bridge.update();
    await bridge.handle('event', action('answer'));
    expect(answers, 1);
  });
  test('end cancels pending answer and rejects only its matching late invite',
      () async {
    await bridge.handle('event', action('answer'));
    await bridge.handle('event', action('end'));
    state = incoming('other');
    await bridge.update();
    expect(ends, 0);
    state = incoming('a');
    await bridge.update();
    expect(ends, 1);
    expect(answers, 0);
  });
  test('old actions never answer a later Matrix call', () async {
    await bridge.handle('event', action('answer'));
    now = now.add(const Duration(seconds: 46));
    state = incoming('a');
    await bridge.update();
    expect(answers, 0);
  });
  test('old owner cannot answer the same restored Matrix call', () async {
    state = incoming('a');
    await bridge.handle('event', {...action('answer'), 'owner': 'old-owner'});
    expect(answers, 0);
  });
  test(
      'mute while awaiting encrypted invite does not overwrite explicit answer',
      () async {
    await bridge.handle('event', action('answer'));
    await bridge.handle('event', {...action('mute'), 'muted': true});
    state = incoming('a');
    await bridge.update();
    expect(answers, 1);
    expect(mutes, [true]);
  });
  test('room mismatch cannot answer a call with same call id', () async {
    state = incoming('a');
    final wrong = action('answer')..['roomId'] = '!other:host';
    await bridge.handle('event', wrong);
    expect(answers, 0);
  });
  test('dispose makes late native actions and tokens inert', () async {
    await bridge.dispose();
    state = incoming('a');
    await bridge.handle('event', action('answer'));
    await bridge.update();
    expect(answers, 0);
    expect(native, contains('stop'));
  });
  test(
      'foreground Matrix invite is presented once and ending clears system call',
      () async {
    state = incoming('a');
    await bridge.update();
    await bridge.update();
    expect(native.where((n) => n == 'showIncoming').length, 1);
    state = const IosCallSnapshot(phase: 'ended');
    await bridge.update();
    expect(native, contains('endCall'));
  });
}
