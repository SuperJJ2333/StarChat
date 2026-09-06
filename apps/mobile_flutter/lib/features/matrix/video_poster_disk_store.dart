import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

/// Room-instance temporary storage. The AES-GCM key exists only in memory;
/// filenames contain hashes, and files contain nonce + MAC + ciphertext.
/// No quota eviction: the owner explicitly destroys the session on disposal.
final class VideoPosterDiskStore {
  VideoPosterDiskStore({Future<Directory> Function()? directory})
      : _createDirectory = directory ?? _temporaryDirectory;

  final Future<Directory> Function() _createDirectory;
  final _cipher = AesGcm.with256bits();
  late final _key = _cipher.newSecretKey();
  Future<Directory>? _directory;
  final Set<String> _keys = {};
  bool _closed = false;

  static Future<Directory> _temporaryDirectory() async {
    final root = await getTemporaryDirectory();
    return root.createTemp('chatflow-posters-');
  }

  Future<File> _file(String key) async {
    final directory = await (_directory ??= _createDirectory());
    return File('${directory.path}/${sha256.convert(utf8.encode(key))}.poster');
  }

  Future<Uint8List?> read(String key) async {
    if (_closed || !_keys.contains(key)) return null;
    final file = await _file(key);
    if (!await file.exists()) return null;
    try {
      final data = await file.readAsBytes();
      if (data.length < 28) return null;
      final plain = await _cipher.decrypt(
          SecretBox(data.sublist(28),
              nonce: data.sublist(0, 12), mac: Mac(data.sublist(12, 28))),
          secretKey: await _key,
          aad: utf8.encode(key));
      return _closed ? null : Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      await delete(key);
      return null;
    }
  }

  Future<void> write(String key, Uint8List bytes) async {
    if (_closed) return;
    final box = await _cipher.encrypt(bytes,
        secretKey: await _key, aad: utf8.encode(key));
    if (_closed) return;
    final file = await _file(key);
    if (_closed) return;
    await file.writeAsBytes([...box.nonce, ...box.mac.bytes, ...box.cipherText],
        flush: true);
    if (_closed) {
      if (await file.exists()) await file.delete();
      return;
    }
    _keys.add(key);
  }

  Future<void> delete(String key) async {
    _keys.remove(key);
    if (_directory == null) return;
    final file = await _file(key);
    if (await file.exists()) await file.delete();
  }

  Future<List<String>> keys() async => _keys.toList();

  Future<void> dispose() async {
    _closed = true;
    _keys.clear();
    final pending = _directory;
    if (pending == null) return;
    final directory = await pending;
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
