import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/nudge_service.dart';

final class FakeBackend implements NudgeBackend {
  Map<String, Object?>? content;
  @override
  Future<void> sendEncrypted(
          String roomId, String type, Map<String, Object?> value) async =>
      content = value;
}

void main() {
  test('nudge suffix belongs to the target profile, not the sender', () async {
    final backend = FakeBackend();
    final service = NudgeService(
        backend: backend,
        roomId: '!r',
        senderId: '@alice:test',
        senderDisplayName: 'Alice');
    await service.send(
        targetUserId: '@bob:test', targetDisplayName: 'Bob', suffix: '拍了拍我的肩膀');
    expect(backend.content!['target_user_id'], '@bob:test');
    expect(backend.content!['suffix'], '拍了拍我的肩膀');
  });
}
