import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'startup_projection.dart';

final class PreparedStartupProjection {
  const PreparedStartupProjection(this.digest, this.length);
  final String digest;
  final int length;
}

/// Two envelopes maximum: committed + candidate. No plaintext ever reaches IO.
final class StartupProjectionStore {
  StartupProjectionStore(this.directory);
  final Directory directory;
  static final _writers = <String, Future<void>>{};
  Future<T> withWriter<T>(Future<T> Function() action) async {
    final key = directory.absolute.path;
    final previous = _writers[key] ?? Future<void>.value();
    final operation = previous.then((_) => action());
    final settled =
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _writers[key] = settled;
    try {
      return await operation;
    } finally {
      if (identical(_writers[key], settled)) _writers.remove(key);
    }
  }

  static final _cipher = AesGcm.with256bits();
  static final _fileName = RegExp(r'^[a-f0-9]{64}\.cfsp$');
  Future<SecretKey> _key(StartupProjectionAdmission admission) => Hkdf(
        hmac: Hmac.sha256(),
        outputLength: 32,
      ).deriveKey(
          secretKey: SecretKey(projectionKey(admission.databaseKey)),
          nonce: utf8.encode('ChatFlow/startup-projection/HKDF-SHA256/v1'),
          info: admission.context);

  static String randomEpoch() => base64Url
      .encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
  File get _marker => File('${directory.path}/installation');
  Future<String?> readInstallation() async {
    try {
      if (await _marker.length() != 43) return null;
      final handle = await _marker.open();
      try {
        return projectionEpoch(utf8.decode(await handle.read(44)));
      } finally {
        await handle.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// Only called after full installation reconciliation and verified session.
  Future<String> primeInstallation() async {
    final existing = await readInstallation();
    if (existing != null) return existing;
    await directory.create(recursive: true);
    final marker = randomEpoch();
    await _marker.writeAsString(marker, flush: true);
    return marker;
  }

  File _file(String hash) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid cache digest');
    }
    return File('${directory.path}/$hash.cfsp');
  }

  Future<StartupProjection?> read(StartupProjectionAdmission admission) async {
    try {
      if (admission.digest == null ||
          admission.length == null ||
          admission.length! < 38 ||
          admission.length! > startupProjectionMaxEnvelope) {
        return null;
      }
      final file = _file(admission.digest!);
      if (await file.length() != admission.length) return null;
      final handle = await file.open();
      late Uint8List bytes;
      try {
        bytes = await handle.read(admission.length! + 1);
      } finally {
        await handle.close();
      }
      if (bytes.length != admission.length ||
          digest.sha256.convert(bytes).toString() != admission.digest) {
        return null;
      }
      if (ascii.decode(bytes.sublist(0, 4)) != 'CFSP' ||
          bytes[4] != 1 ||
          bytes[5] != 0) {
        return null;
      }
      final size = ByteData.sublistView(bytes).getUint32(6);
      if (size + 38 != bytes.length) return null;
      final plain = await _cipher.decrypt(
          SecretBox(bytes.sublist(22, 22 + size),
              nonce: bytes.sublist(10, 22), mac: Mac(bytes.sublist(22 + size))),
          secretKey: await _key(admission),
          aad: [...bytes.sublist(0, 22), ...admission.context]);
      return StartupProjection.decode(plain);
    } catch (_) {
      return null;
    }
  }

  Future<PreparedStartupProjection> prepare(
      StartupProjectionAdmission admission,
      StartupProjection projection) async {
    final plain = projection.encode();
    // Validate every record on writes too, not only after decryption.
    StartupProjection.decode(plain);
    if (plain.length + 38 > startupProjectionMaxEnvelope) {
      throw StateError('Projection quota exceeded');
    }
    await directory.create(recursive: true);
    await clean(admission.digest);
    final nonce = _cipher.newNonce();
    final header = Uint8List(22)..setAll(0, ascii.encode('CFSP'));
    header[4] = 1;
    ByteData.sublistView(header).setUint32(6, plain.length);
    header.setAll(10, nonce);
    final box = await _cipher.encrypt(plain,
        secretKey: await _key(admission),
        nonce: nonce,
        aad: [...header, ...admission.context]);
    final encoded =
        Uint8List.fromList([...header, ...box.cipherText, ...box.mac.bytes]);
    final hash = digest.sha256.convert(encoded).toString();
    final temp = File('${directory.path}/candidate');
    await temp.writeAsBytes(encoded, flush: true);
    await temp.rename(_file(hash).path);
    return PreparedStartupProjection(hash, encoded.length);
  }

  Future<void> clean(String? keep) async {
    if (!await directory.exists()) return;
    await for (final entry in directory.list(followLinks: false)) {
      final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name == 'installation') continue;
      if (entry is! File ||
          (name != 'candidate' && !_fileName.hasMatch(name))) {
        throw StateError('Unexpected projection cache entry');
      }
      if (name != '$keep.cfsp') {
        await entry.delete();
      } else if (await entry.length() > startupProjectionMaxEnvelope) {
        throw StateError('Projection quota exceeded');
      }
    }
  }
}
