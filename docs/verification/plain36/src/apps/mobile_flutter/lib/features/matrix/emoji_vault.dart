import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

enum EmojiVaultEventType { add, remove, recent }

final class EmojiVaultItem {
  const EmojiVaultItem({
    required this.id,
    required this.sha256,
    required this.mimeType,
    required this.encryptedFile,
    required this.createdAt,
    required this.isAnimated,
  });

  final String id;
  final String sha256;
  final String mimeType;
  final Map<String, Object?> encryptedFile;
  final DateTime createdAt;
  final bool isAnimated;

  factory EmojiVaultItem.fromJson(Map<String, Object?> json) => EmojiVaultItem(
        id: json['id']! as String,
        sha256: json['sha256']! as String,
        mimeType: json['mime_type']! as String,
        encryptedFile:
            Map<String, Object?>.from(json['encrypted_file']! as Map),
        createdAt: DateTime.parse(json['created_at']! as String).toUtc(),
        isAnimated: json['is_animated']! as bool,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'sha256': sha256,
        'mime_type': mimeType,
        'encrypted_file': encryptedFile,
        'created_at': createdAt.toUtc().toIso8601String(),
        'is_animated': isAnimated,
      };
}

final class EmojiVaultEvent {
  const EmojiVaultEvent._({
    required this.eventId,
    required this.type,
    required this.at,
    this.item,
    this.itemId,
    this.itemIds = const [],
  });

  factory EmojiVaultEvent.add({
    required String eventId,
    required DateTime at,
    required EmojiVaultItem item,
  }) =>
      EmojiVaultEvent._(
        eventId: eventId,
        type: EmojiVaultEventType.add,
        at: at,
        item: item,
      );

  factory EmojiVaultEvent.remove({
    required String eventId,
    required DateTime at,
    required String itemId,
  }) =>
      EmojiVaultEvent._(
        eventId: eventId,
        type: EmojiVaultEventType.remove,
        at: at,
        itemId: itemId,
      );

  factory EmojiVaultEvent.recent({
    required String eventId,
    required DateTime at,
    required List<String> itemIds,
  }) =>
      EmojiVaultEvent._(
        eventId: eventId,
        type: EmojiVaultEventType.recent,
        at: at,
        itemIds: List.unmodifiable(itemIds),
      );

  final String eventId;
  final EmojiVaultEventType type;
  final DateTime at;
  final EmojiVaultItem? item;
  final String? itemId;
  final List<String> itemIds;

  String get matrixType => switch (type) {
        EmojiVaultEventType.add => 'com.changliao.emoji.add',
        EmojiVaultEventType.remove => 'com.changliao.emoji.remove',
        EmojiVaultEventType.recent => 'com.changliao.emoji.recents',
      };

  Map<String, Object?> toJson() => {
        'event_id': eventId,
        'at': at.toUtc().toIso8601String(),
        if (item != null) 'item': item!.toJson(),
        if (itemId != null) 'item_id': itemId,
        if (itemIds.isNotEmpty) 'item_ids': itemIds,
      };
}

abstract interface class EmojiVaultTransport {
  bool get isEncrypted;

  Future<Map<String, Object?>> uploadEncrypted(
    Uint8List bytes,
    String mimeType,
  );

  Future<void> sendEncrypted(EmojiVaultEvent event);
}

final class EmojiVault {
  EmojiVault({required this.transport});

  final EmojiVaultTransport transport;
  final Map<String, EmojiVaultItem> _items = {};
  final Map<String, DateTime> _itemVersions = {};
  final Map<String, DateTime> _tombstones = {};
  final List<String> _recent = [];

  List<EmojiVaultItem> get items {
    final result = _items.values.toList(growable: false);
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  List<String> get recentItemIds => List.unmodifiable(_recent);

  Future<EmojiVaultItem> add(
    Uint8List bytes, {
    required String mimeType,
  }) async {
    if (!transport.isEncrypted) {
      throw StateError('Emoji vault room must be end-to-end encrypted');
    }
    final digest = sha256.convert(bytes).toString();
    for (final item in _items.values) {
      if (item.sha256 == digest) return item;
    }
    final now = DateTime.now().toUtc();
    final idSeed = utf8.encode('$digest:${now.microsecondsSinceEpoch}');
    final id = sha256.convert(idSeed).toString().substring(0, 32);
    final encryptedFile = await transport.uploadEncrypted(bytes, mimeType);
    final item = EmojiVaultItem(
      id: id,
      sha256: digest,
      mimeType: mimeType,
      encryptedFile: Map.unmodifiable(encryptedFile),
      createdAt: now,
      isAnimated: mimeType.toLowerCase() == 'image/gif',
    );
    final event = EmojiVaultEvent.add(
      eventId: 'local-$id',
      at: now,
      item: item,
    );
    await transport.sendEncrypted(event);
    apply([event]);
    return item;
  }

  Future<void> remove(String itemId) async {
    if (!transport.isEncrypted) {
      throw StateError('Emoji vault room must be end-to-end encrypted');
    }
    final now = DateTime.now().toUtc();
    final event = EmojiVaultEvent.remove(
      eventId: 'local-remove-$itemId-${now.microsecondsSinceEpoch}',
      at: now,
      itemId: itemId,
    );
    await transport.sendEncrypted(event);
    apply([event]);
  }

  Future<void> markRecent(String itemId) async {
    if (!transport.isEncrypted) {
      throw StateError('Emoji vault room must be end-to-end encrypted');
    }
    final now = DateTime.now().toUtc();
    final ids = [itemId, ..._recent.where((id) => id != itemId)].take(40);
    final event = EmojiVaultEvent.recent(
      eventId: 'local-recents-${now.microsecondsSinceEpoch}',
      at: now,
      itemIds: ids.toList(growable: false),
    );
    await transport.sendEncrypted(event);
    apply([event]);
  }

  void apply(Iterable<EmojiVaultEvent> incoming) {
    final events = incoming.toList(growable: false)
      ..sort((a, b) {
        final time = a.at.compareTo(b.at);
        return time == 0 ? a.eventId.compareTo(b.eventId) : time;
      });
    for (final event in events) {
      switch (event.type) {
        case EmojiVaultEventType.add:
          final item = event.item!;
          final tombstone = _tombstones[item.id];
          final version = _itemVersions[item.id];
          if (tombstone != null && !event.at.isAfter(tombstone)) continue;
          if (version == null || !event.at.isBefore(version)) {
            _items[item.id] = item;
            _itemVersions[item.id] = event.at;
          }
        case EmojiVaultEventType.remove:
          final id = event.itemId!;
          final tombstone = _tombstones[id];
          if (tombstone == null || event.at.isAfter(tombstone)) {
            _tombstones[id] = event.at;
          }
          final version = _itemVersions[id];
          if (version == null || !version.isAfter(event.at)) {
            _items.remove(id);
            _itemVersions.remove(id);
          }
        case EmojiVaultEventType.recent:
          for (final id in event.itemIds.reversed) {
            _recent.remove(id);
            _recent.insert(0, id);
          }
      }
    }
  }
}
