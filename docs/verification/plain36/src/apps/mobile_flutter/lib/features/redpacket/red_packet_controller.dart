import 'package:flutter/foundation.dart';

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

final class RedPacketController extends ChangeNotifier {
  RedPacketController(this.api);
  final RedPacketViewGateway api;
  Map<String, dynamic>? detail;
  bool loading = false;
  String? error;

  Future<void> load(String id) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      detail = await api.redPacketDetail(id);
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    notifyListeners();
  }

  /// Claims a share and returns the claimed amount, or rethrows the business
  /// error (e.g. already claimed / exhausted) for the caller to present.
  Future<String> claim(String id) async {
    final result = await api.claimRedPacket(id);
    await load(id);
    return result['amount']?.toString() ?? '';
  }
}
