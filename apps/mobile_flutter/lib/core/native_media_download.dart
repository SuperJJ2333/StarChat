import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Transport only. Matrix keys and decrypted data never enter this channel.
final class NativeMediaRequest {
  NativeMediaRequest(
      {required this.id,
      required this.url,
      required this.trustedOrigin,
      required this.kind,
      required this.maxBytes,
      this.mediaType = 'cipher',
      this.authorization}) {
    final matrix = kind == 'matrix';
    final path = matrix
        ? RegExp(r'^/_matrix/(client/v1/media|media/v3)/download/[^/]+/.+$')
        : RegExp(r'^/api/v1/moments/media/content/[^/]+$');
    if (url.scheme != 'https' ||
        url.userInfo.isNotEmpty ||
        url.origin != trustedOrigin ||
        !path.hasMatch(url.path) ||
        (!matrix && kind != 'moments') ||
        (matrix
            ? mediaType != 'cipher'
            : !['image', 'video'].contains(mediaType)) ||
        (!matrix && authorization != null) ||
        maxBytes <= 0 ||
        maxBytes > 64 * 1024 * 1024) {
      throw ArgumentError('Untrusted media request');
    }
  }
  final String id, trustedOrigin, kind, mediaType;
  final Uri url;
  final int maxBytes;
  final String? authorization;
  String get opaqueId => sha256.convert(utf8.encode(id)).toString();
}

final class NativeMediaDownloadSession {
  NativeMediaDownloadSession(this.accountId, {MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('chatflow/background_media') {
    _sessions.putIfAbsent(accountId, () => {}).add(this);
  }
  static final _sessions = <String, Set<NativeMediaDownloadSession>>{};

  /// Foreground Matrix requests join already-registered ciphertext transfers.
  /// No raw SDK data or keys are passed to the native transport.
  static Future<Uint8List>? joinPending(String accountId, String identity) {
    final id = sha256.convert(utf8.encode(identity)).toString();
    for (final session
        in _sessions[accountId] ?? <NativeMediaDownloadSession>{}) {
      final request = session._requests[id];
      if (!session._closed && request != null) {
        unawaited(session._promote(id));
        return session.download(request);
      }
    }
    return null;
  }

  final String accountId;
  final MethodChannel _channel;
  Future<String>? _nonce;
  bool _closed = false;
  final _prepared = <String, Future<void>>{};
  final _owners = <String, Set<Object>>{};
  final _releasing = <String, Future<void>>{};
  final _requests = <String, NativeMediaRequest>{};
  final _reading = <String, Future<Uint8List>>{};
  String get _account => sha256.convert(utf8.encode(accountId)).toString();
  void _check() {
    if (_closed) throw StateError('Media account revoked');
  }

  Future<String> _activate() => _nonce ??= () async {
        _check();
        final value = await _channel
            .invokeMethod<String>('activate', {'account': _account});
        if (value == null || value.isEmpty) {
          throw StateError('Media transport unavailable');
        }
        if (_closed) {
          await _channel.invokeMethod<void>(
              'revoke', {'account': _account, 'nonce': value});
          throw StateError('Media account revoked');
        }
        return value;
      }()
          .catchError((Object error) {
        _nonce = null;
        throw error;
      });

  Future<void> prepare(NativeMediaRequest request, {Object? owner}) {
    _check();
    final id = request.opaqueId;
    if (owner != null) _owners.putIfAbsent(id, () => {}).add(owner);
    final releasing = _releasing[id];
    if (releasing != null) {
      return releasing.then((_) => prepare(request, owner: owner));
    }
    _requests[request.opaqueId] = request;
    return _prepared[request.opaqueId] ??= () async {
      final nonce = await _activate();
      _check();
      await _channel.invokeMethod<void>('enqueue', {
        'account': _account,
        'nonce': nonce,
        'id': request.opaqueId,
        'url': request.url.toString(),
        'origin': request.trustedOrigin,
        'kind': request.kind,
        'mediaType': request.mediaType,
        'maxBytes': request.maxBytes,
        if (request.authorization != null)
          'authorization': request.authorization,
      });
      _check();
    }()
        .catchError((Object error) {
      _prepared.remove(request.opaqueId);
      _requests.remove(request.opaqueId);
      throw error;
    });
  }

  /// Release only this candidate's registration. A matching descriptor may
  /// still serve another candidate or an actual foreground/background reader.
  Future<void> release(NativeMediaRequest request, {required Object owner}) {
    final id = request.opaqueId;
    if (_owners[id]?.remove(owner) != true) return Future<void>.value();
    if (_owners[id]?.isNotEmpty ?? false) return Future<void>.value();
    _owners.remove(id);
    return _releasing[id] ??=
        _releaseUnused(request).catchError((Object error) {
      if (!_closed) _owners.putIfAbsent(id, () => {}).add(owner);
      throw error;
    }).whenComplete(() {
      _releasing.remove(id);
    });
  }

  Future<void> _releaseUnused(NativeMediaRequest request) async {
    final id = request.opaqueId;
    try {
      await _prepared[id];
    } catch (_) {/* A partial enqueue may still need cancellation. */}
    if (_closed ||
        (_owners[id]?.isNotEmpty ?? false) ||
        _reading.containsKey(id) ||
        !_requests.containsKey(id)) {
      return;
    }
    final pending = _nonce;
    if (pending == null) return;
    final nonce = await pending;
    if (_closed ||
        (_owners[id]?.isNotEmpty ?? false) ||
        _reading.containsKey(id)) {
      return;
    }
    await _channel.invokeMethod<void>(
        'consume', {'account': _account, 'nonce': nonce, 'id': id});
    _requests.remove(id);
    _prepared.remove(id);
  }

  Future<void> _promote(String id) async {
    try {
      final nonce = await _activate();
      _check();
      await _channel.invokeMethod<void>(
          'promote', {'account': _account, 'nonce': nonce, 'id': id});
    } catch (_) {
      /* Priority changes are best effort; transfer errors remain visible to its consumer. */
    }
  }

  Future<Uint8List> download(NativeMediaRequest request) =>
      _reading[request.opaqueId] ??= _download(request).whenComplete(() {
        _reading.remove(request.opaqueId);
      });
  Future<Uint8List> _download(NativeMediaRequest request) async {
    await prepare(request);
    final nonce = await _activate();
    final args = {'account': _account, 'nonce': nonce, 'id': request.opaqueId};
    try {
      // Polling is only result delivery. All network work runs natively even
      // when this timer is suspended. Resume reads the durable completion.
      while (true) {
        _check();
        final status =
            await _channel.invokeMapMethod<String, dynamic>('status', args);
        _check();
        if (status?['state'] == 'complete') {
          final file = File(status!['path'] as String);
          final size = await file.length();
          if (size == 0 || size > request.maxBytes) {
            throw StateError('Media size rejected');
          }
          final bytes = await file.readAsBytes();
          _check();
          if (bytes.length > request.maxBytes) {
            throw StateError('Media size rejected');
          }
          await _channel.invokeMethod<void>('consume', args);
          _prepared.remove(request.opaqueId);
          _requests.remove(request.opaqueId);
          return bytes;
        }
        if (status?['state'] != 'pending') {
          throw StateError('Media transfer failed');
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } catch (_) {
      _prepared.remove(request.opaqueId);
      _requests.remove(request.opaqueId);
      try {
        await _channel.invokeMethod<void>('consume', args);
      } catch (_) {/* Revocation already removed this result. */}
      rethrow;
    }
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _sessions[accountId]?.remove(this);
    if (_sessions[accountId]?.isEmpty ?? false) _sessions.remove(accountId);
    _prepared.clear();
    _owners.clear();
    _requests.clear();
    final pending = _nonce;
    if (pending == null) return;
    try {
      final nonce = await pending;
      await _channel
          .invokeMethod<void>('revoke', {'account': _account, 'nonce': nonce});
    } on PlatformException {
      /* Native teardown will be retried on activation. */
    } on MissingPluginException {
      /* Desktop/test platforms have no transport. */
    } on StateError {
      /* Activation raced this cancellation and revoked itself. */
    }
  }
}
