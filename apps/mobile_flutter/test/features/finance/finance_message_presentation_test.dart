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

  test('third-party transfer copy names the receiver, never an error', () {
    expect(transferCounterpartyLabel('张三'), '转给张三');
    expect(transferCounterpartyLabel('  李四  '), '转给李四');
    // 旧消息没有收款对象时保持中性文案（不得回退到错误/重试）。
    expect(transferCounterpartyLabel(null), '转账');
    expect(transferCounterpartyLabel(''), '转账');
  });

  test('third-party exclusive packet copy names the designated member', () {
    expect(
        exclusiveRedPacketLabel(mode: 'EXCLUSIVE', recipientName: '王五'),
        '给王五的专属红包');
    // 旧消息缺少类型时同样按专属红包处理（该分支只可能来自专属红包）。
    expect(exclusiveRedPacketLabel(recipientName: '王五'), '给王五的专属红包');
    expect(exclusiveRedPacketLabel(mode: 'EXCLUSIVE'), '专属红包');
    expect(exclusiveRedPacketLabel(mode: 'EXCLUSIVE', recipientName: '  '),
        '专属红包');
    // 普通群红包在群成员视角本就可领取。
    expect(exclusiveRedPacketLabel(mode: 'RANDOM', recipientName: '王五'),
        '领取红包');
    expect(exclusiveRedPacketLabel(mode: 'EQUAL'), '领取红包');
  });

  test('counterparty display name prefers the viewer local remark only', () {
    expect(
        counterpartyDisplayName(
            remark: '我的备注', nickname: '公开昵称', roomDisplayName: '群名片'),
        '我的备注');
    expect(
        counterpartyDisplayName(nickname: '公开昵称', roomDisplayName: '群名片'),
        '公开昵称');
    expect(counterpartyDisplayName(roomDisplayName: '群名片'), '群名片');
    expect(counterpartyDisplayName(remark: '  ', nickname: ''), isNull);
    expect(counterpartyDisplayName(), isNull);
  });
}
