import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/push/native_message_policy.dart';
import 'package:liuhetong_mobile/core/notification/notification_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final scope = 'a' * 64;
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(NativeMessagePolicy.channel,
        (call) async {
      calls.add(call);
      if (call.method == 'bind') return {'scope': scope, 'revision': 4};
      return true;
    });
  });
  tearDown(() =>
      messenger.setMockMethodCallHandler(NativeMessagePolicy.channel, null));
  test(
      'preparation waits for durable policy ACK and emits only scoped pusher metadata',
      () async {
    final policy = NativeMessagePolicy(enabled: true);
    await policy.observeRoom('account', '!room', false);
    await policy.prepare('account', const NotificationPreferenceValues());
    expect(policy.registration, {
      'chatflow_push_v': 1,
      'chatflow_push_scope': scope,
      'chatflow_push_revision': 5
    });
    final snapshot =
        calls.firstWhere((call) => call.method == 'install').arguments as Map;
    expect((snapshot['rooms'] as Map).keys.single, isNot('!room'));
    await policy.revoke();
    expect(policy.registration, isNull);
  });
  test(
      'failed ACK never exposes registration and restrictive update invalidates first',
      () async {
    final policy = NativeMessagePolicy(enabled: true);
    messenger.setMockMethodCallHandler(NativeMessagePolicy.channel,
        (call) async {
      calls.add(call);
      if (call.method == 'bind') return {'scope': scope, 'revision': 0};
      if (call.method == 'install') return false;
      return true;
    });
    await expectLater(
        policy.prepare('account', const NotificationPreferenceValues()),
        throwsStateError);
    expect(policy.registration, isNull);
    expect(calls.map((c) => c.method),
        containsAllInOrder(['bind', 'invalidate', 'install']));
  });
  test(
      'unchanged room state performs no native write; local mute updates one row',
      () async {
    final policy = NativeMessagePolicy(enabled: true);
    await policy.observeRoom('account', '!room', false);
    await policy.prepare('account', const NotificationPreferenceValues());
    calls.clear();
    await policy.observeRoom('account', '!room', false);
    expect(calls, isEmpty);
    await policy.observeRoom('account', '!room', true);
    expect(calls.single.method, 'room');
    expect((calls.single.arguments as Map)['muted'], true);
  });
  test('late bind cannot reenable a revoked account', () async {
    final bind = Completer<Object?>();
    final entered = Completer<void>();
    messenger.setMockMethodCallHandler(NativeMessagePolicy.channel,
        (call) async {
      calls.add(call);
      if (call.method == 'bind') {
        entered.complete();
        return bind.future;
      }
      return true;
    });
    final policy = NativeMessagePolicy(enabled: true);
    final start =
        policy.prepare('old-account', const NotificationPreferenceValues());
    await entered.future;
    await policy.revoke();
    bind.complete({'scope': scope, 'revision': 0});
    await start;
    expect(policy.registration, isNull);
    expect(calls.where((call) => call.method == 'install'), isEmpty);
  });
  test('failed room persistence hides registration and retries desired mute',
      () async {
    final policy = NativeMessagePolicy(enabled: true);
    await policy.observeRoom('account', '!room', false);
    await policy.prepare('account', const NotificationPreferenceValues());
    messenger.setMockMethodCallHandler(NativeMessagePolicy.channel,
        (call) async {
      calls.add(call);
      if (call.method == 'room') {
        throw PlatformException(code: 'NATIVE_MESSAGE_STATE');
      }
      return true;
    });
    await expectLater(policy.observeRoom('account', '!room', true),
        throwsA(isA<PlatformException>()));
    expect(policy.registration, isNull);
    await policy.retryPending();
    final snapshot =
        calls.lastWhere((c) => c.method == 'install').arguments as Map;
    expect((snapshot['rooms'] as Map).values.single, true);
    expect(policy.registration, isNotNull);
  });
  test('newer restrictive settings defeat a delayed audible install ACK',
      () async {
    final firstInstall = Completer<Object?>();
    final entered = Completer<void>();
    var installs = 0;
    messenger.setMockMethodCallHandler(NativeMessagePolicy.channel,
        (call) async {
      calls.add(call);
      if (call.method == 'bind') return {'scope': scope, 'revision': 0};
      if (call.method == 'install' && ++installs == 1) {
        entered.complete();
        return firstInstall.future;
      }
      return true;
    });
    final policy = NativeMessagePolicy(enabled: true);
    final start =
        policy.prepare('account', const NotificationPreferenceValues());
    await entered.future;
    final restrictive = policy.updatePreferences(
        const NotificationPreferenceValues(messageNotificationEnabled: false));
    firstInstall.complete(true);
    await Future.wait([start, restrictive]);
    expect(policy.registration?['chatflow_push_revision'], 2);
    final lastInstall =
        calls.lastWhere((call) => call.method == 'install').arguments as Map;
    expect(lastInstall['enabled'], false);
  });
}
