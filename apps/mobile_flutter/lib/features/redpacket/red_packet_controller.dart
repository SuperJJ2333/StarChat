import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/business_auth_contracts.dart';
import '../contacts/contact_models.dart';
import 'red_packet_detail_store.dart';

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
  /// [details] 传入会话级明细缓存后，本控制器会「本地优先 → 立即展示 →
  /// 后台同步 → 失败不覆盖」；不传（如拆红包弹窗）则每个请求都以服务端为准。
  RedPacketController(this.api, {RedPacketDetailStore? details})
      : _details = details {
    final monitor =
        api is BusinessSessionMonitor ? api as BusinessSessionMonitor : null;
    _monitor = monitor;
    _epoch = monitor?.sessionEpoch;
    _sessionSubscription = monitor?.sessionInvalidations.listen((_) => _end());
  }
  final RedPacketViewGateway api;

  /// 会话级本地明细缓存；只读明细页注入，资金动作弹窗不注入。
  final RedPacketDetailStore? _details;
  late final BusinessSessionMonitor? _monitor;
  late final int? _epoch;
  StreamSubscription<BusinessSessionInvalidation>? _sessionSubscription;
  Map<String, dynamic>? detail;
  bool loading = false;
  String? error;
  int _generation = 0;
  bool _disposed = false;
  bool _ended = false;

  /// [detail] 属于哪个红包：控制器被复用于另一个红包时不得沿用旧明细。
  String? _loadedId;

  /// 本地缓存的账号/会话作用域：登录态切换后 epoch 变化，旧明细不复用。
  String get _scope => '${_epoch ?? 0}';
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
    _loadedId = null;
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
    // 本地优先 / 立即展示：本次会话已经拿到过这个红包的明细就先用它渲染，
    // 网络刷新在后台进行；有本地数据时不再进入整页 loading（L1/L2/L3）。
    final cached = _loadedId == id ? detail : _details?.read(_scope, id);
    if (cached != null) detail = cached;
    _loadedId = id;
    loading = cached == null;
    error = null;
    notifyListeners();
    try {
      final loaded = await api.redPacketDetail(id);
      if (!_live || generation != _generation) return;
      detail = loaded;
      _loadedId = id;
      _details?.write(_scope, id, loaded);
    } catch (e) {
      if (!_live || generation != _generation) return;
      // 失败不覆盖：detail 仍指向本地明细，页面继续渲染旧数据（L4）。
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
    _loadedId = null;
    _sessionSubscription?.cancel();
    super.dispose();
  }
}
