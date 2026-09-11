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
  Future<void> forwardEncryptedText(
      String sourceRoomId, String targetRoomId, String text);
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
    return !age.isNegative && age <= const Duration(minutes: 3);
  }

  Future<void> recall(
    MessageInteractionEvent event, {
    required DateTime serverNow,
  }) {
    if (!canRecall(event, serverNow)) {
      throw StateError('消息已超过三分钟撤回期限或不属于当前账号');
    }
    return backend.redact(roomId, event.id, '用户撤回了一条消息');
  }

  Future<void> reply(
    String eventId,
    String text, {
    String? selectedQuote,
    List<String> mentionedUserIds = const [],
  }) =>
      backend.send(roomId, {
        'msgtype': 'm.text',
        'body': text,
        'm.relates_to': {
          'm.in_reply_to': {'event_id': eventId},
        },
        if (selectedQuote != null) 'io.changliao.selected_quote': selectedQuote,
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

  /// Sends selected plaintext as a new encrypted Matrix text event in the
  /// chosen encrypted destination. It deliberately has no source event ID.
  Future<void> forwardText(String text, String targetRoomId) {
    if (text.isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
    return backend.forwardEncryptedText(roomId, targetRoomId, text);
  }
}

final class MentionDraft {
  final Map<String, List<String>> _userIdsByMarker = <String, List<String>>{};

  String append(
    String currentText, {
    required String displayName,
    required String userId,
  }) {
    final marker = '@$displayName';
    _userIdsByMarker[marker] = [userId];
    return '$currentText$marker ';
  }

  /// Inserts the 群管理员/群主-only 「@所有人」 marker that mentions every
  /// given member id when the message is sent.
  String appendAll(
    String currentText, {
    required List<String> userIds,
  }) {
    const marker = '@所有人';
    _userIdsByMarker[marker] = List<String>.unmodifiable(userIds);
    return '$currentText$marker ';
  }

  List<String> activeUserIds(String text) => [
        for (final entry in _userIdsByMarker.entries)
          if (text.contains(entry.key)) ...entry.value,
      ];

  void clear() => _userIdsByMarker.clear();
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

/// 拍一拍 wording follows the viewer's perspective:
/// - viewers see their own pat as 「我拍了拍{备注或昵称}」;
/// - pats from other members show plain nicknames on both sides so the
///   remark a member set for somebody never reaches anyone else.
String formatNudgeNotice({
  required String viewerId,
  required String senderId,
  required String senderName,
  required String targetUserId,
  required String targetName,
  String suffix = '',
  String? viewerRemarkForTarget,
  String? targetLiveName,
  String? senderLiveName,
}) {
  String? firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  if (senderId == viewerId) {
    final target = firstNonEmpty([
      viewerRemarkForTarget,
      targetLiveName,
      targetName,
    ]);
    return '我拍了拍${target ?? '好友'}$suffix';
  }
  final sender = firstNonEmpty([senderLiveName, senderName]) ?? '好友';
  final target = firstNonEmpty([targetLiveName, targetName]) ?? '好友';
  return '$sender拍了拍$target$suffix';
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
