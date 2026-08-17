import 'package:flutter/foundation.dart';

import '../../core/business_api_client.dart';

final class RedPacketController extends ChangeNotifier {
  RedPacketController(this.api);
  final BusinessApiClient api;
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

  Future<void> claim(String id) async {
    if (loading) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      await api.claimRedPacket(id);
      await load(id);
    } catch (e) {
      error = e.toString();
      loading = false;
      notifyListeners();
    }
  }
}
