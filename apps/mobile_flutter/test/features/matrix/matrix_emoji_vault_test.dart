import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/emoji_vault.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_emoji_vault.dart';

final class FakeMatrixEmojiVaultBackend implements MatrixEmojiVaultBackend {
  String? storedRoomId;
  bool encrypted = true;
  var creates = 0;
  var stores = 0;
  final events = <EmojiVaultEvent>[];
  final sentTypes = <String>[];

  @override
  String? readStoredRoomId() => storedRoomId;

  @override
  Future<String> createEncryptedVaultRoom() async {
    creates++;
    return '!emoji-vault:example.test';
  }

  @override
  Future<void> storeRoomId(String roomId) async {
    stores++;
    storedRoomId = roomId;
  }

  @override
  Future<bool> isRoomEncrypted(String roomId) async => encrypted;

  @override
  Future<List<EmojiVaultEvent>> loadEvents(String roomId) async => events;

  @override
  Future<Map<String, Object?>> uploadEncrypted(
    String roomId,
    Uint8List bytes,
    String mimeType,
  ) async =>
      {
        'url': 'mxc://example.test/encrypted',
        'key': const {'k': 'secret'}
      };

  @override
  Future<void> sendEncryptedEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async {
    sentTypes.add(type);
  }
}

void main() {
  test('open creates one encrypted self-room and persists only its room id',
      () async {
    final backend = FakeMatrixEmojiVaultBackend();

    final session = await MatrixEmojiVault.open(backend);

    expect(session.roomId, '!emoji-vault:example.test');
    expect(backend.creates, 1);
    expect(backend.stores, 1);
    expect(backend.storedRoomId, session.roomId);
  });

  test('open reuses stored room and merges decrypted events', () async {
    final backend = FakeMatrixEmojiVaultBackend()
      ..storedRoomId = '!existing:example.test'
      ..events.add(
        EmojiVaultEvent.add(
          eventId: r'$event',
          at: DateTime.utc(2026, 8, 17),
          item: EmojiVaultItem(
            id: 'emoji-1',
            sha256: 'abc',
            mimeType: 'image/png',
            encryptedFile: const {'url': 'mxc://example.test/cipher'},
            createdAt: DateTime.utc(2026, 8, 17),
            isAnimated: false,
          ),
        ),
      );

    final session = await MatrixEmojiVault.open(backend);

    expect(backend.creates, 0);
    expect(session.vault.items.single.id, 'emoji-1');
  });

  test('open fails closed when the stored room is not encrypted', () async {
    final backend = FakeMatrixEmojiVaultBackend()
      ..storedRoomId = '!plain:example.test'
      ..encrypted = false;

    expect(() => MatrixEmojiVault.open(backend), throwsStateError);
  });

  test('vault sends namespaced events through encrypted backend transport',
      () async {
    final backend = FakeMatrixEmojiVaultBackend();
    final session = await MatrixEmojiVault.open(backend);

    await session.vault.add(
      Uint8List.fromList([1, 2, 3]),
      mimeType: 'image/gif',
    );

    expect(backend.sentTypes, ['com.changliao.emoji.add']);
  });
}
