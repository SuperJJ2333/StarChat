import 'dart:typed_data';
import 'package:matrix/matrix.dart';
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
  const GroupAnnouncement(this.blocks, {this.publisherName, this.publishedAt});
  final List<AnnouncementBlock> blocks;
  final String? publisherName;
  final DateTime? publishedAt;
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
      throw const FormatException('群公告最多100段，请删除部分内容后重试');
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
  @override
  bool get canEdit => GroupRoomAuthority(room).canManage;
  @override
  Stream<void> get changes => room.client.onSync.stream
      .where((update) => update.rooms?.join?.containsKey(room.id) == true)
      .map<void>((_) {});
  @override
  Future<GroupAnnouncement> load() async {
    _requireMember();
    final reference = room.getState(groupAnnouncementStateType);
    if (reference == null) {
      // Read-only compatibility for announcements published by older clients.
      // An existing empty reference is an explicit clear and must win over it.
      final legacy = room.topic.trim();
      return GroupAnnouncement(
          legacy.isEmpty ? [] : [AnnouncementBlock.text(legacy)]);
    }
    if (reference.content['event_id'] == null) {
      return const GroupAnnouncement([]);
    }
    final eventId = reference.content['event_id'];
    if (eventId is! String || !eventId.startsWith(r'$')) {
      throw FormatException('公告引用无效');
    }
    final event = await _loadEncryptedEvent(eventId);
    if (event == null ||
        event.senderId != reference.senderId ||
        event.originalSource?.type != EventTypes.Encrypted) {
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
        publishedAt: event.originServerTs);
  }

  void _requireMember() {
    if (room.client.userID == null || room.membership != Membership.join) {
      throw StateError('仅群成员可查看公告');
    }
  }

  Future<Event?> _loadEncryptedEvent(String eventId) async {
    _requireMember();
    var event = await room.getEventById(eventId);
    // SDK cache hits can still be ciphertext; its network path alone decrypts.
    if (event?.type == EventTypes.Encrypted && room.client.encryptionEnabled) {
      event = await room.client.encryption?.decryptRoomEvent(room.id, event!);
    }
    _requireMember();
    return event;
  }

  void _requireEncryptedManager() {
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
    if (!announcement.isEffective) {
      await room.client
          .setRoomStateWithKey(room.id, groupAnnouncementStateType, '', {});
      return;
    }
    final publishedBlocks = <AnnouncementBlock>[];
    for (final block in announcement.blocks) {
      publishedBlocks.add(block.localBytes == null
          ? block
          : AnnouncementBlock.image(
              await uploadImage(block.localBytes!, block.fileName!)));
    }
    final id =
        await room.sendEvent(GroupAnnouncement(publishedBlocks).toContent());
    if (id == null || !id.startsWith(r'$')) throw StateError('公告发送失败');
    // Public state contains no body, attachment URL or encryption key.
    await room.client.setRoomStateWithKey(
        room.id, groupAnnouncementStateType, '', {'event_id': id});
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
      /* Preserve the original when no thumbnail can be generated. */
    }
    if (thumbnail != null && thumbnail.size > file.size) thumbnail = null;
    final prepared =
        await prepareContentAddressedMedia(file: file, thumbnail: thumbnail);
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
        event.originalSource?.type != EventTypes.Encrypted) {
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
      if (!event.isAttachmentEncrypted) {
        throw StateError('图片暂不可用');
      }
      return (await event.downloadAndDecryptAttachment()).bytes;
    });
    validateAnnouncementImage(bytes);
    return bytes;
  }
}
