import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

/// 次级动作按钮的语义色调。
enum WeChatButtonTone {
  /// 无背景色：必须有可见边框，否则用户无法区分按钮与普通文本。
  neutral,

  /// 危险动作（如取消提现申请）：使用设计规范的危险色填充。
  danger,
}

/// 钱包等页面上的文本动作按钮。
///
/// 设计规则：**动作按钮不得看起来像纯文本**。没有背景色的动作一律带边框；
/// 危险动作使用 `--color-danger`（[WeChatColors.dangerFill]）填充 + 白字。
final class WeChatSecondaryButton extends StatelessWidget {
  const WeChatSecondaryButton(
      {super.key,
      required this.label,
      required this.onPressed,
      this.tone = WeChatButtonTone.neutral});

  final String label;
  final VoidCallback? onPressed;
  final WeChatButtonTone tone;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final danger = tone == WeChatButtonTone.danger;
    final fill = danger ? WeChatColors.dangerFill : null;
    final borderColor = danger
        ? WeChatColors.dangerFill
        : enabled
            ? WeChatColors.controlBorder
            : WeChatColors.divider;
    final labelColor = !enabled
        ? WeChatColors.textTertiary
        : danger
            ? CupertinoColors.white
            : WeChatColors.brandPrimary;
    return Semantics(
        button: true,
        enabled: enabled,
        label: label,
        child: Container(
            decoration: BoxDecoration(
                color: enabled ? fill : null,
                border: Border.all(color: borderColor),
                borderRadius:
                    BorderRadius.circular(WeChatRadius.actionButton)),
            child: CupertinoButton(
                padding: const EdgeInsets.symmetric(
                    horizontal: WeChatSpacing.actionButtonHorizontal,
                    vertical: 10),
                minimumSize: const Size.square(
                    WeChatDimensions.minimumTouchTarget),
                onPressed: onPressed,
                child: Text(label,
                    style: TextStyle(
                        color: labelColor,
                        fontSize: WeChatTypography.callout)))));
  }
}
