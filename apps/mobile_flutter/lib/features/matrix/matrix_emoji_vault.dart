import 'dart:typed_data';
import 'dart:async';

import 'emoji_vault.dart';
import 'emoji_preview_cache.dart';
import 'content_addressed_media.dart';

const emojiVaultAccountDataType = 'com.changliao.emoji.vault';

abstract interface class MatrixEmojiVaultMetadataBackend {
  Future<List<EmojiVaultEvent>?> readCachedEvents(String roomId);
}

/// The vault is an event log, not a latest-messages list: recent-use events can
/// push every add/remove event out of the first timeline window.
Future<List<T>> loadCompleteEmojiHistory<T>({
  required List<T> Function() events,
  required bool Function() canRequestHistory,
  required String Function() cursor,
  required Future<void> Function() requestHistory,
}) async {
  while (canRequestHistory()) {
    final before = '${cursor()}:${events().length}';
    await requestHistory();
    if (canRequestHistory() && before == '${cursor()}:${events().length}') {
      throw StateError('Emoji history pagination did not advance');
    }
  }
  return List.of(events());
}

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

abstract interface class MatrixEmojiVaultCacheIdentity {
  String get cacheIdentity;
}

abstract interface class MatrixEmojiVaultContentLoader {
  Future<Uint8List> loadContent(String roomId, EmojiVaultItem item);
}

final class MatrixEmojiVault {
  MatrixEmojiVault._({
    required this.roomId,
    required this.vault,
    required MatrixEmojiVaultBackend backend,
  }) : _backend = backend {
    if (backend is MatrixEmojiVaultCacheIdentity) {
      final disk = EncryptedEmojiPreviewStore(
          (backend as MatrixEmojiVaultCacheIdentity).cacheIdentity);
      _previews = EmojiPreviewCache(
          read: disk.read, write: disk.write, delete: disk.delete);
    } else {
      _previews = EmojiPreviewCache();
    }
  }

  final String roomId;
  final EmojiVault vault;
  final MatrixEmojiVaultBackend _backend;
  late final EmojiPreviewCache _previews;
  static final _sessions = Expando<Map<String, Future<MatrixEmojiVault>>>();

  String _previewKey(EmojiVaultItem item) =>
      '$roomId:${item.id}:${item.sha256}:160-v1';
  Future<Uint8List> loadPreview(EmojiVaultItem item) =>
      _previews.load(_previewKey(item), () => loadBytes(item));

  Future<void> removeItem(String id) async {
    final matches = vault.items.where((item) => item.id == id);
    final item = matches.isEmpty ? null : matches.first;
    await vault.remove(id);
    if (item != null) {
      try {
        await _previews.remove(_previewKey(item));
      } catch (_) {/* Accepted deletion must not be undone by cache I/O. */}
    }
  }

  /// Metadata refresh never blocks opening the cached panel.
  Future<void> refresh() async =>
      vault.apply(await _backend.loadEvents(roomId));

  Future<Uint8List> loadBytes(EmojiVaultItem item) async {
    final backend = _backend;
    if (backend is MatrixEmojiVaultContentLoader) {
      return (backend as MatrixEmojiVaultContentLoader).loadContent(roomId, item);
    }
    final bytes = await backend.downloadAndDecrypt(roomId, item.encryptedFile);
    verifyMediaContent(bytes, item.sha256);
    return bytes;
  }

  static Future<MatrixEmojiVault> open(
    MatrixEmojiVaultBackend backend,
  ) {
    if (backend is MatrixEmojiVaultCacheIdentity) {
      final sessions = _sessions[backend] ??= {};
      final account =
          '${(backend as MatrixEmojiVaultCacheIdentity).cacheIdentity}|${backend.readStoredRoomId()}';
      return sessions[account] ??=
          _open(backend).onError((Object error, StackTrace stack) {
        sessions.remove(account);
        Error.throwWithStackTrace(error, stack);
      });
    }
    return _open(backend);
  }

  static Future<MatrixEmojiVault> _open(MatrixEmojiVaultBackend backend) async {
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
    List<EmojiVaultEvent>? cached;
    if (backend is MatrixEmojiVaultMetadataBackend) {
      try {
        cached = await (backend as MatrixEmojiVaultMetadataBackend)
            .readCachedEvents(roomId);
      } catch (_) {/* Fall back to authoritative history. */}
    }
    vault.apply(cached ?? await backend.loadEvents(roomId));
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
