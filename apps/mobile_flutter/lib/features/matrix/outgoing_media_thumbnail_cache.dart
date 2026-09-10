import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:matrix/matrix.dart';
import 'gif_image_policy.dart';
import 'media_cache.dart';

/// Device-only account/content memo. Holds only bounded thumbnail bytes; the
/// original is retained by the canonical media cache, never this result map.
final class OutgoingMediaThumbnailCache {
  static const _maxEntries = 48;
  static const _maxBytes = 8 * 1024 * 1024;
  static final _entries = <String, MatrixImageFile?>{};
  static final _flights = <String, Future<MatrixImageFile?>>{};
  static int _generation = 0;
  static int _bytes = 0;

  static void _clear() {
    _generation++;
    _entries.clear();
    _flights.clear();
    _bytes = 0;
  }

  static Future<MatrixImageFile?> load({
    required String accountId,
    required MatrixImageFile image,
    required Future<MatrixImageFile?> Function() generate,
  }) {
    registerDecodedMediaCacheClearer(_clear);
    // GIF playback needs the original animation. Do not decode a static poster
    // for every send, consistent with buildChatImageThumbnail's GIF policy.
    if (isGifBytes(image.bytes)) return Future.value(null);
    final key = jsonEncode([accountId, sha256.convert(image.bytes).toString()]);
    if (_entries.containsKey(key)) {
      final result = _entries.remove(key);
      _entries[key] = result;
      return Future.value(result);
    }
    final pending = _flights[key];
    if (pending != null) return pending;
    final generation = _generation;
    final flight = (() async {
      final thumbnail = await generate();
      final result =
          thumbnail != null && thumbnail.size > image.size ? null : thumbnail;
      if (generation != _generation) return result;
      _entries[key] = result;
      _bytes += result?.size ?? 0;
      while (_entries.length > _maxEntries || _bytes > _maxBytes) {
        final removed = _entries.remove(_entries.keys.first);
        _bytes -= removed?.size ?? 0;
      }
      return result;
    })();
    _flights[key] = flight;
    return flight.whenComplete(() {
      if (identical(_flights[key], flight)) _flights.remove(key);
    });
  }
}
