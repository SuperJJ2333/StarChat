import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/notification_preferences.dart';
import 'package:liuhetong_mobile/features/push/ios_push_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const values = NotificationPreferenceValues(dndEnabled: true);

  test('native IANA and persisted revision form the strict ordinary iOS policy',
      () async {
    const channel = MethodChannel('chatflow/apns');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getTimeZoneIdentifier');
      return 'Asia/Hong_Kong';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final store = _Store();
    final result = await IosPushPolicy(store: store).prepare(values);
    expect(result, {
      'v': 1,
      'revision': 1,
      'timezone': 'Asia/Hong_Kong',
      'dnd_enabled': true,
      'dnd_start_minutes': 1380,
      'dnd_end_minutes': 480
    });
    expect(jsonDecode(store.data!), result);
  });

  test(
      'unchanged policy survives restart without revision churn; travel advances it',
      () async {
    final store = _Store();
    var zone = 'America/New_York';
    IosPushPolicy policy() =>
        IosPushPolicy(store: store, timeZoneIdentifier: () async => zone);
    final first = await policy().prepare(values);
    final again = await policy().prepare(values);
    expect(first['revision'], 1);
    expect(again['revision'], 1);
    expect(store.writes, 1);
    zone = 'Europe/London';
    final moved = await policy().prepare(values);
    expect(moved['revision'], 2);
    final disabled = await policy().prepare(values.copyWith(dndEnabled: false));
    expect(disabled['revision'], 3);
  });

  test('registration waits for durable policy and concurrent changes converge',
      () async {
    final store = _Store()..gate = Completer<void>();
    final policy =
        IosPushPolicy(store: store, timeZoneIdentifier: () async => 'UTC');
    var done = false;
    final first = policy.prepare(values).then((value) {
      done = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(done, false);
    final rest = List.generate(
        20, (_) => policy.prepare(values.copyWith(dndEndMinutes: 540)));
    store.gate!.complete();
    final outcomes = await Future.wait([first, ...rest]);
    expect(outcomes.every((value) => value['dnd_end_minutes'] == 540), true);
    expect(store.writes, 2);
    expect(jsonDecode(store.data!)['revision'], 2);
  });

  test(
      'unavailable or invalid native zone becomes explicit fail-closed metadata',
      () async {
    for (final zone in [
      null,
      '',
      '../zone',
      'CST with spaces',
      'localtime',
      'posixrules',
      'posix/UTC',
      'right/UTC'
    ]) {
      final result = await IosPushPolicy(
          store: _Store(),
          timeZoneIdentifier: () async => zone).prepare(values);
      expect(result['timezone'], '');
      expect(result['dnd_enabled'], true);
    }
  });

  test('storage failure does not return an unpersisted policy revision',
      () async {
    final store = _Store()..fail = true;
    final policy =
        IosPushPolicy(store: store, timeZoneIdentifier: () async => 'UTC');
    await expectLater(policy.prepare(values), throwsStateError);
    expect(store.data, null);
  });

  test('default persistent storage survives policy owner replacement',
      () async {
    SharedPreferences.setMockInitialValues({});
    IosPushPolicy policy() =>
        IosPushPolicy(timeZoneIdentifier: () async => 'UTC');
    expect((await policy().prepare(values))['revision'], 1);
    expect((await policy().prepare(values))['revision'], 1);
    final changed = values.copyWith(dndEndMinutes: 600);
    expect((await policy().prepare(changed))['revision'], 2);
    expect((await policy().prepare(changed))['revision'], 2);
  });

  test('corrupt or exhausted revision cannot silently reset identity',
      () async {
    for (final revision in [
      true,
      0,
      -1,
      '1',
      9007199254740991,
      9007199254740992
    ]) {
      final store = _Store()..data = jsonEncode({'revision': revision});
      final policy =
          IosPushPolicy(store: store, timeZoneIdentifier: () async => 'UTC');
      await expectLater(policy.prepare(values), throwsStateError);
      expect(store.writes, 0);
    }
  });
}

final class _Store implements IosPushPolicyStore {
  String? data;
  int writes = 0;
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<String?> read() async => data;
  @override
  Future<void> write(String value) async {
    if (fail) throw StateError('synthetic storage unavailable');
    await gate?.future;
    data = value;
    writes++;
  }
}
