import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/encryption/key_manager.dart';
import 'package:matrix/encryption/utils/stored_inbound_group_session.dart';
import 'package:matrix/matrix.dart';
import 'package:olm/olm.dart' as olm;

import '../../core/session_store.dart';

enum VaultSyncPhase {
  downloading,
  ready,
  partial,
  retrying,
  unavailable,
  revoked
}

final class VaultSyncStatus extends ChangeNotifier {
  VaultSyncPhase phase = VaultSyncPhase.downloading;
  int downloaded = 0, protected = 0, decrypted = 0, missing = 0;
  void changed() => notifyListeners();
  void setPhase(VaultSyncPhase value) {
    phase = value;
    notifyListeners();
  }
}

final class VaultFailure implements Exception {
  const VaultFailure(this.code, {this.conflicts = const []});
  final String code;
  final List<Map<String, dynamic>> conflicts;
  @override
  String toString() => 'Recovery service: $code';
}

/// Uses only the frozen Matrix-domain vault routes. No recovery material is
/// passed to a Business API. All asynchronous work keeps this captured owner.
final class MatrixRecoveryVault {
  MatrixRecoveryVault(
      {required this.client,
      required this.owner,
      required this.store,
      required this.status,
      this.refreshBusinessSession})
      : user = client.userID!,
        device = client.deviceID!,
        _family = store.businessIdentity,
        _businessGeneration = store.businessAuthorizationGeneration,
        homeserver = client.homeserver!,
        secrets =
            store.vaultStorage(client.homeserver.toString(), client.userID!);

  static const algorithm = 'm.megolm_backup.v1.curve25519-aes-sha2';
  static const base = '/_matrix/client/unstable/com.starchat.recovery/v1';
  final Client client;
  final RecoveryOperationOwner owner;
  final SecureSessionStore store;
  final VaultSyncStatus status;
  final Future<void> Function()? refreshBusinessSession;
  final VaultSecureStorage secrets;
  final String user, device;
  final Uri homeserver;
  final String? _family;
  final int _businessGeneration;
  Future<void> _queryTail = Future<void>.value();
  Future<http.Response>? _writeTransfer;
  Map<String, dynamic>? _descriptor;
  String? _privateKey;
  Future<void>? _initializing;

  static String operationId() {
    final random = Random.secure();
    final b = List<int>.generate(16, (_) => random.nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  void check() {
    owner.check();
    if (_family == null ||
        store.businessIdentity != _family ||
        store.businessAuthorizationGeneration != _businessGeneration ||
        client.userID != user ||
        client.deviceID != device ||
        client.homeserver != homeserver) {
      throw const VaultFailure('owner_changed');
    }
  }

  Future<String> _businessToken() async {
    check();
    // session() may migrate a legacy record; count that actual storage write.
    final session = await owner.write(store.session);
    check();
    if (session == null || session.matrixUserId != user) {
      throw const VaultFailure('revoked');
    }
    try {
      final claims = jsonDecode(utf8.decode(base64Url.decode(
          base64Url.normalize(session.accessToken.split('.')[1])))) as Map;
      final family = claims['family_id'];
      if (family is! String || family.isEmpty) throw const FormatException();
      final identity = '${claims['sub']}:$family:${claims['device_id']}';
      if (_family != identity) throw const VaultFailure('revoked');
    } on VaultFailure {
      rethrow;
    } catch (_) {
      throw const VaultFailure('invalid_identity');
    }
    return session.accessToken;
  }

  Future<Map<String, dynamic>> _request(String method, String path,
      {Map<String, dynamic>? body,
      String? operation,
      bool refreshed = false}) async {
    final priorWrite = _writeTransfer;
    if (method == 'PUT' && priorWrite != null) {
      await owner.read(() => priorWrite).timeout(const Duration(seconds: 8));
    }
    final business = await _businessToken();
    check();
    final request = http.Request(method, homeserver.resolve('$base$path'))
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer ${client.accessToken}',
        'X-StarChat-Session': 'Bearer $business',
        'Content-Type': 'application/json',
        if (operation != null) 'Idempotency-Key': operation,
        if (path.startsWith('/enrollments/')) 'If-None-Match': '*'
      });
    if (body != null) request.body = jsonEncode(body);
    if (request.bodyBytes.length > 1024 * 1024) {
      throw const VaultFailure('oversize');
    }
    // A response deadline cancels no writes: late readonly responses are fenced.
    Future<http.Response> transfer() async {
      final streamed = await client.httpClient.send(request);
      final bytes = <int>[];
      final maximum = path == '/material' ? 4096 : 1024 * 1024;
      await for (final chunk in streamed.stream) {
        if (bytes.length + chunk.length > maximum) {
          throw const VaultFailure('oversize');
        }
        bytes.addAll(chunk);
      }
      return http.Response.bytes(bytes, streamed.statusCode);
    }

    final transferFuture =
        method == 'PUT' ? owner.write(transfer) : owner.read(transfer);
    if (method == 'PUT') {
      _writeTransfer = transferFuture;
      unawaited(transferFuture.then<void>((_) {
        if (identical(_writeTransfer, transferFuture)) _writeTransfer = null;
      }, onError: (Object _, StackTrace __) {
        if (identical(_writeTransfer, transferFuture)) _writeTransfer = null;
      }));
    }
    final response = await transferFuture.timeout(const Duration(seconds: 8));
    check();
    Map<String, dynamic> value;
    try {
      value = Map<String, dynamic>.from(jsonDecode(response.body));
    } catch (_) {
      if (response.statusCode == 503) {
        throw const VaultFailure('M_VAULT_UNAVAILABLE');
      }
      if (response.statusCode == 404 || response.statusCode == 405) {
        throw const VaultFailure('M_UNRECOGNIZED');
      }
      throw const VaultFailure('invalid_response');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401 &&
          !refreshed &&
          refreshBusinessSession != null) {
        check();
        await owner.write(refreshBusinessSession!);
        check();
        return _request(method, path,
            body: body, operation: operation, refreshed: true);
      }
      // Deliberately omit server error text and request material from errors.
      throw VaultFailure(
          value['errcode'] is String ? value['errcode'] : 'unavailable',
          conflicts: value['conflicts'] is List
              ? (value['conflicts'] as List)
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList()
              : const []);
    }
    return value;
  }

  static Uint8List _decodeKey(String key) {
    final bytes = base64.decode(base64.normalize(key));
    if (bytes.length != 32 || base64.encode(bytes).replaceAll('=', '') != key) {
      throw const VaultFailure('invalid_key');
    }
    return bytes;
  }

  void _validateDescriptor(Map<String, dynamic> value) {
    if (value['algorithm'] != algorithm ||
        value['revision'] is! int ||
        value['revision'] < 0 ||
        value['version'] is! String ||
        !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
            .hasMatch(value['version']) ||
        value['public_key'] is! String ||
        sha256.convert(_decodeKey(value['public_key'])).toString() !=
            value['public_fingerprint']) {
      throw const VaultFailure('invalid_binding');
    }
  }

  Future<void> initialize() {
    check();
    final current = _initializing;
    if (current != null) return current;
    final future = _initialize();
    _initializing = future;
    return future.whenComplete(() {
      if (identical(_initializing, future)) _initializing = null;
    });
  }

  Future<void> _initialize() async {
    check();
    final response = await _request('GET', '/status');
    Map<String, dynamic> descriptor;
    if (response['state'] == 'absent' && response['collection'] == null) {
      var operation = await owner.read(() => secrets.read('enrollment'));
      if (operation == null) {
        operation = operationId();
        await owner.write(() => secrets.write('enrollment', operation!));
      }
      check();
      try {
        descriptor = await _request('PUT', '/enrollments/$operation',
            operation: operation, body: {'algorithm': algorithm});
      } on VaultFailure catch (failure) {
        if (failure.code != 'M_VAULT_EXISTS') rethrow;
        final winner = await _request('GET', '/status');
        if (winner['state'] != 'available') rethrow;
        descriptor = Map<String, dynamic>.from(winner['collection']);
      }
    } else if (response['state'] == 'available' &&
        response['collection'] is Map) {
      descriptor = Map<String, dynamic>.from(response['collection']);
    } else {
      throw const VaultFailure('invalid_status');
    }
    _validateDescriptor(descriptor);
    final material = await _request('POST', '/material',
        body: {'version': descriptor['version']});
    _validateDescriptor(material);
    if (material['owner'] != user ||
        material['server'] != user.substring(user.indexOf(':') + 1) ||
        ['version', 'algorithm', 'public_key', 'public_fingerprint']
            .any((k) => material[k] != descriptor[k])) {
      throw const VaultFailure('invalid_binding');
    }
    final decoder = olm.PkDecryption();
    try {
      if (decoder.init_with_private_key(_decodeKey(material['private_key'])) !=
          descriptor['public_key']) {
        throw const VaultFailure('invalid_binding');
      }
    } finally {
      decoder.free();
    }
    check();
    await owner.write(() => secrets.write('material', jsonEncode(material)));
    check();
    _descriptor = descriptor;
    _privateKey = material['private_key'];
  }

  Future<void> archiveAvailable(
      {Future<List<StoredInboundGroupSession>> Function(String?)?
          readSessions}) async {
    if (_descriptor == null) await initialize();
    final descriptor = _descriptor!;
    final database = client.database!;
    final pending = await owner.read(() => secrets.read('pending'));
    if (pending != null) {
      await _uploadPending(Map<String, dynamic>.from(jsonDecode(pending)));
    }
    String? cursor;
    do {
      check();
      final sessions = await owner.read(() => readSessions != null
          ? readSessions(cursor)
          : database.getInboundGroupSessionsPage(
              afterSessionId: cursor, limit: 80));
      if (sessions.isEmpty) break;
      cursor = sessions.last.sessionId;
      final exports = <DbInboundGroupSessionBundle>[];
      final revisions = <String, int>{}, sources = <String, String>{};
      for (final session in sessions) {
        final pair = '${session.roomId}|${session.sessionId}';
        final source = sha256
            .convert(utf8.encode(jsonEncode([
              session.pickle,
              session.content,
              session.senderClaimedKeys,
              session.senderKey
            ])))
            .toString();
        final receipt = await owner.read(() => database.getRecoveryCheckpoint(
            'receipt.${sha256.convert(utf8.encode(pair))}'));
        if (receipt?['version'] == descriptor['version'] &&
            receipt?['source'] == source) {
          continue;
        }
        sources[pair] = source;
        revisions[pair] = receipt?['version'] == descriptor['version']
            ? receipt!['revision'] as int
            : 0;
        exports.add(DbInboundGroupSessionBundle(
            dbSession: session,
            verified: client
                    .getUserDeviceKeysByCurve25519Key(session.senderKey)
                    ?.verified ??
                false));
      }
      if (exports.isNotEmpty) {
        final encrypted = await owner.read(() async => client
            .nativeImplementations
            .generateUploadKeys(GenerateUploadKeysArgs(
                pubkey: descriptor['public_key'],
                dbSessions: exports,
                userId: user)));
        final candidates = <Map<String, dynamic>>[];
        for (final room in encrypted.rooms.entries) {
          for (final session in room.value.sessions.entries) {
            candidates.add({
              'room_id': room.key,
              'session_id': session.key,
              'expected_revision': revisions['${room.key}|${session.key}'],
              ...session.value.toJson()
            });
          }
        }
        if (candidates.isNotEmpty) {
          final journal = {
            'operation': operationId(),
            'version': descriptor['version'],
            'sources': sources,
            'body': {
              'algorithm': algorithm,
              'public_key': descriptor['public_key'],
              'sessions': candidates
            }
          };
          await owner
              .write(() => secrets.write('pending', jsonEncode(journal)));
          check();
          await _uploadPending(journal);
        }
      }
      await Future<void>.delayed(Duration.zero);
    } while (owner.active);
    check();
    status.protected = await owner
        .read(() => database.recoveryProtectedCount(descriptor['version']));
    check();
    status.changed();
  }

  Future<void> _uploadPending(Map<String, dynamic> journal) async {
    if (journal['version'] != _descriptor!['version']) {
      throw const VaultFailure('invalid_binding');
    }
    final body = Map<String, dynamic>.from(journal['body']);
    Map<String, dynamic> receipt;
    try {
      receipt = await _request(
          'PUT', '/sessions/${journal['version']}/${journal['operation']}',
          operation: journal['operation'], body: body);
    } on VaultFailure catch (failure) {
      if (failure.code != 'M_REVISION_CONFLICT' || failure.conflicts.isEmpty) {
        rethrow;
      }
      // The rejected operation made no writes. Reconcile only expected CAS,
      // retaining the exact ciphertext, then protect a NEW operation before retry.
      for (final conflict in failure.conflicts) {
        final matches = (body['sessions'] as List).where((e) =>
            e['room_id'] == conflict['room_id'] &&
            e['session_id'] == conflict['session_id']);
        if (matches.length != 1 || conflict['revision'] is! int) {
          throw const VaultFailure('invalid_conflict');
        }
        matches.single['expected_revision'] = conflict['revision'];
      }
      final reconciled = {...journal, 'body': body, 'operation': operationId()};
      await owner.write(() => secrets.write('pending', jsonEncode(reconciled)));
      check();
      // Return to bounded scheduler backoff; never spin on a concurrent writer.
      throw const VaultFailure('retry_conflict');
    }
    if (receipt['version'] != journal['version'] ||
        receipt['receipts'] is! List) {
      throw const VaultFailure('invalid_receipt');
    }
    final candidates = body['sessions'] as List;
    if ((receipt['receipts'] as List).length != candidates.length) {
      throw const VaultFailure('invalid_receipt');
    }
    final seen = <String>{};
    for (final raw in receipt['receipts'] as List) {
      final pair = '${raw['room_id']}|${raw['session_id']}';
      final source = (journal['sources'] as Map)[pair];
      final matches = candidates.where((c) =>
          c['room_id'] == raw['room_id'] &&
          c['session_id'] == raw['session_id']);
      if (!seen.add(pair) ||
          source == null ||
          matches.length != 1 ||
          raw['revision'] is! int ||
          raw['candidate_revision'] is! int ||
          raw['candidate_revision'] > raw['revision'] ||
          raw['digest'] !=
              candidateDigest(user, journal['version'],
                  Map<String, dynamic>.from(matches.single))) {
        throw const VaultFailure('invalid_receipt');
      }
      await owner.write(() => client.database!.storeRecoveryRecord(
              'receipt.${sha256.convert(utf8.encode(pair))}', {
            'version': journal['version'],
            'source': source,
            'revision': raw['revision'],
            'candidate_revision': raw['candidate_revision'],
            'digest': raw['digest']
          }));
      check();
    }
    await owner.write(() => secrets.delete('pending'));
    check();
    status.protected = await owner.read(
        () => client.database!.recoveryProtectedCount(journal['version']));
    check();
    status.changed();
  }

  static String candidateDigest(
      String user, String version, Map<String, dynamic> candidate) {
    final content = Map<String, dynamic>.from(candidate)
      ..remove('expected_revision')
      ..remove('revision')
      ..remove('candidate_revision')
      ..remove('digest');
    Object? ordered(Object? value) {
      if (value is Map) {
        final keys = value.keys.cast<String>().toList()..sort();
        return {for (final key in keys) key: ordered(value[key])};
      }
      if (value is List) return value.map(ordered).toList();
      return value;
    }

    return sha256
        .convert(utf8.encode(jsonEncode(ordered([
          user,
          version,
          content['room_id'],
          content['session_id'],
          content
        ]))))
        .toString();
  }

  /// Values are sender keys taken from actual target ciphertext, not backup hints.
  Future<int> restoreMissing(Map<(String, String), String> missing) {
    // Serialize the entire continuation walk. Copy only the bounded pair set;
    // callers retain no response page while another query is in flight.
    final captured = Map<(String, String), String>.from(missing);
    final result = _queryTail.then((_) {
      check();
      return _restoreMissing(captured);
    });
    _queryTail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<int> _restoreMissing(Map<(String, String), String> missing) async {
    if (missing.isEmpty) return 0;
    if (missing.length > 64) {
      throw ArgumentError('Missing-key query is bounded');
    }
    if (_descriptor == null) await initialize();
    final pairs = [
      for (final p in missing.keys) {'room_id': p.$1, 'session_id': p.$2}
    ];
    String? continuation;
    final imported = <(String, String)>{};
    final continuations = <String>{};
    final decoder = olm.PkDecryption();
    try {
      decoder.init_with_private_key(_decodeKey(_privateKey!));
      do {
        final result = await _request('POST', '/sessions/query', body: {
          'version': _descriptor!['version'],
          'pairs': pairs,
          if (continuation != null) 'continuation': continuation,
        });
        if (result['version'] != _descriptor!['version'] ||
            (result['candidates'] as List).length > 16) {
          throw const VaultFailure('invalid_response');
        }
        for (final candidate in result['candidates'] as List) {
          check();
          final pair = (
            candidate['room_id'] as String,
            candidate['session_id'] as String
          );
          final sender = missing[pair];
          if (sender == null) throw const VaultFailure('invalid_binding');
          try {
            if (candidate['digest'] !=
                candidateDigest(user, _descriptor!['version'],
                    Map<String, dynamic>.from(candidate))) {
              continue;
            }
            final data = candidate['session_data'] as Map;
            final payload = Map<String, dynamic>.from(jsonDecode(decoder
                .decrypt(data['ephemeral'], data['mac'], data['ciphertext'])));
            check();
            if (await client.encryption!.keyManager
                .importRecoverySession(pair.$1, pair.$2, sender, payload)) {
              imported.add(pair);
            }
            check();
          } on StateError {
            rethrow;
          } catch (_) {
            /* Try the next retained candidate; preserve valid local keys. */
          }
        }
        continuation = result['continuation'] as String?;
        if (continuation != null &&
            (!continuations.add(continuation) || continuations.length > 128)) {
          throw const VaultFailure('query_stalled');
        }
        await Future<void>.delayed(Duration.zero);
      } while (continuation != null && owner.active);
    } finally {
      decoder.free();
    }
    return imported.length;
  }
}
