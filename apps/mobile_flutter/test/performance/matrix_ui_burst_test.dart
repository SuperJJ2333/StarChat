import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';

void main() {
  test('one burst preserves all decrypt events but projects UI once', () async {
    final client = Client('ui-burst-fixture');
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://fixture.invalid'),
        suspendClient: (_) async {});
    var snapshots = 0;
    var decrypted = 0;
    final snapshotSubscription = matrix.syncEvents.listen((_) => snapshots++);
    final decryptionSubscription =
        matrix.decryptionUpdates.listen((_) => decrypted++);
    for (var i = 0; i < 20; i++) {
      client.onEvent.add(EventUpdate(
          roomID: '!fixture:invalid',
          type: EventUpdateType.decryptedTimelineQueue,
          content: {
            'event_id': 'fixture-$i',
            'type': EventTypes.Message,
            'content': {'msgtype': MessageTypes.Text, 'body': 'synthetic'},
          }));
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(decrypted, 20);
    expect(snapshots, 1);
    await snapshotSubscription.cancel();
    await decryptionSubscription.cancel();
    await matrix.suspend();
  });
}
