import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/decryption_state_controller.dart';

void main() {
  test('late room key transitions a missing-key event to decrypted', () {
    final controller = DecryptionStateController();
    controller.markMissingKey('event-1');
    expect(controller.stateFor('event-1').state,
        MessageDecryptionState.missingKey);

    controller.retry('event-1');
    expect(controller.stateFor('event-1').state,
        MessageDecryptionState.decrypting);

    controller.lateKeyReceived('event-1');
    expect(controller.stateFor('event-1').state,
        MessageDecryptionState.decrypted);
  });

  test('decrypted event does not regress after a later transient failure', () {
    final controller = DecryptionStateController();
    controller.lateKeyReceived('event-1');
    controller.markFailed('event-1', eventCode: 'NETWORK_RETRY');

    final entry = controller.stateFor('event-1');
    expect(entry.state, MessageDecryptionState.decrypted);
    expect(entry.eventCode, isNull);
  });
}
