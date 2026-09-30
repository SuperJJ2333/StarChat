import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/features/matrix/content_addressed_media.dart';
import 'package:liuhetong_mobile/features/matrix/emoji_vault.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/media/image_compression_policy.dart';
import 'package:liuhetong_mobile/features/matrix/gif_image_policy.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../media/media_test_fixtures.dart';
import 'matrix_client_factory_test.dart' show SnapshotClient;

final class _VaultClient extends SnapshotClient {
  _VaultClient({Uint8List? download})
      : _http = MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer legacy-test-token');
          return http.Response.bytes(download ?? [], 200);
        });
  final http.Client _http;
  @override
  http.Client get httpClient => _http;
  @override
  Uri get homeserver => Uri.parse('https://test');
  @override
  String get accessToken => 'legacy-test-token';
  @override
  Future<bool> authenticatedMediaSupported() async => true;
  final uploads = <Uint8List>[];
  final contentTypes = <String?>[];
  @override
  bool get encryptionEnabled => true;
  @override
  bool get fileEncryptionEnabled => true;
  @override
  Future<Uri> uploadContent(Uint8List bytes,
      {String? filename, String? contentType}) async {
    uploads.add(bytes);
    contentTypes.add(contentType);
    return Uri.parse('mxc://test/${uploads.length}');
  }
}

final class _VaultRoom extends Room {
  _VaultRoom(Client client) : super(id: '!vault:test', client: client);
  void Function()? onEncryptedRead;
  @override
  bool get encrypted {
    onEncryptedRead?.call();
    return true;
  }

  @override
  Membership get membership => Membership.join;
  @override
  bool get canSendDefaultMessages => true;
}

final class _CollectionTransport implements EmojiVaultTransport {
  final uploads = <Uint8List>[];
  final mimes = <String>[];
  final sent = <EmojiVaultEvent>[];
  @override
  bool get isEncrypted => true;
  @override
  Future<Map<String, Object?>> uploadEncrypted(
      Uint8List bytes, String mimeType) async {
    mimes.add(mimeType);
    uploads.add(bytes);
    return {'url': 'mxc://test/collection'};
  }

  @override
  Future<void> sendEncrypted(EmojiVaultEvent event) async => sent.add(event);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'compressed final GIF drives collection digest, chat envelope and SDK upload',
      () async {
    final original = largeMediaTestGif();
    final finalBytes = await ImageCompressionPolicy.prepare(original);
    final transport = _CollectionTransport();
    final vault = EmojiVault(transport: transport);
    final first = await vault.add(original, mimeType: 'image/jpeg');
    final duplicate = await vault.add(finalBytes, mimeType: 'image/gif');
    expect(first.sha256, sha256.convert(finalBytes).toString());
    expect(duplicate.id, first.id);
    expect(transport.uploads.single, finalBytes);
    final oldEnvelope =
        await MatrixFile(bytes: original, name: 'old.gif').encrypt();
    final prepared = await prepareContentAddressedMedia(
        file: MatrixImageFile(
            bytes: original,
            name: 'disguised.jpg',
            mimeType: 'image/jpeg',
            width: 384,
            height: 384,
            preEncrypted: oldEnvelope));
    expect(prepared.file.bytes, finalBytes);
    expect(prepared.file.name, 'disguised.gif');
    expect(prepared.file.mimeType, 'image/gif');
    expect((prepared.file as MatrixImageFile).width,
        gifDimensions(finalBytes)!.$1);
    final envelope = await prepared.file.encrypt();
    expect(await decryptFileImplementation(envelope), finalBytes);
    expect(prepared.extraContent!['chatflow_media']['content_sha256'],
        first.sha256);
    final client = _VaultClient();
    final room = _VaultRoom(client);
    client.snapshotRooms.add(room);
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    final lease = await owner.openRoomLease(room.id);
    final backend = await lease.openEmojiVaultBackend();
    await backend.uploadEncrypted(room.id, finalBytes, first.mimeType);
    expect(client.uploads.single, envelope.data);
    expect(client.contentTypes, ['application/octet-stream']);
    await lease.cancel();
    await client.dispose();
  });

  test('static compression updates metadata and drops old random ciphertext',
      () async {
    // Dimensions alone require a new final image, even when PNG is small.
    final original = mediaTestPng(width: 1200, height: 800);
    final old = await MatrixFile(bytes: original, name: 'old.png').encrypt();
    final prepared = await prepareContentAddressedMedia(
        deterministic: false,
        file: MatrixImageFile(
            bytes: original,
            name: 'large.png',
            width: 1200,
            height: 800,
            preEncrypted: old));
    final dimensions =
        await ImageCompressionPolicy.dimensions(prepared.file.bytes);
    expect((prepared.file as MatrixImageFile).width, dimensions.$1);
    expect((prepared.file as MatrixImageFile).height, dimensions.$2);
    expect(await decryptFileImplementation(await prepared.file.encrypt()),
        prepared.file.bytes);
  });

  test('actual GIF file attachment is compressed while retaining its file type',
      () async {
    final original = largeMediaTestGif();
    final prepared = await prepareContentAddressedMedia(
        file: MatrixFile(
            bytes: original,
            name: 'attachment.gif',
            mimeType: 'application/octet-stream'));
    expect(prepared.file, isNot(isA<MatrixImageFile>()));
    expect(prepared.file.msgType, MessageTypes.File);
    expect(prepared.file.bytes.length, lessThanOrEqualTo(maxUnifiedImageBytes));
    expect(await decryptFileImplementation(await prepared.file.encrypt()),
        prepared.file.bytes);
    final retry = await prepareContentAddressedMedia(file: prepared.file);
    expect(retry.file.msgType, MessageTypes.File);
    expect(retry.file.bytes, same(prepared.file.bytes));
  });

  test('room replacement during preparation prevents SDK vault upload',
      () async {
    final client = _VaultClient();
    final room = _VaultRoom(client);
    client.snapshotRooms.add(room);
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    final lease = await owner.openRoomLease(room.id);
    final backend = await lease.openEmojiVaultBackend();
    room.onEncryptedRead = () {
      room.onEncryptedRead = null;
      scheduleMicrotask(() => client.snapshotRooms.clear());
    };
    await expectLater(
        backend.uploadEncrypted(room.id, mediaTestGif(), 'image/gif'),
        throwsStateError);
    expect(client.uploads, isEmpty);
    await lease.cancel();
    await client.dispose();
  });

  test('real SDK vault upload uses the same prepared ciphertext as chat',
      () async {
    final client = _VaultClient();
    final room = _VaultRoom(client);
    client.snapshotRooms.add(room);
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    final lease = await owner.openRoomLease(room.id);
    final backend = await lease.openEmojiVaultBackend();
    final bytes = mediaTestGif();
    final preparedChat = await prepareContentAddressedMedia(
        file: MatrixImageFile(
            bytes: bytes, name: 'animation.gif', mimeType: 'image/gif'));
    final chatEnvelope = await preparedChat.file.encrypt();
    final descriptor =
        await backend.uploadEncrypted(room.id, bytes, 'image/jpeg');
    expect(client.uploads.single, chatEnvelope.data);
    expect(client.contentTypes, ['application/octet-stream']);
    expect(descriptor['mimetype'], 'image/gif');
    expect((descriptor['key'] as Map)['k'], chatEnvelope.k);
    expect(descriptor['iv'], chatEnvelope.iv);
    expect((descriptor['hashes'] as Map)['sha256'], chatEnvelope.sha256);
    expect(descriptor.containsKey('content_sha256'), isFalse);
    await lease.cancel();
    await client.dispose();
  });

  test('collection corrects disguised GIF metadata and duplicates upload once',
      () async {
    final transport = _CollectionTransport();
    final vault = EmojiVault(transport: transport);
    final bytes = mediaTestGif();
    final first = await vault.add(bytes, mimeType: 'image/jpeg');
    final second = await vault.add(bytes, mimeType: 'image/gif');
    expect(first.mimeType, 'image/gif');
    expect(first.isAnimated, isTrue);
    expect(second.id, first.id);
    expect(transport.mimes, ['image/gif']);
    expect(transport.sent.length, 1);
  });

  test('legacy random SDK vault descriptor still decrypts original bytes',
      () async {
    final original = mediaTestGif();
    final legacy = await MatrixFile(bytes: original, name: 'old.gif').encrypt();
    final client = _VaultClient(download: legacy.data);
    final room = _VaultRoom(client);
    client.snapshotRooms.add(room);
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    final lease = await owner.openRoomLease(room.id);
    final backend = await lease.openEmojiVaultBackend();
    final descriptor = <String, Object?>{
      'url': 'mxc://test/old-random',
      'mimetype': 'image/gif',
      'v': 'v2',
      'key': {
        'alg': 'A256CTR',
        'ext': true,
        'k': legacy.k,
        'key_ops': ['encrypt', 'decrypt'],
        'kty': 'oct',
      },
      'iv': legacy.iv,
      'hashes': {'sha256': legacy.sha256},
    };
    expect(await backend.downloadAndDecrypt(room.id, descriptor), original);
    await lease.cancel();
    await client.dispose();
  });

  test('account changing during preparation prevents any SDK vault upload',
      () async {
    final client = _VaultClient();
    final room = _VaultRoom(client);
    client.snapshotRooms.add(room);
    final owner =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    final lease = await owner.openRoomLease(room.id);
    final backend = await lease.openEmojiVaultBackend();
    room.onEncryptedRead = () {
      room.onEncryptedRead = null;
      scheduleMicrotask(() => client.matrixUserId = '@revoked:test');
    };
    final operation =
        backend.uploadEncrypted(room.id, mediaTestGif(), 'image/gif');
    await expectLater(operation, throwsStateError);
    expect(client.uploads, isEmpty);
    await lease.cancel();
    await client.dispose();
  });

  test('collection rejects broken GIF before uploading', () async {
    final transport = _CollectionTransport();
    final vault = EmojiVault(transport: transport);
    final bytes = mediaTestGif();
    await expectLater(
        vault.add(Uint8List.sublistView(bytes, 0, bytes.length - 3),
            mimeType: 'image/jpeg'),
        throwsFormatException);
    expect(transport.mimes, isEmpty);
    expect(transport.sent, isEmpty);
  });
}
