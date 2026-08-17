import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/nudge_service.dart';

final class FakeNudgeBackend implements NudgeBackend {
  final events = <Map<String, Object?>>[];

  @override
  Future<void> sendEncrypted(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async {
    expect(type, 'com.changliao.nudge');
    events.add(content);
  }
}

final class FakeNudgePreferenceBackend implements NudgePreferenceBackend {
  String value = '';

  @override
  Future<String> loadSuffix() async => value;

  @override
  Future<void> saveSuffix(String suffix) async => value = suffix;
}

void main() {
  test('one avatar double tap sends one encrypted nudge snapshot', () async {
    final backend = FakeNudgeBackend();
    final service = NudgeService(
      backend: backend,
      roomId: '!chat:test',
      senderId: '@alice:test',
      senderDisplayName: 'Alice',
    );

    await service.send(
      targetUserId: '@bob:test',
      targetDisplayName: 'Bob',
      suffix: '的肩膀',
    );

    expect(backend.events, hasLength(1));
    expect(backend.events.single, {
      'sender_id': '@alice:test',
      'sender_display_name': 'Alice',
      'target_user_id': '@bob:test',
      'target_display_name': 'Bob',
      'suffix': '的肩膀',
    });
  });

  test('custom nudge suffix round-trips through encrypted preference backend',
      () async {
    final backend = FakeNudgePreferenceBackend();
    final preferences = NudgePreferenceService(backend);

    await preferences.saveSuffix('的肩膀');

    expect(await preferences.loadSuffix(), '的肩膀');
    expect(
      () => preferences.saveSuffix(List.filled(31, 'x').join()),
      throwsArgumentError,
    );
  });
}
