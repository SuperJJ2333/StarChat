import 'dart:typed_data';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show compute;

import '../matrix/gif_image_policy.dart';
import 'image_compression_policy.dart';

/// Validated original metadata. The bytes are not transformed or retained in a
/// global cache; protocol adapters remain responsible for access and storage.
final class MediaAsset {
  const MediaAsset(
      {required this.bytes,
      required this.mimeType,
      required this.filename,
      required this.isGif});
  final Uint8List bytes;
  final String mimeType;
  final String filename;
  final bool isGif;
}

abstract final class MediaAssetGateway {
  /// Keeps the authorized retained-file result without loading its full bytes.
  static Future<File> readFile(Future<File> Function() loader,
      {void Function()? ensureCurrent}) async {
    ensureCurrent?.call();
    final file = await loader();
    ensureCurrent?.call();
    try {
      if (await file.length() <= 0) {
        throw const FormatException('原文件不存在或为空，请重新加载');
      }
    } on FileSystemException {
      throw const FormatException('原文件不存在或为空，请重新加载');
    }
    ensureCurrent?.call();
    return file;
  }

  static Future<MediaAsset> inspect(Uint8List bytes,
      {required String mimeType, required String filename}) async {
    await _validateOriginal(bytes);
    final detected = _detectedMimeType(bytes);
    return MediaAsset(
        bytes: bytes,
        mimeType: detected ?? mimeType,
        filename: exportFilename(bytes, filename: filename),
        isGif: detected == 'image/gif');
  }

  /// Compress initial image intake; compliant GIF bytes are reused exactly.
  static Future<Uint8List> prepareImage(Uint8List bytes,
      {required Future<Uint8List> Function(Uint8List) transform}) async {
    return ImageCompressionPolicy.prepare(bytes, transform: transform);
  }

  /// The loader must enforce account/lease validity, decryption and cache
  /// budgets before returning. Only an explicitly trusted digest is authority.
  /// No retry, format limit for new sends, or permanent caching is added here.
  static Future<Uint8List> readOriginal(Future<Uint8List> Function() loader,
      {String? expectedSha256}) async {
    if (expectedSha256 != null && !_sha256Hex.hasMatch(expectedSha256)) {
      throw const FormatException('Invalid media content digest');
    }
    final bytes = await loader();
    if (expectedSha256 != null) {
      await compute(_verifyOriginal, (bytes, expectedSha256));
    }
    return bytes;
  }

  /// The caller supplies original bytes, never a preview. A known header wins
  /// over a misleading extension or MIME declaration; unknown formats retain
  /// their original extension for legacy file/audio/video compatibility.
  static String exportFilename(Uint8List bytes,
      {required String filename, String? mimeType}) {
    final name = filename.replaceAll('\\', '/').split('/').last;
    final extension = switch (_detectedMimeType(bytes)) {
      'image/gif' => 'gif',
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      _ => null,
    };
    if (extension == null) return name;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    return '${stem.isEmpty ? 'media' : stem}.$extension';
  }

  static Future<void> _validateOriginal(Uint8List bytes) async {
    if (bytes.length >= 3 &&
        bytes[0] == 71 &&
        bytes[1] == 73 &&
        bytes[2] == 70) {
      if (!isGifBytes(bytes)) throw const FormatException('GIF 文件已损坏，请重新选择');
      await compute(validateGifStructureForSend, bytes);
    }
  }

  static final _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

  static void _verifyOriginal((Uint8List, String) input) {
    if (crypto.sha256.convert(input.$1).toString() != input.$2) {
      throw const FormatException('Media content digest mismatch');
    }
  }

  static String? _detectedMimeType(Uint8List bytes) {
    if (isGifBytes(bytes)) return 'image/gif';
    if (bytes.length >= 8 &&
        bytes[0] == 137 &&
        bytes[1] == 80 &&
        bytes[2] == 78 &&
        bytes[3] == 71 &&
        bytes[4] == 13 &&
        bytes[5] == 10 &&
        bytes[6] == 26 &&
        bytes[7] == 10) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255) {
      return 'image/jpeg';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 82 &&
        bytes[1] == 73 &&
        bytes[2] == 70 &&
        bytes[3] == 70 &&
        bytes[8] == 87 &&
        bytes[9] == 69 &&
        bytes[10] == 66 &&
        bytes[11] == 80) {
      return 'image/webp';
    }
    return null;
  }
}
