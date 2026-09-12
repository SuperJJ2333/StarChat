import 'package:flutter/cupertino.dart';
import '../foundation/wechat_tokens.dart';

enum TransferCardState { pending, accepted, returned }

/// 聊天内转账气泡（demo 一比一）：白底卡片 + 圆形图标 + 状态细条 + 底部说明行；
/// 状态条颜色区分——待收=品牌绿、已收款=橙、退回=灰。
final class WeChatTransferCard extends StatelessWidget {
  const WeChatTransferCard({
    super.key,
    required this.amount,
    required this.state,
    required this.isOwn,
    this.labelOverride,
    this.onTap,
  });
  final String amount;
  final TransferCardState state;
  final bool isOwn;
  final VoidCallback? onTap;
  final String? labelOverride;

  String get label =>
      labelOverride ??
      switch (state) {
        TransferCardState.pending => isOwn ? '等待收款' : '点击收款',
        TransferCardState.accepted => isOwn ? '对方已收款' : '转账已收款',
        TransferCardState.returned => '已退回',
      };

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final surface =
        dark ? WeChatColors.darkElevated : WeChatColors.lightElevated;
    final foreground =
        dark ? WeChatColors.darkTextPrimary : WeChatColors.lightTextPrimary;
    final barColor = switch (state) {
      TransferCardState.pending => WeChatColors.brandPrimary,
      TransferCardState.accepted => const Color(0xFFFA9D3B),
      TransferCardState.returned => WeChatColors.textTertiary,
    };
    // demo 定稿：图标右下角小角标——⏱ 待收 / ✓ 已收 / ↺ 退回。
    final (badge, badgeColor) = switch (state) {
      TransferCardState.pending => (
          CupertinoIcons.clock_fill,
          WeChatColors.brandPrimary
        ),
      TransferCardState.accepted => (
          CupertinoIcons.check_mark_circled_solid,
          const Color(0xFFFA9D3B)
        ),
      TransferCardState.returned => (
          CupertinoIcons.arrow_uturn_left_circle_fill,
          WeChatColors.textTertiary
        ),
    };
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Container(
        key: const Key('wechat-transfer-card'),
        width: 220,
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 3,
              offset: Offset(0, 1),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 9),
            child: Row(children: [
              // demo 定稿：状态圆 + 右下角 14px 状态角标（白描边）。
              SizedBox(
                width: 38,
                height: 38,
                child: Stack(clipBehavior: Clip.none, children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: barColor,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(CupertinoIcons.arrow_left_right,
                        color: CupertinoColors.white, size: 18),
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: badgeColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: dark
                                ? WeChatColors.darkElevated
                                : WeChatColors.lightElevated,
                            width: 1.5),
                      ),
                      child: Icon(badge,
                          size: 10, color: CupertinoColors.white),
                    ),
                  ),
                ]),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$amount 点钻',
                      style: TextStyle(
                        color: state == TransferCardState.returned
                            ? WeChatColors.textSecondary
                            : foreground,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      style: const TextStyle(
                        color: WeChatColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ]),
          ),
          Container(height: 2, color: barColor),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  isOwn ? '转账给对方' : '对方转给你',
                  style: const TextStyle(
                      color: WeChatColors.textSecondary, fontSize: 11),
                ),
                Text(
                  switch (state) {
                    TransferCardState.pending => '待收款',
                    TransferCardState.accepted => '已收款',
                    TransferCardState.returned => '已退回',
                  },
                  style: TextStyle(
                    color: state == TransferCardState.returned
                        ? WeChatColors.textTertiary
                        : WeChatColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
