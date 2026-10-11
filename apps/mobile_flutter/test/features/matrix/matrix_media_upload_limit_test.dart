import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_media_upload_limit.dart';

class _LimitClient extends Client {
  _LimitClient() : super('synthetic-limit-client');
  var calls = 0;
  Completer<MediaConfig>? held;
  @override
  String? get userID => '@synthetic:test';
  late final room = Room(id: '!synthetic:test', client: this);
  @override
  Room? getRoomById(String id) => room.id == id ? room : null;
  @override
  Future<MediaConfig> getConfig() {
    calls++;
    return held?.future ??
        Future.value(MediaConfig(mUploadSize: 50 * 1024 * 1024));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _LimitClient client;
  late MatrixSdkE2eeClient owner;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    client = _LimitClient();
    owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://synthetic.invalid'),
        suspendClient: (_) async {});
  });
  tearDown(() async {
    if (client.held != null && !client.held!.isCompleted) {
      client.held!.complete(MediaConfig(mUploadSize: 1));
    }
    await owner.suspend();
    await client.dispose();
  });

  test('SDK media gateway exposes the cached Matrix server upload limit',
      () async {
    expect(owner, isA<MatrixMediaUploadLimitGateway>());
    expect(await (owner as MatrixMediaUploadLimitGateway).maximumUploadBytes(),
        50 * 1024 * 1024);
    expect(client.calls, 1);
  });

  test('real room lease exposes the same early media limit capability',
      () async {
    final lease = await owner.openRoomLease(client.room.id);
    expect(lease, isA<MatrixMediaUploadLimitGateway>());
    expect(await (lease as MatrixMediaUploadLimitGateway).maximumUploadBytes(),
        50 * 1024 * 1024);
    await lease.cancel();
    await expectLater(
        (lease as MatrixMediaUploadLimitGateway).maximumUploadBytes(),
        throwsStateError);
    expect(client.calls, 1);
  });

  test('lease revocation fences a late successful limit response', () async {
    final lease = await owner.openRoomLease(client.room.id);
    expect(lease, isA<MatrixMediaUploadLimitGateway>());
    client.held = Completer<MediaConfig>();
    final result =
        (lease as MatrixMediaUploadLimitGateway).maximumUploadBytes();
    final rejected = expectLater(result, throwsStateError);
    await pumpEventQueue();
    expect(client.calls, 1);
    lease.revokeNow();
    client.held!.complete(MediaConfig(mUploadSize: 50 * 1024 * 1024));
    await rejected;
    await lease.cancel();
  });

  test('session revocation fences a late SDK response before reading source',
      () async {
    expect(owner, isA<MatrixMediaUploadLimitGateway>());
    client.held = Completer<MediaConfig>();
    final result =
        (owner as MatrixMediaUploadLimitGateway).maximumUploadBytes();
    final rejected = expectLater(result, throwsStateError);
    await pumpEventQueue();
    final suspension = owner.suspend();
    client.held!.complete(MediaConfig(mUploadSize: 50 * 1024 * 1024));
    await rejected;
    await suspension;
  });
}
