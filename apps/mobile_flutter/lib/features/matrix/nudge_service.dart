import 'package:matrix/matrix.dart';

import 'matrix_message_reminder_backend.dart';

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

final class MatrixNudgeBackend implements NudgeBackend {
  const MatrixNudgeBackend(this.client);

  final Client client;

  @override
  Future<void> sendEncrypted(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async {
    final room = client.getRoomById(roomId);
    if (room == null || !room.encrypted || !client.encryptionEnabled) {
      throw StateError('拍一拍只能发送到端到端加密会话');
    }
    await room.sendEvent(Map<String, dynamic>.from(content), type: type);
  }
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
    if (suffix.runes.length > 30) {
      throw ArgumentError.value(suffix, 'suffix', '拍一拍后缀不能超过 30 个字符');
    }
    return backend.saveSuffix(suffix.trim());
  }
}

final class MatrixNudgePreferenceBackend implements NudgePreferenceBackend {
  const MatrixNudgePreferenceBackend(this.client);

  final Client client;

  Room get _room {
    final roomId = client
        .accountData[messageReminderAccountDataType]?.content['room_id']
        ?.toString();
    final room = roomId == null ? null : client.getRoomById(roomId);
    if (room == null || !room.encrypted || !client.encryptionEnabled) {
      throw StateError('拍一拍设置必须使用账号私有加密配置房间');
    }
    return room;
  }

  @override
  Future<String> loadSuffix() async {
    final timeline = await _room.getTimeline();
    try {
      final events = timeline.events
          .where((event) => event.type == changliaoNudgePreferenceEventType)
          .toList(growable: false)
        ..sort((a, b) => b.originServerTs.compareTo(a.originServerTs));
      return events.isEmpty
          ? ''
          : events.first.content['suffix']?.toString() ?? '';
    } finally {
      timeline.cancelSubscriptions();
    }
  }

  @override
  Future<void> saveSuffix(String suffix) async {
    await _room.sendEvent(
      {'suffix': suffix},
      type: changliaoNudgePreferenceEventType,
    );
  }
}
