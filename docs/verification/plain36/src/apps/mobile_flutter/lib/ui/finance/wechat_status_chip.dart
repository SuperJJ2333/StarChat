import 'package:flutter/cupertino.dart';
import '../foundation/wechat_tokens.dart';

enum FinanceSemanticStatus { processing, succeeded, failed }

final class WeChatStatusChip extends StatelessWidget {
  const WeChatStatusChip({super.key, required this.status});
  final FinanceSemanticStatus status;
  @override
  Widget build(BuildContext context) {
    final (label, icon, color) = switch (status) {
      FinanceSemanticStatus.processing => (
          '处理中',
          CupertinoIcons.clock,
          WeChatColors.warning
        ),
      FinanceSemanticStatus.succeeded => (
          '成功',
          CupertinoIcons.checkmark_circle_fill,
          WeChatColors.brandPrimary
        ),
      FinanceSemanticStatus.failed => (
          '失败',
          CupertinoIcons.xmark_circle_fill,
          WeChatColors.danger
        )
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(color: color, fontSize: 14))
    ]);
  }
}
