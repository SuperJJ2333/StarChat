import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart' show DecryptException;
import 'group_room_authority.dart';
import 'gif_image_policy.dart';
import 'content_addressed_media.dart';
import 'media_cache.dart';

const maxAnnouncementBlocks = 100;
const maxAnnouncementImageBytes = 20 * 1024 * 1024;
const maxAnnouncementDraftImageBytes = 40 * 1024 * 1024;

void validateAnnouncementImage(Uint8List bytes) {
  if (bytes.length > maxAnnouncementImageBytes) {
    throw const FormatException('公告图片不能超过20MB');
  }
  validateGifForSend(bytes);
}

const groupAnnouncementMessageType =
    'com.changliao.group.announcement.document';

final class AnnouncementPendingDecryption implements Exception {
  const AnnouncementPendingDecryption();
}

// The SDK cannot request a session for this encrypted payload (for example an
// unsupported algorithm or a rejected replay). Do not promise another retry
// will decrypt it, and do not weaken the SDK's validation to display it.
final class AnnouncementDecryptionUnavailable implements Exception {
  const AnnouncementDecryptionUnavailable();
}

final class AnnouncementBlock {
  const AnnouncementBlock.text(this.value)
      : isImage = false,
        localBytes = null,
        fileName = null;
  const AnnouncementBlock.image(this.value)
      : isImage = true,
        localBytes = null,
        fileName = null;
  AnnouncementBlock.localImage(Uint8List bytes, this.fileName)
      : isImage = true,
        value = '',
        localBytes = Uint8List.fromList(bytes);
  final Uint8List? localBytes;
  final String? fileName;
  final String value;
  final bool isImage;
}

final class GroupAnnouncement {
  const GroupAnnouncement(this.blocks,
      {this.publisherName, this.publishedAt, this.publicationId});
  final List<AnnouncementBlock> blocks;
  final String? publisherName;
  final DateTime? publishedAt;

  /// The selected Matrix document event, stable across room/page recreation.
  final String? publicationId;
  bool get isEffective => blocks.any(
      (block) => block.localBytes != null || block.value.trim().isNotEmpty);
  String get preview =>
      blocks
          .where((b) => !b.isImage && b.value.trim().isNotEmpty)
          .map((b) => b.value.trim())
          .firstOrNull ??
      (isEffective ? '[图片公告]' : '');
  void validateForSave() {
    if (blocks.length > maxAnnouncementBlocks) {
      throw const FormatException('群公告内容已达上限，请删除部分图片后重试');
    }
    var total = 0;
    for (final block in blocks) {
      if (block.localBytes == null) continue;
      validateAnnouncementImage(block.localBytes!);
      total += block.localBytes!.length;
    }
    if (total > maxAnnouncementDraftImageBytes) {
      throw const FormatException('公告草稿图片合计不能超过40MB');
    }
  }

  Map<String, dynamic> toContent() {
    validateForSave();
    if (blocks.any((block) => block.localBytes != null)) {
      throw StateError('草稿图片尚未发布');
    }
    return {
      'msgtype': groupAnnouncementMessageType,
      'body': '群公告',
      'blocks': [
        for (final block in blocks)
          {'type': block.isImage ? 'image' : 'text', 'value': block.value}
      ],
    };
  }

  factory GroupAnnouncement.fromContent(Map<String, dynamic> content) {
    if (content['msgtype'] != groupAnnouncementMessageType) {
      throw FormatException('公告格式无效');
    }
    final blocks = content['blocks'];
    if (blocks is! List || blocks.length > maxAnnouncementBlocks) {
      throw FormatException('公告格式无效');
    }
    return GroupAnnouncement([
      for (final block in blocks)
        if (block is Map && block['value'] is String && block['type'] == 'text')
          AnnouncementBlock.text(block['value'] as String)
        else if (block is Map &&
            block['value'] is String &&
            block['type'] == 'image' &&
            (block['value'] as String).startsWith(r'$'))
          AnnouncementBlock.image(block['value'] as String),
    ]);
  }
}

abstract interface class GroupAnnouncementService {
  bool get canEdit;
  Stream<void> get changes;
  Future<GroupAnnouncement> load();
  Future<void> save(GroupAnnouncement announcement);
  Future<String> uploadImage(Uint8List bytes, String name);
  Future<Uint8List> loadImage(String eventId);
}

final class MatrixGroupAnnouncementService implements GroupAnnouncementService {
  MatrixGroupAnnouncementService(this.room);
  final Room room;
  // Stop retrying the same inaccessible historical payload on every sync.
  // Cached ciphertext can still decrypt locally when a valid key arrives.
  static final _unavailable = Expando<Map<String, Event>>();
  static const _diagnosticsEnabled =
      bool.fromEnvironment('ANNOUNCEMENT_DIAGNOSTICS');

  // Temporary, opt-in device diagnostics. Never send these through telemetry:
  // only fixed codes and presence booleans can reach the local log sink.
  void _diagnose(String stage, [Event? event]) {
    if (!_diagnosticsEnabled) return;
    final badEncrypted = event?.messageType == MessageTypes.BadEncrypted;
    final body = badEncrypted ? event?.content['body'] : null;
    final code = !badEncrypted
        ? 'none'
        : switch (body) {
            DecryptException.unknownSession => 'no_session',
            'UNKNOWN_MESSAGE_INDEX' ||
            'Exception: UNKNOWN_MESSAGE_INDEX' =>
              'unknown_index',
            DecryptException.unknownAlgorithm => 'unsupported',
            DecryptException.channelCorrupted => 'corrupted',
            _ => 'other',
          };
    final source = event?.originalSource ?? event;
    debugPrint('ANNOUNCEMENT_DIAGNOSTIC ${jsonEncode({
          'stage': stage,
          'code': code,
          'event_exists': event != null,
          'encrypted': event?.type == EventTypes.Encrypted,
          'bad_encrypted': badEncrypted,
          'can_request': event?.content['can_request_session'] == true,
          'has_original': event?.originalSource != null,
          'has_ciphertext': source?.content['ciphertext'] is String,
          'has_session': source?.content['session_id'] is String ||
              event?.content['session_id'] is String,
          'has_sender_key': source?.content['sender_key'] is String ||
              event?.content['sender_key'] is String,
          'crypto_enabled': room.client.encryptionEnabled,
          'joined': room.membership == Membership.join,
        })}');
  }

  @override
  bool get canEdit => GroupRoomAuthority(room).canManage;
  @override
  Stream<void> get changes => Stream<void>.multi((controller) {
        final sync = room.client.onSync.stream
            .where((update) => update.rooms?.join?.containsKey(room.id) == true)
            .listen((_) => controller.add(null));
        // Session recovery can arrive without a room timeline/state update.
        final keys = room.onSessionKeyReceived.stream.listen((_) {
          _diagnose('key_received');
          controller.add(null);
        });
        controller.onCancel = () async {
          await sync.cancel();
          await keys.cancel();
        };
      });
  @override
  Future<GroupAnnouncement> load() async {
    _requireMember();
    final reference = room.getState(groupAnnouncementStateType);
    if (reference == null) {
      // Read-only compatibility for announcements published by older clients.
      // An existing empty reference is an explicit clear and must win over it.
      final legacy = room.topic.trim();
      final topicState = room.getState(EventTypes.RoomTopic);
      return GroupAnnouncement(
          legacy.isEmpty ? [] : [AnnouncementBlock.text(legacy)],
          publicationId: legacy.isNotEmpty && topicState is Event
              ? topicState.eventId
              : null);
    }
    if (reference.content['event_id'] == null) {
      return const GroupAnnouncement([]);
    }
    final eventId = reference.content['event_id'];
    if (eventId is! String || !eventId.startsWith(r'$')) {
      throw FormatException('公告引用无效');
    }
    final event = await _loadEncryptedEvent(eventId,
        expectedSenderId: reference.senderId);
    if (event == null ||
        event.senderId != reference.senderId ||
        event.type != EventTypes.Message) {
      throw StateError('公告暂不可用');
    }
    final document = GroupAnnouncement.fromContent(event.content);
    final displayName = room
        .getState(EventTypes.RoomMember, event.senderId)
        ?.content['displayname'];
    final name = displayName is String ? displayName.trim() : null;
    return GroupAnnouncement(document.blocks,
        publisherName:
            name == null || name.isEmpty || name.startsWith('@') ? '群成员' : name,
        publishedAt: event.originServerTs,
        publicationId: eventId);
  }

  void _requireMember() {
    if (room.client.userID == null || room.membership != Membership.join) {
      throw StateError('仅群成员可查看公告');
    }
  }

  Future<Event?> _loadEncryptedEvent(String eventId,
      {String? expectedSenderId}) async {
    _requireMember();
    final failed = _unavailable[room]?[eventId];
    // Cached failures only retry local keys. No new network or key request is
    // generated by rebuilds; a subsequently received key can still unlock it.
    var event = failed == null
        ? await room.getEventById(eventId)
        : room.client.encryption?.decryptRoomEventSync(room.id,
                Event.fromMatrixEvent(failed.originalSource ?? failed, room)) ??
            failed;
    _diagnose('loaded', event);
    if (event != null &&
        expectedSenderId != null &&
        event.senderId != expectedSenderId) {
      throw StateError('公告暂不可用');
    }
    // Failed SDK projections can omit ciphertext for non-requestable errors.
    // Always retry their original encrypted event, never the error projection.
    if (event?.messageType == MessageTypes.BadEncrypted &&
        event?.originalSource?.type == EventTypes.Encrypted) {
      event = Event.fromMatrixEvent(event!.originalSource!, room);
    }
    // SDK cache hits can still be ciphertext; its network path alone decrypts.
    if (failed == null &&
        event?.type == EventTypes.Encrypted &&
        room.client.encryptionEnabled) {
      event = await room.client.encryption?.decryptRoomEvent(room.id, event!);
    }
    _diagnose('decrypted', event);
    _requireMember();
    if (event?.type == EventTypes.Encrypted ||
        event?.messageType == MessageTypes.BadEncrypted) {
      if (event != null) {
        (_unavailable[room] ??= <String, Event>{})[eventId] = event;
      }
      throw const AnnouncementDecryptionUnavailable();
    }
    return event;
  }

  void _requireEncryptedManager() {
    _requireMember();
    GroupRoomAuthority(room).requireManager();
    if (!room.encrypted || !room.client.encryptionEnabled) {
      throw StateError('请完成端到端加密设置后发布公告');
    }
  }

  @override
  Future<void> save(GroupAnnouncement announcement) async {
    announcement.validateForSave();
    _requireEncryptedManager();
    await GroupRoomAuthority(room).protectState();
    _requireEncryptedManager();
    if (!announcement.isEffective) {
      await room.client
          .setRoomStateWithKey(room.id, groupAnnouncementStateType, '', {});
      return;
    }
    final publishedBlocks = <AnnouncementBlock>[];
    for (final block in announcement.blocks) {
      if (!block.isImage) {
        publishedBlocks.add(block);
      } else if (block.localBytes != null) {
        publishedBlocks.add(AnnouncementBlock.image(
            await uploadImage(block.localBytes!, block.fileName!)));
      } else {
        publishedBlocks.add(AnnouncementBlock.image(
            await _encryptedImageReference(block.value)));
      }
    }
    _requireEncryptedManager();
    final id =
        await room.sendEvent(GroupAnnouncement(publishedBlocks).toContent());
    if (id == null || !id.startsWith(r'$')) throw StateError('公告发送失败');
    // Public state contains only the encrypted document's event ID.
    _requireEncryptedManager();
    await room.client.setRoomStateWithKey(
        room.id, groupAnnouncementStateType, '', {'event_id': id});
  }

  Future<String> _encryptedImageReference(String eventId) async {
    try {
      final event = await _loadEncryptedEvent(eventId);
      if (event == null || event.messageType != MessageTypes.Image) {
        throw const FormatException('旧公告图片无法读取，请删除或重新选择图片后发布');
      }
      if (event.originalSource?.type != EventTypes.Encrypted &&
          !event.isAttachmentEncrypted &&
          event.content['com.changliao.group.announcement.image'] != true) {
        throw const FormatException('公告图片无效，请删除或重新选择图片后发布');
      }
      // A retained public image must be encrypted before it can enter a new
      // announcement document. Only this administrator-selected image is copied.
      final bytes = await loadImage(eventId);
      return uploadImage(bytes, event.body);
    } on AnnouncementDecryptionUnavailable {
      throw const FormatException('旧公告图片缺少解密密钥，请删除或重新选择图片后发布');
    } on AnnouncementPendingDecryption {
      throw const FormatException('旧公告图片缺少解密密钥，请删除或重新选择图片后发布');
    }
  }

  @override
  Future<String> uploadImage(Uint8List bytes, String name) async {
    validateAnnouncementImage(bytes);
    _requireEncryptedManager();
    final file = MatrixImageFile(bytes: bytes, name: name);
    MatrixImageFile? thumbnail;
    try {
      thumbnail = await file.generateThumbnail(
          nativeImplementations: room.client.nativeImplementations,
          customImageResizer: room.client.customImageResizer);
    } catch (_) {
      // The original image can still be sent when no thumbnail is available.
    }
    if (thumbnail != null && thumbnail.size > file.size) thumbnail = null;
    final prepared =
        await prepareContentAddressedMedia(file: file, thumbnail: thumbnail);
    _requireEncryptedManager();
    final id = await room.sendFileEvent(prepared.file,
        thumbnail: prepared.thumbnail, extraContent: prepared.extraContent);
    if (id == null || !id.startsWith(r'$')) throw StateError('图片上传失败');
    return id;
  }

  @override
  Future<Uint8List> loadImage(String eventId) async {
    final event = await _loadEncryptedEvent(eventId);
    if (event == null ||
        event.messageType != MessageTypes.Image ||
        (event.originalSource?.type != EventTypes.Encrypted &&
            event.content['com.changliao.group.announcement.image'] != true)) {
      throw StateError('图片暂不可用');
    }
    final declaredSize = event.infoMap['size'];
    if (declaredSize is num && declaredSize > maxAnnouncementImageBytes) {
      throw const FormatException('公告图片不能超过20MB');
    }
    final hashes = TrustedMediaHashes.fromEvent(event);
    final bytes = await loadMediaWithCache(
        MediaCacheKey(
            accountId: room.client.userID ?? '',
            roomId: room.id,
            eventId: eventId,
            sourceIdentity: matrixMediaSourceIdentity(event.content),
            contentSha256: hashes?.contentSha256), () async {
      return (await event.downloadAndDecryptAttachment()).bytes;
    });
    _requireMember();
    validateAnnouncementImage(bytes);
    return bytes;
  }
}
