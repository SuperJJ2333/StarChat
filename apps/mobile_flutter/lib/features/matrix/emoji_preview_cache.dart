import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/session_store.dart';
import 'gif_image_policy.dart';

/// Only small, static first frames live here. Original media stays unchanged.
final class EmojiPreviewCache {
  EmojiPreviewCache(
      {this.read,
      this.write,
      this.delete,
      this.transform = createEmojiPreview,
      this.maxBytes = 8 * 1024 * 1024});
  final Future<Uint8List?> Function(String)? read;
  final Future<void> Function(String, Uint8List)? write;
  final Future<void> Function(String)? delete;
  final Future<Uint8List> Function(Uint8List) transform;
  final int maxBytes;
  final _memory = <String, Uint8List>{};
  final _flights = <String, Future<Uint8List>>{};
  final _versions = <String, int>{};
  Future<void> _queue = Future.value();
  int _bytes = 0;

  Future<Uint8List> load(String key, Future<Uint8List> Function() original) {
    final cached = _memory.remove(key);
    if (cached != null) {
      _memory[key] = cached;
      return Future.value(cached);
    }
    return _flights[key] ??= _enqueue(key, original);
  }

  Future<Uint8List> _enqueue(
      String key, Future<Uint8List> Function() original) {
    final version = _versions[key] ?? 0;
    final result = _queue.then((_) async {
      Uint8List? bytes;
      try {
        bytes = await read?.call(key);
      } catch (_) {/* cache miss */}
      if (bytes == null) {
        bytes = await transform(await original());
        if ((_versions[key] ?? 0) == version) {
          try {
            await write?.call(key, bytes);
          } catch (_) {/* memory only */}
        }
      }
      if ((_versions[key] ?? 0) != version) {
        await delete?.call(key);
        return bytes;
      }
      if (bytes.length <= maxBytes) {
        _memory[key] = bytes;
        _bytes += bytes.length;
        while (_bytes > maxBytes) {
          _bytes -= _memory.remove(_memory.keys.first)!.length;
        }
      }
      return bytes;
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result.whenComplete(() {
      _flights.remove(key);
    });
  }

  void clearMemory() {
    _memory.clear();
    _bytes = 0;
  }

  Future<void> remove(String key) async {
    _versions[key] = (_versions[key] ?? 0) + 1;
    _bytes -= _memory.remove(key)?.length ?? 0;
    await delete?.call(key);
  }
}

Future<Uint8List> createEmojiPreview(Uint8List bytes) async {
  // GIF codecs may allocate their logical canvas even when downscaling.
  validateGifForSend(bytes);
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      final scale = 160 /
          (descriptor.width > descriptor.height
              ? descriptor.width
              : descriptor.height);
      final codec = await descriptor.instantiateCodec(
        targetWidth: scale < 1
            ? (descriptor.width * scale).round().clamp(1, 160)
            : descriptor.width,
        targetHeight: scale < 1
            ? (descriptor.height * scale).round().clamp(1, 160)
            : descriptor.height,
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          final data =
              await frame.image.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) throw StateError('Emoji preview unavailable');
          return data.buffer
              .asUint8List(data.offsetInBytes, data.lengthInBytes);
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

/// Per-account AES-GCM previews; keys stay in platform secure storage. Disk is
/// reconstructible and bounded to 64 MiB. No plaintext attachment goes to disk.
final class EncryptedEmojiPreviewStore {
  EncryptedEmojiPreviewStore(String accountId,
      {SecureKeyValueStore? keys, Future<Directory> Function()? directory})
      : _account = sha256.convert(utf8.encode(accountId)).toString(),
        _keys = keys ?? FlutterSecureKeyValueStore(),
        _directory = directory ?? getApplicationSupportDirectory;
  final String _account;
  final SecureKeyValueStore _keys;
  final Future<Directory> Function() _directory;
  final _cipher = AesGcm.with256bits();
  Future<SecretKey>? _key;

  Future<SecretKey> _loadKey() => _key ??= () async {
        final name = 'emoji.preview.key.v1.$_account';
        final existing = await _keys.read(name);
        if (existing != null) return SecretKey(base64Decode(existing));
        final key = await _cipher.newSecretKey();
        await _keys.write(name, base64Encode(await key.extractBytes()));
        return key;
      }();
  Future<File> _file(String key) async {
    final root = await _directory();
    final dir = Directory('${root.path}/emoji-previews-v1/$_account');
    await dir.create(recursive: true);
    return File('${dir.path}/${sha256.convert(utf8.encode(key))}.bin');
  }

  Future<Uint8List?> read(String key) async {
    final file = await _file(key);
    if (!await file.exists()) return null;
    try {
      final data = await file.readAsBytes();
      final result = await _cipher.decrypt(
          SecretBox.fromConcatenation(data, nonceLength: 12, macLength: 16),
          secretKey: await _loadKey());
      await file.setLastModified(DateTime.now());
      return Uint8List.fromList(result);
    } catch (_) {
      await delete(key);
      return null;
    }
  }

  Future<void> write(String key, Uint8List bytes) async {
    final file = await _file(key);
    final box = await _cipher.encrypt(bytes, secretKey: await _loadKey());
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(box.concatenation(), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
    final files = await file.parent
        .list()
        .where((f) => f is File && f.path.endsWith('.bin'))
        .cast<File>()
        .toList();
    final stats = <File, FileStat>{};
    var total = 0;
    for (final entry in files) {
      final stat = await entry.stat();
      stats[entry] = stat;
      total += stat.size;
    }
    files.sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
    for (final entry in files) {
      if (total <= 64 * 1024 * 1024) break;
      if (entry.path == file.path) continue;
      total -= stats[entry]!.size;
      await entry.delete();
    }
  }

  Future<void> delete(String key) async {
    final file = await _file(key);
    if (await file.exists()) await file.delete();
  }
}
