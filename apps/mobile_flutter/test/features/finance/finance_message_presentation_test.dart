import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/finance/finance_message_presentation.dart';
import 'package:liuhetong_mobile/ui/finance/wechat_red_packet_card.dart';

void main() {
  test('viewer claim wins packet terminal state', () {
    expect(
        redPacketVisualState({
          'viewer_claim': {'user_id': 'u'},
          'status': 'COMPLETED'
        }),
        RedPacketVisualState.claimed);
    expect(redPacketVisualState({'status': 'COMPLETED'}),
        RedPacketVisualState.exhausted);
    expect(redPacketVisualState({'status': 'EXPIRED'}),
        RedPacketVisualState.expired);
    expect(redPacketVisualState({'status': 'CANCELLED'}),
        RedPacketVisualState.withdrawn);
    expect(
        redPacketVisualState({
          'server_time': '2026-01-02T00:00:00Z',
          'expires_at': '2026-01-01T00:00:00Z'
        }),
        RedPacketVisualState.expired);
  });
  test('accepted transfer copy uses business identities', () {
    expect(
        transferLabel(
            status: 'ACCEPTED', viewerId: 'r', senderId: 's', receiverId: 'r'),
        '转账已收款');
    expect(
        transferLabel(
            status: 'ACCEPTED', viewerId: 's', senderId: 's', receiverId: 'r'),
        '对方已收款');
    expect(
        transferLabel(
            status: 'ACCEPTED', viewerId: 'x', senderId: 's', receiverId: 'r'),
        '转账已完成');
  });
}
