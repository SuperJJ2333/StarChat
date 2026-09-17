import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// TURN 在本项目里的**准确**定位（诊断措辞依据，避免误导真机判断）：
///
/// - TURN 是**连接可靠性 fallback**，不是天然的加速器。当双方能走
///   host / srflx（P2P 直连）时，直连路径的延迟通常**低于**经 TURN 中继；
/// - `discovery=unavailable` 的含义只是「本次只有 host/srflx 等可达路径」，
///   它**不能**直接推出「远距离一定卡」；
/// - 真正危险的组合是：
///   ① **需要 TURN**（严格 NAT / CGNAT / 运营商级 NAT 下直连打不通）**且没有
///      TURN** → 可能完全无法建立连接；
///   ② 需要 TURN 且**中继区域非常远** → 媒体绕行导致 RTT 显著升高。
///
/// 因此真机判断必须结合 `[chatflow/callquality]` 的 `path=direct|relay`、
/// `turn=used|not-used`、`rttAvg` 一起看，而不是只看这一行 discovery 结果。
/// 客户端不做区域选择，多区域 TURN 属于服务端基础设施。
///
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
          '[chatflow/turn] discovery=ready elapsed_ms=${now().difference(started).inMilliseconds} '
          'servers=${credentials.uris.length}');
      return _servers(credentials);
    } catch (_) {
      // Match the SDK's direct-connect fallback without a long discovery stall.
      // Do not log exceptions: providers can include credentials in error text.
      //
      // 措辞刻意保守：这只表示「没有可用中继」，不表示「远距离一定卡」。
      // 直连成功时延迟通常更低；风险是严格 NAT/CGNAT 下可能完全连不通。
      // 刻意不打印 TURN 主机名/用户名/凭据。
      debugPrint(
          '[chatflow/turn] discovery=unavailable elapsed_ms=${now().difference(started).inMilliseconds} '
          'note=direct-paths-only-oneway-risk=strict-nat-without-relay');
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
