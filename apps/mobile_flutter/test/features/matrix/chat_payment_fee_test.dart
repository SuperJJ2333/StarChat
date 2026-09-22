import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_payment_flow.dart';

/// ADR-0073：基础手续费与转账同规则（0.5%，最低 0.01 点钻），且全客户端只有
/// 一处实现（[chatPaymentFee]，BigInt 整数运算，无浮点估算）。
/// ADR-0078：群红包可减免，授权文案不得把基础费率当成实际费用。
void main() {
  test('手续费规则：0.5%，最低 0.01，两位四舍五入', () {
    expect(chatPaymentFee('10.00'), '0.05');
    expect(chatPaymentFee('200.00'), '1.00');
    expect(chatPaymentFee('5.00'), '0.03'); // 0.025 → half-up
    expect(chatPaymentFee('1.00'), '0.01');
    expect(chatPaymentFee('0.10'), '0.01'); // 低于下限兜底
    expect(chatPaymentFee('12'), '0.06');
    // 边界大数不得溢出或退化为浮点。
    expect(chatPaymentFee('999999999999999999999999.99').isNotEmpty, isTrue);
  });

  test('未完成/非法输入返回 null，界面据此显示"待估算"而不是抛异常', () {
    expect(chatPaymentFeeOrNull(''), isNull);
    expect(chatPaymentFeeOrNull('  '), isNull);
    expect(chatPaymentFeeOrNull('abc'), isNull);
    expect(chatPaymentFeeOrNull('1.234'), isNull, reason: '服务端只接受两位小数');
    expect(chatPaymentFeeOrNull('10.00'), '0.05');
    expect(chatPaymentFeeOrNull('12'), '0.06');
  });

  test('授权弹窗保留转账及私聊红包手续费与最低费用', () {
    expect(
        chatPaymentFeeDescription('chat_transfer.create', {'amount': '10.00'}),
        '手续费 0.05 点钻（0.5%，最低 0.01）');
    expect(chatPaymentFeeDescription('red_packet.create', {'total': '1.00'}),
        '手续费 0.01 点钻（0.5%，最低 0.01）');
    expect(chatPaymentFeeDescription('chat_transfer.create', {'amount': ''}),
        isNull);
  });

  test('群红包授权文案等待服务端核验而不承诺基础费率', () {
    final description = chatPaymentFeeDescription(
        'red_packet.create', {'total': '100.00', 'room_id': '!group:test'});
    expect(description, contains('手续费及群主减免以服务端核验为准'));
    expect(description, contains('红包详情查看'));
    expect(description, isNot(contains('0.50')));
  });
}
