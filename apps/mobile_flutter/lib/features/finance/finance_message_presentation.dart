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

/// 群聊第三方视角（既非付款人也非收款人，业务明细不可见）的转账文案：
/// 「转给xx」。xx 只由**查看者本机**的联系人投影解析（备注 → 昵称 →
/// 房间内显示名），消息里只带收款人账号标识，绝不携带任何人的备注。
String transferCounterpartyLabel(String? recipientName) {
  final name = recipientName?.trim() ?? '';
  return name.isEmpty ? '转账' : '转给$name';
}

/// 第三方视角展示名解析：**本机**备注 → 昵称 → 会话内显示名。
/// 备注是隐私，只取当前账号自己的联系人投影；消息内容只携带账号标识，
/// 任何情况下都不得把他人写入的备注当作展示名。
String? counterpartyDisplayName(
    {String? remark, String? nickname, String? roomDisplayName}) {
  for (final value in [remark, nickname, roomDisplayName]) {
    final text = value?.trim() ?? '';
    if (text.isNotEmpty) return text;
  }
  return null;
}

/// 群聊第三方视角的专属红包文案：「给xxx的专属红包」。
/// 普通群红包（EQUAL/RANDOM）在群成员视角本就可领取，只有专属红包
/// 会对非指定成员返回 403；mode 缺失（旧消息）时按专属红包处理。
String exclusiveRedPacketLabel({String? mode, String? recipientName}) {
  if (mode == 'EQUAL' || mode == 'RANDOM') return '领取红包';
  final name = recipientName?.trim() ?? '';
  return name.isEmpty ? '专属红包' : '给$name的专属红包';
}
