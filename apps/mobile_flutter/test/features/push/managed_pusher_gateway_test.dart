import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/push/matrix_pusher_service.dart';
import 'package:matrix/matrix.dart';

final class _Client extends Client {
  _Client() : super('synthetic-pusher');
  List<Pusher>? rows = [];
  int reads = 0;
  Completer<List<Pusher>?>? pending;
  @override
  String? get userID => '@synthetic:test';
  @override
  Future<List<Pusher>?> getPushers() async {
    reads++;
    if (pending != null) return pending!.future;
    return rows;
  }
}

void main() {
  test('managed pusher list cannot publish after capability revocation',
      () async {
    final client = _Client()..pending = Completer<List<Pusher>?>();
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'), suspendClient: (_) async {});
    late Future<List<Pusher>> reading;
    final resource = await matrix.registerAppHomeResource(
        open: (capability) async {
          reading = capability.createPusherGateway().list();
        },
        close: () async {});
    final rejected = expectLater(reading, throwsStateError);
    await resource.cancel();
    client.pending!.complete([]);
    await rejected;
    expect(client.reads, 1);
    await matrix.suspend();
  });

  test('managed pusher gateway returns SDK list and treats null as unknown',
      () async {
    final client = _Client();
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'), suspendClient: (_) async {});
    late MatrixPusherGateway gateway;
    await matrix.registerAppHomeResource(
        open: (capability) async {
          gateway = capability.createPusherGateway();
          expect(await gateway.list(), isEmpty,
              reason: 'opening lifecycle owns admission');
        },
        close: () async {});
    client.rows = [
      Pusher(
          appId: 'synthetic',
          pushkey: 'opaque',
          kind: 'http',
          appDisplayName: 'test',
          deviceDisplayName: 'test',
          lang: 'en',
          data: PusherData(url: Uri.parse('https://push.test/notify')))
    ];
    expect(await gateway.list(), same(client.rows));
    client.rows = null;
    await expectLater(gateway.list(), throwsStateError);
    expect(client.reads, 3);
    await matrix.suspend();
    await expectLater(Future.sync(gateway.list), throwsStateError);
    expect(client.reads, 3,
        reason: 'revoked capability must not read old account');
  });
}
