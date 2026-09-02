import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/amount_rules.dart';

void main() {
  group('AmountRules.validate', () {
    test('accepts positive amounts with at most two decimals', () {
      for (final value in ['8.88', '20', '0.01', ' 12.5 ', '100']) {
        expect(AmountRules.validate(value), isNull, reason: value);
      }
    });

    test('rejects more than two decimals with a clear message', () {
      expect(AmountRules.validate('1.001'), '金额最多支持两位小数');
      expect(AmountRules.validate('0.000'), '金额最多支持两位小数');
    });

    test('rejects zero and negative amounts', () {
      expect(AmountRules.validate('0'), '金额必须大于0');
      expect(AmountRules.validate('0.00'), '金额必须大于0');
      expect(AmountRules.validate('-5'), '金额格式不正确');
    });

    test('rejects malformed input', () {
      expect(AmountRules.validate(''), '请输入金额');
      expect(AmountRules.validate('abc'), '金额格式不正确');
      expect(AmountRules.validate('1.2.3'), '金额格式不正确');
      expect(AmountRules.validate('007'), '金额格式不正确');
    });
  });

  group('TwoDecimalAmountFormatter', () {
    final formatter = const TwoDecimalAmountFormatter();

    TextEditingValue edit(String oldText, String newText) =>
        formatter.formatEditUpdate(
          TextEditingValue(text: oldText),
          TextEditingValue(text: newText, selection: TextSelection.collapsed(offset: newText.length)),
        );

    test('keeps valid typing untouched', () {
      expect(edit('', '8.88').text, '8.88');
      expect(edit('8.8', '8.88').text, '8.88');
    });

    test('truncates a third decimal while typing', () {
      expect(edit('8.88', '8.881').text, '8.88');
    });

    test('drops non numeric characters', () {
      expect(edit('', '8a8.5b').text, '88.5');
    });
  });
}
