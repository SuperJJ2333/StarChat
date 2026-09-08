import 'dart:typed_data';
import 'package:matrix/matrix.dart';
import 'group_room_authority.dart';
import 'gif_image_policy.dart';

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
  const GroupAnnouncement(this.blocks);
  final List<AnnouncementBlock> blocks;
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

final class MatrixGroupAnnouncementService {
  MatrixGroupAnnouncementService(this.room);
  final Room room;
  bool get canEdit => GroupRoomAuthority(room).canManage;
  Future<GroupAnnouncement> load() async {
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
    final event = await room.getEventById(eventId);
    if (event == null ||
        event.senderId != reference.senderId ||
        event.originalSource?.type != EventTypes.Encrypted) {
      throw StateError('公告暂不可用');
    }
    return GroupAnnouncement.fromContent(event.content);
  }

  void _requireEncryptedManager() {
    GroupRoomAuthority(room).requireManager();
    if (!room.encrypted || !room.client.encryptionEnabled) {
      throw StateError('请完成端到端加密设置后发布公告');
    }
  }

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

  Future<String> uploadImage(Uint8List bytes, String name) async {
    validateAnnouncementImage(bytes);
    _requireEncryptedManager();
    final id =
        await room.sendFileEvent(MatrixImageFile(bytes: bytes, name: name));
    if (id == null || !id.startsWith(r'$')) throw StateError('图片上传失败');
    return id;
  }

  Future<Uint8List> loadImage(String eventId) async {
    final event = await room.getEventById(eventId);
    if (event == null ||
        event.messageType != MessageTypes.Image ||
        event.originalSource?.type != EventTypes.Encrypted ||
        !event.isAttachmentEncrypted) {
      throw StateError('图片暂不可用');
    }
    final declaredSize = event.infoMap['size'];
    if (declaredSize is num && declaredSize > maxAnnouncementImageBytes) {
      throw const FormatException('公告图片不能超过20MB');
    }
    final bytes = (await event.downloadAndDecryptAttachment()).bytes;
    validateAnnouncementImage(bytes);
    return bytes;
  }
}
