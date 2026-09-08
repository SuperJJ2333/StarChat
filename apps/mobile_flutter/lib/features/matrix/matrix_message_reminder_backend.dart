import 'dart:async';

import 'package:matrix/matrix.dart';

import 'message_reminder_service.dart';

const messageReminderAccountDataType = 'com.changliao.reminders.control';
const messageReminderEventType = 'com.changliao.reminder';

final class MatrixMessageReminderBackend
    implements MessageReminderBackend, ReminderSnapshotSource {
  MatrixMessageReminderBackend._({
    required Client client,
    required this.roomId,
    required void Function() ensureActive,
  })  : _client = client,
        _ensureActive = ensureActive;

  final Client _client;
  final String roomId;
  final void Function() _ensureActive;
  var _disposed = false;
  int _operations = 0;
  Completer<void>? _operationsDrained;

  Future<T> _execute<T>(Future<T> Function() operation) async {
    if (_disposed) throw StateError('提醒同步后端已关闭');
    _ensureActive();
    if (_operations++ == 0) _operationsDrained = Completer<void>();
    try {
      return await operation();
    } finally {
      if (--_operations == 0) {
        _operationsDrained?.complete();
        _operationsDrained = null;
      }
    }
  }

  static Future<MatrixMessageReminderBackend> open(
    Client client, {
    void Function()? ensureActive,
  }) async {
    final active = ensureActive ?? () {};
    active();
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
    return MatrixMessageReminderBackend._(
      client: client,
      roomId: roomId,
      ensureActive: active,
    );
  }

  Room get _room =>
      _client.getRoomById(roomId) ?? (throw StateError('提醒同步房间不存在'));

  @override
  Stream<void> get changes {
    if (_disposed) return const Stream<void>.empty();
    _ensureActive();
    return _client.onSync.stream.map<void>((_) {});
  }

  @override
  Future<void> sendEncrypted(MessageReminder reminder) => _execute(() async {
        if (!_room.encrypted || !_client.encryptionEnabled) {
          throw StateError('提醒定义必须通过 Matrix E2EE 同步');
        }
        await _room.sendEvent(
          Map<String, dynamic>.from(reminder.toJson()),
          type: messageReminderEventType,
        );
      });

  @override
  Future<List<MessageReminder>> load() => _execute(() async {
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
      });

  Future<void> dispose() async {
    _disposed = true;
    final drained = _operationsDrained;
    if (drained != null) await drained.future;
  }
}
