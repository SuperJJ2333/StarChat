import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/app_connection_status.dart';

void main() {
  test('owner binding maps source and stale owner cannot unbind it', () {
    final hub = AppConnectionStatusHub.shared;
    final first = Object(), second = Object();
    final source = ValueNotifier(0);
    hub.bind(
        first,
        source,
        (value) => value == 0
            ? AppConnectionStatus.offline
            : AppConnectionStatus.connected);
    hub.bind(
        second,
        source,
        (value) => value == 0
            ? AppConnectionStatus.connecting
            : AppConnectionStatus.connected);
    hub.unbind(first);
    expect(hub.status.value, AppConnectionStatus.connecting);
    source.value = 1;
    expect(hub.status.value, AppConnectionStatus.connected);
    hub.unbind(second);
  });
  test('retry is singleflight for its current owner', () async {
    final hub = AppConnectionStatusHub.shared;
    final gate = Completer<void>();
    var calls = 0;
    final owner = Object();
    hub.bind(owner, ValueNotifier(0), (_) => AppConnectionStatus.offline,
        onRetry: () async {
      calls++;
      await gate.future;
    });
    final a = hub.retry(), b = hub.retry();
    expect(calls, 1);
    gate.complete();
    await Future.wait([a, b]);
    hub.unbind(owner);
  });
  test('a prior owner retry cannot block or clear the next owner flight',
      () async {
    final hub = AppConnectionStatusHub.shared;
    final firstGate = Completer<void>(), secondGate = Completer<void>();
    final first = Object(), second = Object();
    var secondCalls = 0;
    hub.bind(first, ValueNotifier(0), (_) => AppConnectionStatus.offline,
        onRetry: () => firstGate.future);
    final old = hub.retry();
    hub.bind(second, ValueNotifier(0), (_) => AppConnectionStatus.offline,
        onRetry: () {
      secondCalls++;
      return secondGate.future;
    });
    final current = hub.retry();
    expect(secondCalls, 1);
    hub.unbind(first);
    expect(hub.status.value, AppConnectionStatus.offline);
    firstGate.complete();
    await old;
    expect(identical(hub.retry(), current), isTrue);
    secondGate.complete();
    await current;
    hub.unbind(second);
  });
}
