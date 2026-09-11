import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/business_auth_contracts.dart';
import '../contacts/contact_models.dart';

abstract interface class RedPacketViewGateway {
  Future<Map<String, dynamic>> redPacketDetail(String id);
  Future<Map<String, dynamic>> claimRedPacket(String id);
  Future<List<ContactSummary>> listContacts();
}

/// Copy shown for a non-open red packet, keyed by the business status.
String redPacketStatusText(String? status) => switch (status) {
      'COMPLETED' => '红包已被领完',
      'EXPIRED' => '已过期，未领取金额将退回',
      'CANCELLED' => '红包已撤回',
      _ => '领取红包',
    };

String? effectiveRedPacketStatus(Map<String, dynamic>? detail) {
  final status = detail?['status']?.toString();
  if (status != 'OPEN') return status;
  final serverTime = DateTime.tryParse('${detail?['server_time']}');
  final expiresAt = DateTime.tryParse('${detail?['expires_at']}');
  return serverTime != null &&
          expiresAt != null &&
          !serverTime.isBefore(expiresAt)
      ? 'EXPIRED'
      : status;
}

final class RedPacketController extends ChangeNotifier {
  RedPacketController(this.api) {
    final monitor =
        api is BusinessSessionMonitor ? api as BusinessSessionMonitor : null;
    _monitor = monitor;
    _epoch = monitor?.sessionEpoch;
    _sessionSubscription = monitor?.sessionInvalidations.listen((_) => _end());
  }
  final RedPacketViewGateway api;
  late final BusinessSessionMonitor? _monitor;
  late final int? _epoch;
  StreamSubscription<BusinessSessionInvalidation>? _sessionSubscription;
  Map<String, dynamic>? detail;
  bool loading = false;
  String? error;
  int _generation = 0;
  bool _disposed = false;
  bool _ended = false;
  bool get isAlive => _live;
  bool get ended => _ended;

  bool get _live {
    if (_disposed || _ended) return false;
    if (_monitor != null && _monitor.sessionEpoch != _epoch) {
      _end();
      return false;
    }
    return true;
  }

  void _end() {
    if (_disposed || _ended) return;
    _ended = true;
    _generation++;
    detail = null;
    loading = false;
    error = '会话已结束';
    notifyListeners();
  }

  Future<void> load(String id) async {
    if (!_live) {
      _end();
      return;
    }
    final generation = ++_generation;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final loaded = await api.redPacketDetail(id);
      if (!_live || generation != _generation) return;
      detail = loaded;
    } catch (e) {
      if (!_live || generation != _generation) return;
      error = e.toString();
    }
    if (!_live || generation != _generation) return;
    loading = false;
    notifyListeners();
  }

  /// Claims a share and returns the claimed amount, or rethrows the business
  /// error (e.g. already claimed / exhausted) for the caller to present.
  Future<String> claim(String id) async {
    if (!_live) {
      _end();
      throw StateError('会话已结束');
    }
    final result = await api.claimRedPacket(id);
    if (!_live) throw StateError('会话已结束');
    final amount = result['amount']?.toString() ?? '';
    await load(id);
    if (!_live) throw StateError('会话已结束');
    return amount;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    detail = null;
    _sessionSubscription?.cancel();
    super.dispose();
  }
}
