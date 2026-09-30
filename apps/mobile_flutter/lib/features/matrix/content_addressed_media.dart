import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:flutter/foundation.dart' show compute;
import '../media/media_asset_gateway.dart';
import '../media/image_compression_policy.dart';
import 'gif_image_policy.dart' show gifDimensions;
import '../../core/app_config.dart';
import '../../core/native_media_download.dart';
import 'media_cache.dart' show MediaCacheKey, matrixMediaSourceIdentity;

/// Verify disk content without allocating an entire video as one byte array.
Future<void> verifyMediaContentStream(
    Stream<List<int>> chunks, String hash) async {
  validateContentSha256(hash);
  final digest = await crypto.sha256.bind(chunks).first;
  if (digest.toString() != hash) {
    throw const FormatException('Media content hash mismatch');
  }
}

/// Ciphertext flights use the complete encrypted descriptor. Equal plaintext
/// hashes may refer to independently encrypted uploads with different keys/IVs.
String matrixMediaTransferIdentity(Event event, {bool thumbnail = false}) =>
    MediaCacheKey(
            accountId: event.room.client.userID ?? '',
            roomId: event.room.id,
            eventId: thumbnail ? 'thumb:${event.eventId}' : event.eventId,
            sourceIdentity:
                matrixMediaSourceIdentity(event.content, thumbnail: thumbnail))
        .identity;

/// Cold loader only: a declared content hash cannot opt out of attachment E2EE.
/// Hash-authoritative cache hits bypass this loader entirely.
Future<Uint8List> downloadMediaContent(Event event,
    {bool thumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback}) async {
  final hashes = TrustedMediaHashes.fromEvent(event);
  if (hashes != null &&
      !(thumbnail ? event.isThumbnailEncrypted : event.isAttachmentEncrypted)) {
    throw const FormatException('Missing encrypted media descriptor');
  }
  // If AppHome already registered a native ciphertext transfer, a visible
  // bubble joins it instead of issuing a duplicate Dart HTTP request.
  if (downloadCallback == null) {
    final pending = NativeMediaDownloadSession.joinPending(
        event.room.client.userID ?? '',
        matrixMediaTransferIdentity(event, thumbnail: thumbnail));
    if (pending != null) downloadCallback = (_) => pending;
  }
  // The cache caller verifies authoritative plaintext hashes. This wrapper
  // keeps its existing SDK decryption/authorization loader without hashing a
  // second time or imposing new-send GIF limits on legacy attachments.
  return MediaAssetGateway.readOriginal(() async =>
      (await event.downloadAndDecryptAttachment(
              getThumbnail: thumbnail, downloadCallback: downloadCallback))
          .bytes);
}

/// Cold forwarding loader with an encrypted-download byte budget. The legacy
/// loader above intentionally remains unchanged for existing callers.
Future<Uint8List> downloadMediaContentBounded(
  Event event, {
  required int maxDownloadBytes,
  bool thumbnail = false,
}) async {
  final hashes = TrustedMediaHashes.fromEvent(event);
  if (hashes != null &&
      !(thumbnail ? event.isThumbnailEncrypted : event.isAttachmentEncrypted)) {
    throw const FormatException('Missing encrypted media descriptor');
  }
  return MediaAssetGateway.readOriginal(() async {
    final file = await event.downloadAndDecryptAttachment(
      getThumbnail: thumbnail,
      downloadCallback: (url) => _downloadBounded(
        event.room.client.httpClient,
        event.room.client.accessToken,
        url,
        maxDownloadBytes,
      ),
    );
    if (file.bytes.lengthInBytes > maxDownloadBytes) {
      throw const MediaContentLimitException();
    }
    return file.bytes;
  });
}

Future<Uint8List> _downloadBounded(
  http.Client client,
  String? accessToken,
  Uri url,
  int maxDownloadBytes,
) async {
  final request = http.Request('GET', url);
  request.headers['authorization'] = 'Bearer $accessToken';
  final response = await client.send(request);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    final subscription = response.stream.listen((_) {});
    await subscription.cancel();
    throw http.ClientException(
        'Media download failed: ${response.statusCode}', url);
  }
  final bytes = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in response.stream) {
    length += chunk.length;
    if (length > maxDownloadBytes) throw const MediaContentLimitException();
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

final class MediaContentLimitException implements Exception {
  const MediaContentLimitException();
}

final _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

void validateContentSha256(String hash) {
  if (!_sha256Hex.hasMatch(hash)) {
    throw const FormatException('Invalid media content digest');
  }
}

void verifyMediaContent(Uint8List bytes, String? hash) {
  if (hash == null) return;
  validateContentSha256(hash);
  if (crypto.sha256.convert(bytes).toString() != hash) {
    throw const FormatException('Media content digest mismatch');
  }
}

/// Only the SDK's successfully decrypted event supplies content authority.
final class TrustedMediaHashes {
  const TrustedMediaHashes(this.contentSha256, this.thumbnailSha256);
  final String contentSha256;
  final String? thumbnailSha256;

  static TrustedMediaHashes? fromEvent(Event event) => parse(event.content,
      decrypted: event.originalSource?.type == EventTypes.Encrypted &&
          event.type != EventTypes.Encrypted &&
          !event.redacted);

  static TrustedMediaHashes? parse(Map<String, dynamic> content,
      {required bool decrypted}) {
    if (!decrypted || !content.containsKey('chatflow_media')) return null;
    final value = content['chatflow_media'];
    if (value is! Map ||
        value['v'] is! int ||
        value['v'] != 1 ||
        value['content_sha256'] is! String ||
        (value.containsKey('thumbnail_sha256') &&
            value['thumbnail_sha256'] is! String)) {
      throw const FormatException('Invalid media extension');
    }
    final hash = value['content_sha256'] as String;
    final thumbnail = value['thumbnail_sha256'] as String?;
    validateContentSha256(hash);
    if (thumbnail != null) validateContentSha256(thumbnail);
    return TrustedMediaHashes(hash, thumbnail);
  }
}

/// ADR-0060 v1: raw SHA-256 IKM, fixed HKDF domains, nonce + zero counter.
final class MediaEnvelope {
  const MediaEnvelope._(this.contentSha256, this.encrypted);
  final String contentSha256;
  final EncryptedFile encrypted;
  static final _flights = <String, Future<MediaEnvelope>>{};

  static Future<MediaEnvelope> forBytes(Uint8List bytes) async {
    final digest = await compute(crypto.sha256.convert, bytes);
    final hash = digest.toString();
    return _flights[hash] ??=
        compute(_deriveInBackground, (bytes, digest.bytes, hash))
            .whenComplete(() {
      _flights.remove(hash);
    });
  }

  // The worker receives only byte data, never a room/client/session/cache.
  static Future<MediaEnvelope> _deriveInBackground(
          (Uint8List, List<int>, String) input) =>
      _derive(input.$1, input.$2, input.$3);

  static Future<MediaEnvelope> _derive(
      Uint8List bytes, List<int> digest, String hash) async {
    final prk = crypto.Hmac(crypto.sha256, utf8.encode('chatflow-media-v1'))
        .convert(digest)
        .bytes;
    final info = utf8.encode('aes-256-ctr-v1');
    final hmac = crypto.Hmac(crypto.sha256, prk);
    final first = hmac.convert([...info, 1]).bytes;
    final second = hmac.convert([...first, ...info, 2]).bytes;
    final okm = [...first, ...second].sublist(0, 48);
    final encrypted = await encryptFileWithKey(
        bytes,
        Uint8List.fromList(okm.sublist(0, 32)),
        Uint8List.fromList(
            [...okm.sublist(32, 40), ...List<int>.filled(8, 0)]));
    return MediaEnvelope._(hash, encrypted);
  }
}

/// Retains concrete SDK media types and metadata and reuses the prepared
/// envelope through retries. Original bytes have already been processed.
MatrixFile _preparedFile(MatrixFile file, EncryptedFile? encrypted,
    {MediaAsset? original, (int, int)? dimensions}) {
  final bytes = original?.bytes ?? file.bytes;
  final name = original?.filename ?? file.name;
  final mimeType = original?.mimeType ?? file.mimeType;
  if (encrypted == null && identical(bytes, file.bytes)) {
    encrypted = file.preEncrypted;
  }
  if (file is MatrixImageFile) {
    return MatrixImageFile(
        bytes: bytes,
        name: name,
        mimeType: mimeType,
        width: dimensions?.$1 ?? gifDimensions(bytes)?.$1 ?? file.width,
        height: dimensions?.$2 ?? gifDimensions(bytes)?.$2 ?? file.height,
        blurhash: identical(bytes, file.bytes) ? file.blurhash : null,
        preEncrypted: encrypted);
  }
  if (file is MatrixVideoFile) {
    return MatrixVideoFile(
        bytes: bytes,
        name: name,
        mimeType: mimeType,
        width: file.width,
        height: file.height,
        duration: file.duration,
        preEncrypted: encrypted);
  }
  if (file is MatrixAudioFile) {
    return MatrixAudioFile(
        bytes: bytes,
        name: name,
        mimeType: mimeType,
        duration: file.duration,
        preEncrypted: encrypted);
  }
  return _PreparedGenericFile(
      bytes: bytes,
      name: name,
      mimeType: mimeType,
      preEncrypted: encrypted,
      messageType: file.msgType);
}

/// SDK MatrixFile derives msgType from MIME. Truthful image metadata must not
/// promote an attachment explicitly sent as m.file into an m.image message.
final class _PreparedGenericFile extends MatrixFile {
  _PreparedGenericFile({
    required super.bytes,
    required super.name,
    required super.mimeType,
    super.preEncrypted,
    required String messageType,
  }) : _messageType = messageType;

  final String _messageType;
  @override
  String get msgType => _messageType;
}

Future<
    ({
      MatrixFile file,
      MatrixImageFile? thumbnail,
      Map<String, dynamic>? extraContent
    })> prepareContentAddressedMedia({
  required MatrixFile file,
  MatrixImageFile? thumbnail,
  Map<String, dynamic>? extraContent,
  bool deterministic = AppConfig.deterministicMediaEncryption,
}) async {
  final source = await MediaAssetGateway.inspect(file.bytes,
      mimeType: file.mimeType, filename: file.name);
  final isImage =
      file is MatrixImageFile || source.mimeType.startsWith('image/');
  final preparedBytes =
      isImage ? await ImageCompressionPolicy.prepare(file.bytes) : file.bytes;
  final original = identical(preparedBytes, file.bytes)
      ? source
      : await MediaAssetGateway.inspect(preparedBytes,
          mimeType: source.mimeType, filename: source.filename);
  final dimensions =
      file is MatrixImageFile && !identical(preparedBytes, file.bytes)
          ? await ImageCompressionPolicy.dimensions(preparedBytes)
          : null;
  final thumbOriginal = thumbnail == null
      ? null
      : await MediaAssetGateway.inspect(thumbnail.bytes,
          mimeType: thumbnail.mimeType, filename: thumbnail.name);
  final extra = Map<String, dynamic>.of(extraContent ?? {})
    ..remove('chatflow_media')
    ..remove('info');
  if (!deterministic) {
    return (
      file:
          _preparedFile(file, null, original: original, dimensions: dimensions),
      thumbnail: thumbnail == null
          ? null
          : _preparedFile(thumbnail, null, original: thumbOriginal)
              as MatrixImageFile,
      extraContent: extra.isEmpty ? null : extra
    );
  }
  final envelope = await MediaEnvelope.forBytes(original.bytes);
  final thumbEnvelope =
      thumbnail == null ? null : await MediaEnvelope.forBytes(thumbnail.bytes);
  extra['chatflow_media'] = {
    'v': 1,
    'content_sha256': envelope.contentSha256,
    if (thumbEnvelope != null) 'thumbnail_sha256': thumbEnvelope.contentSha256,
  };
  return (
    file: _preparedFile(file, envelope.encrypted,
        original: original, dimensions: dimensions),
    thumbnail: thumbnail == null
        ? null
        : _preparedFile(thumbnail, thumbEnvelope!.encrypted,
            original: thumbOriginal) as MatrixImageFile,
    extraContent: extra
  );
}
