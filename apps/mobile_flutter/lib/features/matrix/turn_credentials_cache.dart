import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// Account-scoped, memory-only credentials. The SDK's cache has no TTL check.
final class TurnCredentialsCache {
  TurnCredentialsCache({
    required this.fetch,
    DateTime Function()? now,
    this.timeout = const Duration(seconds: 3),
  }) : now = now ?? DateTime.now;

  final Future<TurnServerCredentials> Function() fetch;
  final DateTime Function() now;
  final Duration timeout;
  TurnServerCredentials? _credentials;
  DateTime? _refreshAt;
  Future<List<Map<String, dynamic>>>? _pending;

  Future<List<Map<String, dynamic>>> getIceServers() {
    if (_credentials != null && now().isBefore(_refreshAt!)) {
      return Future.value(_servers(_credentials!));
    }
    return _pending ??= _refresh().whenComplete(() => _pending = null);
  }

  Future<List<Map<String, dynamic>>> _refresh() async {
    final started = now();
    _credentials = null;
    _refreshAt = null;
    try {
      final credentials = await fetch().timeout(timeout);
      // Refresh at 80% of TTL and at least every five minutes so endpoint
      // changes are picked up by a long-running app. Never reuse expired keys.
      final usableMs = (credentials.ttl * 800).clamp(0, 300000);
      final refreshAt = started.add(Duration(milliseconds: usableMs));
      if (credentials.uris.isEmpty || !now().isBefore(refreshAt)) return [];
      _credentials = credentials;
      _refreshAt = refreshAt;
      debugPrint(
          '[chatflow/turn] discovery=ready elapsed_ms=${now().difference(started).inMilliseconds}');
      return _servers(credentials);
    } catch (_) {
      // Match the SDK's direct-connect fallback without a long discovery stall.
      // Do not log exceptions: providers can include credentials in error text.
      debugPrint(
          '[chatflow/turn] discovery=unavailable elapsed_ms=${now().difference(started).inMilliseconds}');
      return [];
    }
  }

  List<Map<String, dynamic>> _servers(TurnServerCredentials credentials) => [
        {
          'username': credentials.username,
          'credential': credentials.password,
          'urls': List<String>.of(credentials.uris),
        }
      ];
}

/// Replace only discovery caching; Matrix signaling and media encryption stay
/// in the same SDK implementation for both incoming and outgoing calls.
final class RefreshingTurnVoIP extends VoIP {
  RefreshingTurnVoIP(super.client, super.delegate, this.turnCredentials);

  final TurnCredentialsCache turnCredentials;

  @override
  Future<List<Map<String, dynamic>>> getIceServers() =>
      turnCredentials.getIceServers();
}
