import 'package:flutter/cupertino.dart';
import '../foundation/changliao_icons.dart';
import '../foundation/wechat_tokens.dart';

enum TransferCardState { pending, accepted, returned }

final class WeChatTransferCard extends StatelessWidget {
  const WeChatTransferCard({
    super.key,
    required this.amount,
    required this.state,
    required this.isOwn,
    this.onTap,
  });
  final String amount;
  final TransferCardState state;
  final bool isOwn;
  final VoidCallback? onTap;

  String get label => switch (state) {
        TransferCardState.pending =>
          isOwn ? '等待收款' : '点击收款',
        TransferCardState.accepted =>
          isOwn ? '对方已收款' : '已收款',
        TransferCardState.returned => '已退回',
      };

  @override
  Widget build(BuildContext context) => CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: onTap,
        child: Container(
          key: const Key('wechat-transfer-card'),
          width: 236,
          height: 96,
          decoration: BoxDecoration(
            color: WeChatColors.warning,
            borderRadius: BorderRadius.circular(WeChatRadius.redPacket),
          ),
          child: Column(children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  const Icon(ChangliaoIcons.transferFilled,
                      color: CupertinoColors.white, size: 32),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('$amount 点钻',
                            style: const TextStyle(
                                color: CupertinoColors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(label,
                            style: const TextStyle(
                                color: CupertinoColors.white, fontSize: 13)),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
            Container(
              height: 24,
              color: CupertinoColors.white.withValues(alpha: .9),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: const Text('畅聊点钻转账',
                  style: TextStyle(
                      color: WeChatColors.textSecondary, fontSize: 11)),
            ),
          ]),
        ),
      );
}
