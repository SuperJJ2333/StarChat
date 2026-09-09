import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:matrix/matrix.dart';
import '../../core/app_config.dart';

/// Cold loader only: a declared content hash cannot opt out of attachment E2EE.
/// Hash-authoritative cache hits bypass this loader entirely.
Future<Uint8List> downloadMediaContent(Event event,
    {bool thumbnail = false}) async {
  final hashes = TrustedMediaHashes.fromEvent(event);
  if (hashes != null &&
      !(thumbnail ? event.isThumbnailEncrypted : event.isAttachmentEncrypted)) {
    throw const FormatException('Missing encrypted media descriptor');
  }
  return (await event.downloadAndDecryptAttachment(getThumbnail: thumbnail))
      .bytes;
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

  static Future<MediaEnvelope> forBytes(Uint8List bytes) {
    final digest = crypto.sha256.convert(bytes);
    final hash = digest.toString();
    return _flights[hash] ??=
        _derive(bytes, digest.bytes, hash).whenComplete(() {
      _flights.remove(hash);
    });
  }

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
MatrixFile _preparedFile(MatrixFile file, EncryptedFile encrypted) {
  if (file is MatrixImageFile) {
    return MatrixImageFile(
        bytes: file.bytes,
        name: file.name,
        mimeType: file.mimeType,
        width: file.width,
        height: file.height,
        blurhash: file.blurhash,
        preEncrypted: encrypted);
  }
  if (file is MatrixVideoFile) {
    return MatrixVideoFile(
        bytes: file.bytes,
        name: file.name,
        mimeType: file.mimeType,
        width: file.width,
        height: file.height,
        duration: file.duration,
        preEncrypted: encrypted);
  }
  if (file is MatrixAudioFile) {
    return MatrixAudioFile(
        bytes: file.bytes,
        name: file.name,
        mimeType: file.mimeType,
        duration: file.duration,
        preEncrypted: encrypted);
  }
  return MatrixFile(
      bytes: file.bytes,
      name: file.name,
      mimeType: file.mimeType,
      preEncrypted: encrypted);
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
  final extra = Map<String, dynamic>.of(extraContent ?? {})
    ..remove('chatflow_media')
    ..remove('info');
  if (!deterministic) {
    return (
      file: file,
      thumbnail: thumbnail,
      extraContent: extra.isEmpty ? null : extra
    );
  }
  final envelope = await MediaEnvelope.forBytes(file.bytes);
  final thumbEnvelope =
      thumbnail == null ? null : await MediaEnvelope.forBytes(thumbnail.bytes);
  extra['chatflow_media'] = {
    'v': 1,
    'content_sha256': envelope.contentSha256,
    if (thumbEnvelope != null) 'thumbnail_sha256': thumbEnvelope.contentSha256,
  };
  return (
    file: _preparedFile(file, envelope.encrypted),
    thumbnail: thumbnail == null
        ? null
        : _preparedFile(thumbnail, thumbEnvelope!.encrypted) as MatrixImageFile,
    extraContent: extra
  );
}
