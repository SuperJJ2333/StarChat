import 'dart:typed_data';

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
