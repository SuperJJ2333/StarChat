import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_payment_flow.dart';

/// ADR-0073：红包手续费与转账同规则（0.5%，最低 0.01 点钻），且全客户端只有
/// 一处实现（[chatPaymentFee]，BigInt 整数运算，无浮点估算）。
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

  test('授权弹窗对红包与转账都显示手续费（不再只对转账显示）', () {
    final source =
        File('lib/features/matrix/chat_payment_flow.dart').readAsStringSync();
    expect(source, contains('final fee = chatPaymentFeeOrNull(amount);'));
    expect(source, contains('手续费 \$fee 点钻（0.5%，最低 0.01）'),
        reason: '两种动作共用同一手续费文案');
    expect(source, isNot(contains("transfer ? '手续费")),
        reason: '红包不得再走 null 分支隐藏手续费');
  });
}
