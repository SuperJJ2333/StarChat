import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/push/matrix_pusher_service.dart';
import 'package:liuhetong_mobile/features/push/push_token_provider.dart';
import 'package:liuhetong_mobile/features/push/ios_push_policy.dart';
import 'package:liuhetong_mobile/core/notification/notification_preferences.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('resume repairs a remotely deleted pusher with the same token',
      () async {
    final remote = _RemoteGateway();
    final service = MatrixPusherService(
      gateway: remote,
      tokenProvider: _Token(),
      appId: MatrixPusherService.appIdIOS,
      gatewayUrl: Uri.parse('https://push.test/_matrix/push/v1/notify'),
    );
    addTearDown(service.dispose);
    expect(await service.ensureRegistered(), true);
    remote.pushers.clear();
    await service.recheck();
    expect(remote.pushers, hasLength(1),
        reason: 'local write history is not remote pusher health');
    expect(remote.writes, 2);
  });

  test('20 concurrent resumes share one read and one repair', () async {
    final remote = _RemoteGateway();
    final service = _service(remote);
    addTearDown(service.dispose);
    await service.ensureRegistered();
    remote.pushers.clear();
    remote.readGate = Completer<void>();
    final resumes = List.generate(20, (_) => service.recheck());
    await remote.readEntered.future;
    final before = remote.reads;
    remote.readGate!.complete();
    await Future.wait(resumes);
    expect(remote.writes, 2);
    expect(remote.reads, before + 1, reason: 'only repaired binding readback');
    expect(service.isRemoteVerified, true);
  });

  test('read failure is unknown and resume storms preserve retry backoff', () {
    fakeAsync((time) {
      final remote = _RemoteGateway();
      final service =
          _service(remote, now: () => DateTime(2026).add(time.elapsed));
      service.ensureRegistered();
      time.flushMicrotasks();
      final writeAt = service.lastSuccessAt;
      remote.readError = const FormatException('synthetic offline');
      service.recheck();
      time.flushMicrotasks();
      final failedReads = remote.reads;
      expect(service.isRemoteVerified, false);
      expect(service.lastSuccessAt, writeAt);
      for (var i = 0; i < 20; i++) {
        service.recheck();
      }
      time.flushMicrotasks();
      expect(remote.reads, failedReads);
      time.elapse(const Duration(seconds: 9));
      expect(remote.reads, failedReads);
      remote.readError = null;
      time.elapse(const Duration(seconds: 1));
      expect(remote.reads, failedReads + 1);
      expect(remote.writes, 1);
      expect(service.isRemoteVerified, true);
      service.dispose();
      time.flushMicrotasks();
    });
  });

  test('active periodic verification repairs deletion within five minutes', () {
    fakeAsync((time) {
      final remote = _RemoteGateway();
      final service =
          _service(remote, now: () => DateTime(2026).add(time.elapsed));
      service.ensureRegistered();
      service.watchTokenRefresh();
      time.flushMicrotasks();
      remote.pushers.clear();
      time.elapse(const Duration(minutes: 4, seconds: 59));
      expect(remote.writes, 1);
      time.elapse(const Duration(seconds: 1));
      expect(remote.writes, 2);
      expect(service.isRemoteVerified, true);
      service.dispose();
      time.flushMicrotasks();
    });
  });

  test('429 remains unknown and honors the server retry-after window', () {
    fakeAsync((time) {
      final remote = _RemoteGateway();
      final service =
          _service(remote, now: () => DateTime(2026).add(time.elapsed));
      service.ensureRegistered();
      time.flushMicrotasks();
      remote.readError = MatrixException.fromJson({
        'errcode': 'M_LIMIT_EXCEEDED',
        'error': 'synthetic',
        'retry_after_ms': 30000,
      });
      service.recheck();
      time.flushMicrotasks();
      final reads = remote.reads;
      expect(service.isRemoteVerified, false);
      remote.readError = null;
      time.elapse(const Duration(seconds: 29));
      expect(remote.reads, reads, reason: 'do not bypass server throttling');
      time.elapse(const Duration(seconds: 1));
      expect(service.isRemoteVerified, true);
      service.dispose();
      time.flushMicrotasks();
    });
  });

  test('recovery after repeated failures never waits more than five minutes',
      () {
    fakeAsync((time) {
      final remote = _RemoteGateway();
      final service =
          _service(remote, now: () => DateTime(2026).add(time.elapsed));
      service.ensureRegistered();
      service.watchTokenRefresh();
      time.flushMicrotasks();
      remote.readError = const FormatException('synthetic offline');
      service.recheck();
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 10));
      time.elapse(const Duration(seconds: 30));
      time.elapse(const Duration(minutes: 2));
      remote.readError = null;
      remote.pushers.clear();
      time.elapse(const Duration(minutes: 5));
      expect(remote.writes, 2);
      expect(service.isRemoteVerified, true);
      service.dispose();
      time.flushMicrotasks();
    });
  });

  test('stalled remote read becomes unknown without holding the owner forever',
      () {
    fakeAsync((time) {
      final remote = _RemoteGateway();
      final service =
          _service(remote, now: () => DateTime(2026).add(time.elapsed));
      service.ensureRegistered();
      time.flushMicrotasks();
      remote.readGate = Completer<void>();
      var settled = false;
      service.recheck().then((_) => settled = true);
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 10));
      expect(settled, true);
      expect(service.isRemoteVerified, false);
      remote.readGate!.complete();
      service.dispose();
      time.flushMicrotasks();
    });
  });

  test('late old read cannot restore or report a newer owner binding',
      () async {
    final remote = _RemoteGateway();
    final old = _service(remote);
    final replacement = _service(remote);
    addTearDown(old.dispose);
    addTearDown(replacement.dispose);
    await old.ensureRegistered();
    remote.pushers.clear();
    remote.readGate = Completer<void>();
    final checking = old.recheck();
    await remote.readEntered.future;
    final newer = replacement.ensureRegistered();
    await Future<void>.delayed(Duration.zero);
    remote.readGate!.complete();
    await Future.wait([checking, newer]);
    expect(remote.writes, 2);
    expect(old.isRemoteVerified, false);
    expect(replacement.isRemoteVerified, true);
  });

  test('iOS sound changes reconcile same token and preserve generic alert',
      () async {
    final remote = _RemoteGateway();
    var audible = true;
    final service = MatrixPusherService(
      gateway: remote,
      tokenProvider: _Token(remote.token),
      appId: MatrixPusherService.appIdIOS,
      gatewayUrl: Uri.parse('https://push.test/_matrix/push/v1/notify'),
      iosSoundEnabled: () => audible,
    );
    addTearDown(service.dispose);
    await service.ensureRegistered();
    audible = false;
    await service.ensureRegistered();
    var payload = remote.pushers.single.data.toJson()['default_payload'] as Map;
    expect((payload['aps'] as Map).containsKey('sound'), false);
    expect((payload['aps'] as Map)['alert'],
        {'title': '畅聊 ChatFlow', 'body': '您有一条新消息'});
    final silentData = remote.pushers.single.data.toJson();
    audible = true;
    await service.ensureRegistered();
    payload = remote.pushers.single.data.toJson()['default_payload'] as Map;
    expect((payload['aps'] as Map)['sound'], 'default');
    expect(remote.writes, 3);
    final fixturePath = Platform.environment['R5_PUSH_FIXTURE_PATH'];
    if (fixturePath != null) {
      File(fixturePath).writeAsStringSync(jsonEncode({
        'silent': silentData,
        'audible': remote.pushers.single.data.toJson(),
      }));
    }
  });

  test('scheduled policy revisions change same-token remote registration',
      () async {
    final remote = _RemoteGateway();
    SharedPreferences.setMockInitialValues({});
    var zone = 'Asia/Hong_Kong';
    var audible = true;
    final policy = IosPushPolicy(timeZoneIdentifier: () async => zone);
    var preferences = const NotificationPreferenceValues(dndEnabled: true);
    final service = MatrixPusherService(
        gateway: remote,
        tokenProvider: _Token(remote.token),
        appId: MatrixPusherService.appIdIOS,
        gatewayUrl: Uri.parse('https://push.test/_matrix/push/v1/notify'),
        iosPolicy: () => policy.prepare(preferences),
        iosSoundEnabled: () => audible);
    addTearDown(service.dispose);
    await service.ensureRegistered();
    final original = remote.pushers.single.data.toJson();
    expect((original['chatflow_ios_policy'] as Map)['revision'], 1);
    preferences = preferences.copyWith(dndEndMinutes: 540);
    await service.ensureRegistered();
    final revised =
        remote.pushers.single.data.toJson()['chatflow_ios_policy'] as Map;
    expect(revised['revision'], 2);
    expect(revised['dnd_end_minutes'], 540);
    expect(remote.writes, 2);
    audible = false;
    await service.ensureRegistered();
    final silent = remote.pushers.single.data.toJson();
    audible = true;
    zone = '';
    expect(await service.ensureRegistered(), false);
    final unavailable = remote.pushers.single.data.toJson();
    final fixturePath = Platform.environment['R5_DND_FIXTURE_PATH'];
    if (fixturePath != null) {
      File(fixturePath).writeAsStringSync(jsonEncode({
        'scheduled': original,
        'silent': silent,
        'unavailable': unavailable,
      }));
    }
  });

  test(
      'unknown timezone registers fail-closed sound and stays pending until recovered',
      () async {
    final remote = _RemoteGateway();
    var zone = '';
    final service = MatrixPusherService(
        gateway: remote,
        tokenProvider: _Token(remote.token),
        appId: MatrixPusherService.appIdIOS,
        gatewayUrl: Uri.parse('https://push.test/_matrix/push/v1/notify'),
        iosPolicy: () async => {
              'v': 1,
              'revision': zone.isEmpty ? 1 : 2,
              'timezone': zone,
              'dnd_enabled': true,
              'dnd_start_minutes': 1380,
              'dnd_end_minutes': 480
            });
    addTearDown(service.dispose);
    expect(await service.ensureRegistered(), false);
    final payload =
        remote.pushers.single.data.toJson()['default_payload'] as Map;
    expect((payload['aps'] as Map).containsKey('sound'), false);
    expect(service.isRemoteVerified, false);
    expect(service.lastFailureKind, 'timezone-unavailable');
    zone = 'UTC';
    expect(await service.ensureRegistered(), true);
    expect(service.isRemoteVerified, true);
  });

  test('late policy preparation cannot register after owner disposal',
      () async {
    final remote = _RemoteGateway();
    final pending = Completer<Map<String, Object>>();
    final service = MatrixPusherService(
        gateway: remote,
        tokenProvider: _Token(remote.token),
        appId: MatrixPusherService.appIdIOS,
        gatewayUrl: Uri.parse('https://push.test/_matrix/push/v1/notify'),
        iosPolicy: () => pending.future);
    final registering = service.ensureRegistered();
    await Future<void>.delayed(Duration.zero);
    final disposing = service.dispose();
    pending.complete({'timezone': 'UTC'});
    await disposing;
    expect(await registering, false);
    expect(remote.writes, 0);
    expect(service.isRemoteVerified, false);
  });

  test(
      'policy preparation failure is unknown and retries before any binding exists',
      () {
    fakeAsync((time) {
      final remote = _RemoteGateway();
      var failing = true;
      final service = MatrixPusherService(
          gateway: remote,
          tokenProvider: _Token(remote.token),
          appId: MatrixPusherService.appIdIOS,
          now: () => DateTime(2026).add(time.elapsed),
          gatewayUrl: Uri.parse('https://push.test/_matrix/push/v1/notify'),
          iosPolicy: () async {
            if (failing) throw StateError('synthetic persistence unavailable');
            return {'timezone': 'UTC'};
          });
      service.ensureRegistered();
      time.flushMicrotasks();
      expect(remote.writes, 0);
      expect(service.lastFailureKind, 'StateError');
      expect(service.isRemoteVerified, false);
      failing = false;
      time.elapse(const Duration(seconds: 10));
      expect(remote.writes, 1);
      expect(service.isRemoteVerified, true);
      service.dispose();
      time.flushMicrotasks();
    });
  });
  test(
      'stalled policy preparation releases registration ownership within ten seconds',
      () {
    fakeAsync((time) {
      final remote = _RemoteGateway();
      final pending = Completer<Map<String, Object>>();
      final service = MatrixPusherService(
          gateway: remote,
          tokenProvider: _Token(remote.token),
          appId: MatrixPusherService.appIdIOS,
          now: () => DateTime(2026).add(time.elapsed),
          gatewayUrl: Uri.parse('https://push.test/_matrix/push/v1/notify'),
          iosPolicy: () => pending.future);
      var settled = false;
      service.ensureRegistered().then((_) => settled = true);
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 10));
      expect(settled, true);
      expect(service.isRemoteVerified, false);
      expect(remote.writes, 0);
      service.dispose();
      pending.complete({'timezone': 'UTC'});
      time.flushMicrotasks();
      expect(remote.writes, 0);
    });
  });
}

MatrixPusherService _service(_RemoteGateway remote,
        {DateTime Function()? now}) =>
    MatrixPusherService(
        gateway: remote,
        tokenProvider: _Token(remote.token),
        appId: MatrixPusherService.appIdIOS,
        now: now,
        gatewayUrl: Uri.parse('https://push.test/_matrix/push/v1/notify'));

final class _Token implements PushTokenProvider {
  _Token([this.value = 'synthetic-stable-token']);
  final String value;
  @override
  Future<String?> token() async => value;
  @override
  Stream<String?> tokenUpdates() => const Stream.empty();
  @override
  Future<void> dispose() async {}
}

final class _RemoteGateway implements MatrixPusherGateway {
  static int next = 0;
  final token = 'synthetic-${next++}';
  final pushers = <Pusher>[];
  int writes = 0;
  int reads = 0;
  Object? readError;
  Completer<void>? readGate;
  final readEntered = Completer<void>();
  @override
  Future<List<Pusher>> list() async {
    reads++;
    if (readGate != null) {
      if (!readEntered.isCompleted) readEntered.complete();
      await readGate!.future;
    }
    if (readError != null) throw readError!;
    return List.of(pushers);
  }

  @override
  Future<void> create(Pusher pusher) async {
    writes++;
    pushers.removeWhere((entry) =>
        entry.appId == pusher.appId && entry.pushkey == pusher.pushkey);
    pushers.add(pusher);
  }

  @override
  Future<void> delete(PusherId id) async {
    pushers.removeWhere(
        (entry) => entry.appId == id.appId && entry.pushkey == id.pushkey);
  }
}
