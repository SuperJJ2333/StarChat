import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';

import 'package:matrix/matrix.dart';

import 'emoji_vault.dart';
import 'emoji_preview_cache.dart';

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

final class MatrixEmojiVault {
  MatrixEmojiVault._({
    required this.roomId,
    required this.vault,
    required MatrixEmojiVaultBackend backend,
  }) : _backend = backend {
    if (backend is MatrixSdkEmojiVaultBackend) {
      final disk = EncryptedEmojiPreviewStore(
          '${backend.client.homeserver}|${backend.client.userID}');
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

  Future<Uint8List> loadBytes(EmojiVaultItem item) =>
      _backend.downloadAndDecrypt(roomId, item.encryptedFile);

  static Future<MatrixEmojiVault> open(
    MatrixEmojiVaultBackend backend,
  ) {
    if (backend is MatrixSdkEmojiVaultBackend) {
      final sessions = _sessions[backend.client] ??= {};
      final account =
          '${backend.client.homeserver}|${backend.client.userID}|${backend.readStoredRoomId()}';
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

final class MatrixSdkEmojiVaultBackend
    implements MatrixEmojiVaultBackend, MatrixEmojiVaultMetadataBackend {
  MatrixSdkEmojiVaultBackend(this.client);

  final Client client;
  late final _metadata = EncryptedEmojiPreviewStore(
      '${client.homeserver}|${client.userID}|vault-metadata-v1');
  final _knownEvents = <String, EmojiVaultEvent>{};
  Future<void> _metadataWrites = Future.value();

  @override
  Future<List<EmojiVaultEvent>?> readCachedEvents(String roomId) async {
    final bytes = await _metadata.read(roomId);
    if (bytes == null) return null;
    final raw = jsonDecode(utf8.decode(bytes)) as List;
    final events = raw
        .map((value) {
          final map = Map<String, Object?>.from(value as Map);
          return _decodeContent(
              map['type']! as String,
              Map<String, Object?>.from(map['content']! as Map),
              '',
              DateTime.utc(1970));
        })
        .whereType<EmojiVaultEvent>()
        .toList();
    for (final event in events) {
      _knownEvents[event.eventId] = event;
    }
    return events;
  }

  Future<void> _persistEvents(
      String roomId, Iterable<EmojiVaultEvent> events) async {
    for (final event in events) {
      _knownEvents[event.eventId] = event;
    }
    final write = _metadataWrites.then((_) async {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode([
        for (final event in _knownEvents.values)
          {'type': event.matrixType, 'content': event.toJson()},
      ])));
      await _metadata.write(roomId, bytes);
    });
    _metadataWrites =
        write.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    try {
      await write;
    } catch (_) {/* Sync remains usable if disk is unavailable. */}
  }

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
    final event =
        _decodeContent(type, content, eventId, DateTime.now().toUtc());
    if (event != null) await _persistEvents(roomId, [event]);
  }

  @override
  Future<List<EmojiVaultEvent>> loadEvents(String roomId) async {
    final room = await _room(roomId);
    final timeline = await room.getTimeline();
    try {
      final all = await loadCompleteEmojiHistory<Event>(
        events: () => timeline.events,
        canRequestHistory: () => timeline.canRequestHistory,
        cursor: () => room.prev_batch ?? '',
        requestHistory: () => timeline.requestHistory(historyCount: 100),
      );
      final events = all
          .map(_decodeEvent)
          .whereType<EmojiVaultEvent>()
          .toList(growable: false);
      await _persistEvents(roomId, events);
      return _knownEvents.values.toList(growable: false);
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
    final uri = Uri.parse(url);
    var ciphertext = await client.database?.getFile(uri);
    if (ciphertext == null) {
      final downloadUri = await uri.getDownloadUri(client);
      final response = await client.httpClient.get(
        downloadUri,
        headers: {'authorization': 'Bearer ${client.accessToken}'},
      );
      if (response.statusCode != 200) throw StateError('Emoji download failed');
      ciphertext = response.bodyBytes;
      // Cache ciphertext, never the decrypted original or its keys.
      final database = client.database;
      if (database != null && ciphertext.length <= database.maxFileSize) {
        await database.storeFile(
            uri, ciphertext, DateTime.now().millisecondsSinceEpoch);
      }
    }
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
    return _decodeContent(
        event.type, content, event.eventId, event.originServerTs.toUtc());
  }

  EmojiVaultEvent? _decodeContent(String type, Map<String, Object?> content,
      String eventId, DateTime fallbackAt) {
    final at = DateTime.tryParse(content['at']?.toString() ?? '')?.toUtc() ??
        fallbackAt;
    final stableId = content['event_id']?.toString() ?? eventId;
    switch (type) {
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
