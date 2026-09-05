import 'package:matrix/matrix.dart';

import 'message_reminder_service.dart';

const messageReminderAccountDataType = 'com.changliao.reminders.control';
const messageReminderEventType = 'com.changliao.reminder';

final class MatrixMessageReminderBackend
    implements MessageReminderBackend, ReminderSnapshotSource {
  const MatrixMessageReminderBackend._({
    required this.client,
    required this.roomId,
  });

  final Client client;
  final String roomId;

  static Future<MatrixMessageReminderBackend> open(Client client) async {
    var roomId = client
        .accountData[messageReminderAccountDataType]?.content['room_id']
        ?.toString();
    if (roomId == null || roomId.isEmpty) {
      roomId = await client.createGroupChat(
        groupName: '畅聊提醒同步',
        enableEncryption: true,
        invite: const [],
        preset: CreateRoomPreset.privateChat,
        visibility: Visibility.private,
        waitForSync: true,
      );
      final userId = client.userID;
      if (userId == null) throw StateError('Matrix client is not logged in');
      await client.setAccountData(
        userId,
        messageReminderAccountDataType,
        {'room_id': roomId},
      );
      await client.oneShotSync();
    }
    var room = client.getRoomById(roomId);
    if (room != null && !room.encrypted) {
      await room.enableEncryption();
      await client.oneShotSync();
      room = client.getRoomById(roomId);
    }
    if (room == null || !room.encrypted || !client.encryptionEnabled) {
      throw StateError('提醒同步房间必须启用 Matrix E2EE');
    }
    return MatrixMessageReminderBackend._(client: client, roomId: roomId);
  }

  Room get _room =>
      client.getRoomById(roomId) ?? (throw StateError('提醒同步房间不存在'));

  @override
  Stream<void> get changes => client.onSync.stream.map<void>((_) {});

  @override
  Future<void> sendEncrypted(MessageReminder reminder) async {
    if (!_room.encrypted || !client.encryptionEnabled) {
      throw StateError('提醒定义必须通过 Matrix E2EE 同步');
    }
    await _room.sendEvent(
      Map<String, dynamic>.from(reminder.toJson()),
      type: messageReminderEventType,
    );
  }

  @override
  Future<List<MessageReminder>> load() async {
    final timeline = await _room.getTimeline();
    try {
      return timeline.events
          .where((event) => event.type == messageReminderEventType)
          .map((event) {
            try {
              return MessageReminder.fromJson(
                Map<String, Object?>.from(event.content),
              );
            } catch (_) {
              return null;
            }
          })
          .whereType<MessageReminder>()
          .toList(growable: false);
    } finally {
      timeline.cancelSubscriptions();
    }
  }
}
