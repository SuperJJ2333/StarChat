import 'package:flutter/services.dart';

/// Shared rules for 点钻 money inputs: positive numbers with at most two
/// decimal places, matching the ledger's CAIBI precision.
abstract final class AmountRules {
  static final RegExp _pattern = RegExp(r'^(0|[1-9]\d*)(\.\d{1,2})?$');

  /// Returns `null` when [input] is a valid positive amount, otherwise a
  /// user-facing error message describing the first violated rule.
  static String? validate(String input) {
    final text = input.trim();
    if (text.isEmpty) return '请输入金额';
    if (!_pattern.hasMatch(text)) {
      return text.contains('.') && text.split('.').last.length > 2
          ? '金额最多支持两位小数'
          : '金额格式不正确';
    }
    final value = double.tryParse(text);
    if (value == null || value <= 0) return '金额必须大于0';
    return null;
  }

  static bool isValid(String input) => validate(input) == null;
}

/// Keeps typing within digits and a single dot with at most two decimals.
/// Larger violations are still rejected by [AmountRules.validate] on submit
/// (for example pasted input).
final class TwoDecimalAmountFormatter extends TextInputFormatter {
  const TwoDecimalAmountFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var text = newValue.text.replaceAll(RegExp(r'[^0-9.]'), '');
    final dot = text.indexOf('.');
    if (dot != -1) {
      final head = text.substring(0, dot);
      final tail = text.substring(dot + 1).replaceAll('.', '');
      final decimals = tail.length > 2 ? tail.substring(0, 2) : tail;
      text = '$head.$decimals';
    }
    if (text == newValue.text) return newValue;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
