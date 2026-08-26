import 'dart:io';

import 'package:http/http.dart' as http;

abstract interface class MessageInteractionBackend {
  Future<void> send(String roomId, Map<String, Object?> content);
  Future<void> redact(String roomId, String eventId, String reason);
  Future<void> forwardEncryptedCopy(
    String sourceRoomId,
    String targetRoomId,
    String eventId,
  );
}

final class MessageInteractionEvent {
  const MessageInteractionEvent({
    required this.id,
    required this.senderId,
    required this.originServerTs,
  });

  final String id;
  final String senderId;
  final DateTime originServerTs;
}

final class MessageInteractionService {
  const MessageInteractionService({
    required this.backend,
    required this.roomId,
    required this.currentUserId,
  });

  final MessageInteractionBackend backend;
  final String roomId;
  final String currentUserId;

  bool canRecall(MessageInteractionEvent event, DateTime serverNow) {
    if (event.senderId != currentUserId) return false;
    final age = serverNow.difference(event.originServerTs);
    return !age.isNegative && age <= const Duration(minutes: 2);
  }

  Future<void> recall(
    MessageInteractionEvent event, {
    required DateTime serverNow,
  }) {
    if (!canRecall(event, serverNow)) {
      throw StateError('消息已超过两分钟撤回期限或不属于当前账号');
    }
    return backend.redact(roomId, event.id, '用户撤回了一条消息');
  }

  Future<void> reply(
    String eventId,
    String text, {
    List<String> mentionedUserIds = const [],
  }) =>
      backend.send(roomId, {
        'msgtype': 'm.text',
        'body': text,
        'm.relates_to': {
          'm.in_reply_to': {'event_id': eventId},
        },
        if (mentionedUserIds.isNotEmpty)
          'm.mentions': {
            'user_ids': List<String>.unmodifiable(mentionedUserIds),
          },
      });

  Future<void> sendMention(String text, List<String> userIds) =>
      backend.send(roomId, {
        'msgtype': 'm.text',
        'body': text,
        'm.mentions': {'user_ids': List<String>.unmodifiable(userIds)},
      });

  Future<void> forward(String eventId, String targetRoomId) =>
      backend.forwardEncryptedCopy(roomId, targetRoomId, eventId);
}

final class MentionDraft {
  final Map<String, String> _markersByUserId = <String, String>{};

  String append(
    String currentText, {
    required String displayName,
    required String userId,
  }) {
    final marker = '@$displayName';
    _markersByUserId[userId] = marker;
    return '$currentText$marker ';
  }

  List<String> activeUserIds(String text) => _markersByUserId.entries
      .where((entry) => text.contains(entry.value))
      .map((entry) => entry.key)
      .toList(growable: false);

  void clear() => _markersByUserId.clear();
}

String resolveMessageSenderDisplayName({
  required String senderId,
  String? contactDisplayName,
  String? matrixDisplayName,
}) {
  final contact = contactDisplayName?.trim();
  if (contact != null && contact.isNotEmpty) return contact;
  final matrix = matrixDisplayName?.trim();
  if (matrix != null && matrix.isNotEmpty) return matrix;
  final localPart = senderId.startsWith('@') ? senderId.substring(1) : senderId;
  return localPart.split(':').first;
}

final class MatrixServerClock {
  MatrixServerClock({
    required this.homeserver,
    http.Client? httpClient,
  }) : httpClient = httpClient ?? http.Client();

  final Uri homeserver;
  final http.Client httpClient;

  Future<DateTime> now() async {
    final response = await httpClient.get(
      homeserver.resolve('/_matrix/client/versions'),
    );
    final date = response.headers['date'];
    if (date == null) throw StateError('Matrix homeserver 未返回服务器时间');
    return HttpDate.parse(date).toUtc();
  }
}
