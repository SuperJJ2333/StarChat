import 'dart:typed_data';

import 'package:matrix/matrix.dart';

import 'emoji_vault.dart';

const emojiVaultAccountDataType = 'com.changliao.emoji.vault';

abstract interface class MatrixEmojiVaultBackend {
  String? readStoredRoomId();
  Future<String> createEncryptedVaultRoom();
  Future<void> storeRoomId(String roomId);
  Future<bool> isRoomEncrypted(String roomId);
  Future<List<EmojiVaultEvent>> loadEvents(String roomId);
  Future<Uint8List> downloadAndDecrypt(
    String roomId,
    Map<String, Object?> encryptedFile,
  );
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
  const MatrixEmojiVault._({
    required this.roomId,
    required this.vault,
    required MatrixEmojiVaultBackend backend,
  }) : _backend = backend;

  final String roomId;
  final EmojiVault vault;
  final MatrixEmojiVaultBackend _backend;

  Future<Uint8List> loadBytes(EmojiVaultItem item) =>
      _backend.downloadAndDecrypt(roomId, item.encryptedFile);

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
    return MatrixEmojiVault._(roomId: roomId, vault: vault, backend: backend);
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
      client.accountData[emojiVaultAccountDataType]?.content['room_id']
          as String?;

  @override
  Future<String> createEncryptedVaultRoom() async {
    final roomId = await client.createGroupChat(
      groupName: '畅聊表情仓库',
      enableEncryption: true,
      invite: const [],
      preset: CreateRoomPreset.privateChat,
      visibility: Visibility.private,
      waitForSync: true,
    );
    var room = client.getRoomById(roomId);
    if (room == null) {
      throw StateError('Matrix did not create the emoji vault room');
    }
    if (!room.encrypted) {
      await room.enableEncryption();
      await client.oneShotSync();
      room = client.getRoomById(roomId);
    }
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
      emojiVaultAccountDataType,
      {'room_id': roomId},
    );
    await client.oneShotSync();
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

  @override
  Future<Uint8List> downloadAndDecrypt(
    String roomId,
    Map<String, Object?> encryptedFile,
  ) async {
    final room = await _room(roomId);
    if (!room.encrypted || !client.encryptionEnabled) {
      throw StateError('Emoji media download requires Matrix E2EE');
    }
    final url = encryptedFile['url']?.toString();
    final key = encryptedFile['key'];
    final hashes = encryptedFile['hashes'];
    if (url == null || key is! Map || hashes is! Map) {
      throw StateError('Encrypted emoji descriptor is invalid');
    }
    final downloadUri = await Uri.parse(url).getDownloadUri(client);
    final ciphertext = (await client.httpClient.get(
      downloadUri,
      headers: {'authorization': 'Bearer ${client.accessToken}'},
    ))
        .bodyBytes;
    final plaintext = await client.nativeImplementations.decryptFile(
      EncryptedFile(
        data: ciphertext,
        k: key['k']!.toString(),
        iv: encryptedFile['iv']!.toString(),
        sha256: hashes['sha256']!.toString(),
      ),
    );
    if (plaintext == null) throw StateError('Encrypted emoji integrity failed');
    return plaintext;
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
