import 'dart:typed_data';

import 'package:matrix/matrix.dart';

import 'emoji_vault.dart';

const _vaultAccountDataType = 'com.changliao.emoji.vault';

abstract interface class MatrixEmojiVaultBackend {
  String? readStoredRoomId();
  Future<String> createEncryptedVaultRoom();
  Future<void> storeRoomId(String roomId);
  Future<bool> isRoomEncrypted(String roomId);
  Future<List<EmojiVaultEvent>> loadEvents(String roomId);
  Future<Map<String, Object?>> uploadEncrypted(
    String roomId,
    Uint8List bytes,
    String mimeType,
  );
  Future<void> sendEncryptedEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  );
}

final class MatrixEmojiVault {
  const MatrixEmojiVault._({required this.roomId, required this.vault});

  final String roomId;
  final EmojiVault vault;

  static Future<MatrixEmojiVault> open(
    MatrixEmojiVaultBackend backend,
  ) async {
    var roomId = backend.readStoredRoomId();
    if (roomId == null || roomId.isEmpty) {
      roomId = await backend.createEncryptedVaultRoom();
      await backend.storeRoomId(roomId);
    }
    if (!await backend.isRoomEncrypted(roomId)) {
      throw StateError('Stored emoji vault room is not end-to-end encrypted');
    }
    final transport = _MatrixEmojiVaultTransport(
      backend: backend,
      roomId: roomId,
    );
    final vault = EmojiVault(transport: transport);
    vault.apply(await backend.loadEvents(roomId));
    return MatrixEmojiVault._(roomId: roomId, vault: vault);
  }
}

final class _MatrixEmojiVaultTransport implements EmojiVaultTransport {
  const _MatrixEmojiVaultTransport({
    required this.backend,
    required this.roomId,
  });

  final MatrixEmojiVaultBackend backend;
  final String roomId;

  @override
  bool get isEncrypted => true;

  @override
  Future<Map<String, Object?>> uploadEncrypted(
    Uint8List bytes,
    String mimeType,
  ) =>
      backend.uploadEncrypted(roomId, bytes, mimeType);

  @override
  Future<void> sendEncrypted(EmojiVaultEvent event) =>
      backend.sendEncryptedEvent(roomId, event.matrixType, event.toJson());
}

final class MatrixSdkEmojiVaultBackend implements MatrixEmojiVaultBackend {
  MatrixSdkEmojiVaultBackend(this.client);

  final Client client;

  @override
  String? readStoredRoomId() =>
      client.accountData[_vaultAccountDataType]?.content['room_id'] as String?;

  @override
  Future<String> createEncryptedVaultRoom() async {
    final roomId = await client.createRoom(
      name: '畅聊表情仓库',
      preset: CreateRoomPreset.privateChat,
      visibility: Visibility.private,
      initialState: [
        StateEvent(
          type: EventTypes.Encryption,
          stateKey: '',
          content: const {'algorithm': 'm.megolm.v1.aes-sha2'},
        ),
      ],
    );
    await client.sync();
    final room = client.getRoomById(roomId);
    if (room == null || !room.encrypted) {
      throw StateError('Matrix did not create an encrypted emoji vault room');
    }
    return roomId;
  }

  @override
  Future<void> storeRoomId(String roomId) async {
    final userId = client.userID;
    if (userId == null) throw StateError('Matrix client is not logged in');
    await client.setAccountData(
      userId,
      _vaultAccountDataType,
      {'room_id': roomId},
    );
  }

  Future<Room> _room(String roomId) async {
    var room = client.getRoomById(roomId);
    if (room == null) {
      await client.sync();
      room = client.getRoomById(roomId);
    }
    if (room == null) throw StateError('Emoji vault room is not joined');
    return room;
  }

  @override
  Future<bool> isRoomEncrypted(String roomId) async =>
      (await _room(roomId)).encrypted;

  @override
  Future<Map<String, Object?>> uploadEncrypted(
    String roomId,
    Uint8List bytes,
    String mimeType,
  ) async {
    final room = await _room(roomId);
    if (!room.encrypted) {
      throw StateError('Emoji media upload requires an encrypted room');
    }
    final encrypted = await MatrixFile(
      bytes: bytes,
      name: '畅聊加密表情',
      mimeType: mimeType,
    ).encrypt();
    final uri = await client.uploadContent(
      encrypted.data,
      filename: 'emoji.ciphertext',
      contentType: 'application/octet-stream',
    );
    return {
      'url': uri.toString(),
      'mimetype': mimeType,
      'v': 'v2',
      'key': {
        'alg': 'A256CTR',
        'ext': true,
        'k': encrypted.k,
        'key_ops': ['encrypt', 'decrypt'],
        'kty': 'oct',
      },
      'iv': encrypted.iv,
      'hashes': {'sha256': encrypted.sha256},
    };
  }

  @override
  Future<void> sendEncryptedEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async {
    final room = await _room(roomId);
    if (!room.encrypted || !client.encryptionEnabled) {
      throw StateError('Emoji metadata requires Matrix E2EE');
    }
    final eventId = await room.sendEvent(
      Map<String, dynamic>.from(content),
      type: type,
    );
    if (eventId == null) throw StateError('Emoji vault event was not accepted');
  }

  @override
  Future<List<EmojiVaultEvent>> loadEvents(String roomId) async {
    final room = await _room(roomId);
    final timeline = await room.getTimeline();
    try {
      return timeline.events
          .map(_decodeEvent)
          .whereType<EmojiVaultEvent>()
          .toList(growable: false);
    } finally {
      timeline.cancelSubscriptions();
    }
  }

  EmojiVaultEvent? _decodeEvent(Event event) {
    if (!event.type.startsWith('com.changliao.emoji.')) return null;
    final content = Map<String, Object?>.from(event.content);
    final at = DateTime.tryParse(content['at']?.toString() ?? '')?.toUtc() ??
        event.originServerTs.toUtc();
    final stableId = content['event_id']?.toString() ?? event.eventId;
    switch (event.type) {
      case 'com.changliao.emoji.add':
        final rawItem = content['item'];
        if (rawItem is! Map) return null;
        return EmojiVaultEvent.add(
          eventId: stableId,
          at: at,
          item: EmojiVaultItem.fromJson(
            Map<String, Object?>.from(rawItem),
          ),
        );
      case 'com.changliao.emoji.remove':
        final itemId = content['item_id']?.toString();
        if (itemId == null) return null;
        return EmojiVaultEvent.remove(
          eventId: stableId,
          at: at,
          itemId: itemId,
        );
      case 'com.changliao.emoji.recents':
        final rawIds = content['item_ids'];
        if (rawIds is! List) return null;
        return EmojiVaultEvent.recent(
          eventId: stableId,
          at: at,
          itemIds: rawIds.map((value) => value.toString()).toList(),
        );
      default:
        return null;
    }
  }
}
