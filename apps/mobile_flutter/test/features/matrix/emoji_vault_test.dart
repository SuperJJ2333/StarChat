import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/emoji_vault.dart';

final class FakeEmojiVaultTransport implements EmojiVaultTransport {
  FakeEmojiVaultTransport({this.isEncrypted = true});

  @override
  final bool isEncrypted;
  var uploads = 0;
  final sent = <EmojiVaultEvent>[];

  @override
  Future<Map<String, Object?>> uploadEncrypted(
    Uint8List bytes,
    String mimeType,
  ) async {
    uploads++;
    return {'url': 'mxc://vault/$uploads', 'key': 'cipher-key-$uploads'};
  }

  @override
  Future<void> sendEncrypted(EmojiVaultEvent event) async => sent.add(event);
}

void main() {
  test('vault deduplicates plaintext bytes by SHA-256 before encrypted upload',
      () async {
    final transport = FakeEmojiVaultTransport();
    final vault = EmojiVault(transport: transport);
    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    final first = await vault.add(bytes, mimeType: 'image/gif');
    final second = await vault.add(bytes, mimeType: 'image/gif');

    expect(second.id, first.id);
    expect(transport.uploads, 1);
    expect(transport.sent.single.type, EmojiVaultEventType.add);
  });

  test('vault refuses to upload through an unencrypted Matrix room', () async {
    final vault = EmojiVault(
      transport: FakeEmojiVaultTransport(isEncrypted: false),
    );

    expect(
      () => vault.add(Uint8List.fromList([1]), mimeType: 'image/png'),
      throwsStateError,
    );
  });

  test('newer tombstone wins when events arrive out of order', () {
    final transport = FakeEmojiVaultTransport();
    final vault = EmojiVault(transport: transport);
    final add = EmojiVaultEvent.add(
      eventId: 'add-1',
      at: DateTime.utc(2026, 8, 17, 10),
      item: EmojiVaultItem(
        id: 'emoji-1',
        sha256: 'abc',
        mimeType: 'image/png',
        encryptedFile: const {'url': 'mxc://vault/1'},
        createdAt: DateTime.utc(2026, 8, 17, 10),
        isAnimated: false,
      ),
    );
    final remove = EmojiVaultEvent.remove(
      eventId: 'remove-1',
      at: DateTime.utc(2026, 8, 17, 11),
      itemId: 'emoji-1',
    );

    vault.apply([remove, add]);

    expect(vault.items, isEmpty);
  });

  test('recent events merge stably across devices without replacing the list',
      () {
    final vault = EmojiVault(transport: FakeEmojiVaultTransport());
    vault.apply([
      EmojiVaultEvent.recent(
        eventId: 'device-a',
        at: DateTime.utc(2026, 8, 17, 10),
        itemIds: const ['a', 'b'],
      ),
      EmojiVaultEvent.recent(
        eventId: 'device-b',
        at: DateTime.utc(2026, 8, 17, 11),
        itemIds: const ['c', 'a'],
      ),
    ]);

    expect(vault.recentItemIds, ['c', 'a', 'b']);
  });

  test('remove and markRecent emit encrypted sync events', () async {
    final transport = FakeEmojiVaultTransport();
    final vault = EmojiVault(transport: transport);
    final item = await vault.add(
      Uint8List.fromList([1, 2, 3]),
      mimeType: 'image/png',
    );

    await vault.markRecent(item.id);
    await vault.remove(item.id);

    expect(
      transport.sent.map((event) => event.type),
      [
        EmojiVaultEventType.add,
        EmojiVaultEventType.recent,
        EmojiVaultEventType.remove,
      ],
    );
    expect(vault.items, isEmpty);
  });
}
