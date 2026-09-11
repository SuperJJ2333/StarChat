import '../../ui/finance/wechat_red_packet_card.dart';

RedPacketVisualState redPacketVisualState(Map<String, dynamic>? detail) {
  if (detail == null) return RedPacketVisualState.available;
  if (detail['viewer_claim'] != null) return RedPacketVisualState.claimed;
  if (detail['status'] == 'CANCELLED') return RedPacketVisualState.withdrawn;
  if (detail['status'] == 'EXPIRED') return RedPacketVisualState.expired;
  if (detail['status'] == 'COMPLETED') return RedPacketVisualState.exhausted;
  final server = DateTime.tryParse('${detail['server_time']}');
  final expires = DateTime.tryParse('${detail['expires_at']}');
  if (server != null && expires != null && !expires.isAfter(server)) {
    return RedPacketVisualState.expired;
  }
  return RedPacketVisualState.available;
}

String transferLabel(
    {required String status,
    required String? viewerId,
    required String senderId,
    required String receiverId}) {
  if (status == 'ACCEPTED') {
    if (viewerId == receiverId) return '转账已收款';
    if (viewerId == senderId) return '对方已收款';
    return '转账已完成';
  }
  if (status == 'DECLINED' || status == 'EXPIRED') return '已退回';
  return viewerId == senderId
      ? '等待收款'
      : viewerId == receiverId
          ? '点击收款'
          : '转账待处理';
}
