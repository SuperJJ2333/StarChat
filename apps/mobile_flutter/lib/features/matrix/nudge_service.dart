const changliaoNudgeEventType = 'com.changliao.nudge';
const changliaoNudgePreferenceEventType = 'com.changliao.nudge.preference';

abstract interface class NudgeBackend {
  Future<void> sendEncrypted(
    String roomId,
    String type,
    Map<String, Object?> content,
  );
}

final class NudgeService {
  const NudgeService({
    required this.backend,
    required this.roomId,
    required this.senderId,
    required this.senderDisplayName,
  });

  final NudgeBackend backend;
  final String roomId;
  final String senderId;
  final String senderDisplayName;

  Future<void> send({
    required String targetUserId,
    required String targetDisplayName,
    required String suffix,
  }) =>
      backend.sendEncrypted(roomId, changliaoNudgeEventType, {
        'sender_id': senderId,
        'sender_display_name': senderDisplayName,
        'target_user_id': targetUserId,
        'target_display_name': targetDisplayName,
        'suffix': suffix,
      });
}

abstract interface class NudgePreferenceBackend {
  Future<String> loadSuffix();
  Future<void> saveSuffix(String suffix);
}

final class NudgePreferenceService {
  const NudgePreferenceService(this.backend);

  final NudgePreferenceBackend backend;

  Future<String> loadSuffix() => backend.loadSuffix();

  Future<void> saveSuffix(String suffix) {
    if (suffix.runes.length > 10) {
      throw ArgumentError.value(suffix, 'suffix', '拍一拍后缀不能超过 10 个字符');
    }
    return backend.saveSuffix(suffix.trim());
  }
}
