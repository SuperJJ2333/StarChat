import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liuhetong_mobile/features/push/matrix_pusher_service.dart';
import 'package:liuhetong_mobile/features/push/push_status_registry.dart';
import 'package:liuhetong_mobile/features/push/push_token_provider.dart';

class _Token implements PushTokenProvider {
  @override
  Future<String?> token() async => 'synthetic-review';
  @override
  Stream<String?> tokenUpdates() => const Stream.empty();
  @override
  Future<void> dispose() async {}
}

class _Gateway implements MatrixPusherGateway {
  final rows = <Pusher>[];
  int writes = 0;
  int reads = 0;
  Object? error;
  @override
  Future<List<Pusher>> list() async {
    reads++;
    if (error != null) throw error!;
    return rows;
  }

  @override
  Future<void> create(Pusher row) async {
    writes++;
    rows
      ..clear()
      ..add(row);
  }

  @override
  Future<void> delete(PusherId id) async => rows.clear();
}

void main() {
  test('preference synchronization honors a live server retry-after deadline',
      () {
    fakeAsync((time) {
      final remote = _Gateway();
      var audible = true;
      final service = MatrixPusherService(
          gateway: remote,
          tokenProvider: _Token(),
          appId: MatrixPusherService.appIdIOS,
          gatewayUrl: Uri.parse('https://push.test/_matrix/push/v1/notify'),
          now: () => DateTime(2026).add(time.elapsed),
          iosSoundEnabled: () => audible);
      final registry = PushStatusRegistry()..register(service);
      service.ensureRegistered();
      time.flushMicrotasks();
      expect(remote.writes, 1);
      remote.error = MatrixException.fromJson({
        'errcode': 'M_LIMIT_EXCEEDED',
        'error': 'synthetic',
        'retry_after_ms': 30000,
      });
      service.recheck();
      time.flushMicrotasks();
      final readsBefore = remote.reads;
      audible = false;
      registry.synchronizePreferences();
      time.flushMicrotasks();
      for (var i = 0; i < 20; i++) {
        audible = i.isEven;
        registry.synchronizePreferences();
        service.ensureRegistered();
      }
      time.flushMicrotasks();
      final writesWithinThrottle = remote.writes;
      final readsWithinThrottle = remote.reads;
      expect(writesWithinThrottle, 1,
          reason:
              'preference change must queue desired policy during server 429');
      expect(readsWithinThrottle, readsBefore);
      remote.error = null;
      time.elapse(const Duration(seconds: 29));
      expect(remote.writes, writesWithinThrottle);
      time.elapse(const Duration(seconds: 1));
      expect(remote.writes, 2);
      expect(
          (remote.rows.single.data.additionalProperties['default_payload']
              as Map)['aps'],
          isNot(contains('sound')),
          reason: 'latest desired preference converges at deadline');
      expect(service.isRemoteVerified, true);
      service.dispose();
      time.flushMicrotasks();
      expect(writesWithinThrottle, 1,
          reason:
              'preference change must queue desired policy during server 429');
      expect(readsWithinThrottle, readsBefore);
    });
  });
}
