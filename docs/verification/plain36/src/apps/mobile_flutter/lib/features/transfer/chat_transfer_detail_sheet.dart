import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';

String chatTransferStatusLabel(String? status) => switch (status) {
      'ACCEPTED' => '对方已收款',
      'DECLINED' => '已退还',
      'EXPIRED' => '已超时退回',
      _ => '待收款',
    };

final class ChatTransferDetailSheet extends StatefulWidget {
  const ChatTransferDetailSheet({
    super.key,
    required this.api,
    required this.transferId,
    required this.viewerId,
    this.onSettled,
  });
  final BusinessApiClient api;
  final String transferId;
  final String viewerId;
  final VoidCallback? onSettled;
  @override
  State<ChatTransferDetailSheet> createState() =>
      _ChatTransferDetailSheetState();
}

final class _ChatTransferDetailSheetState
    extends State<ChatTransferDetailSheet> {
  Map<String, dynamic>? detail;
  String? error;
  bool working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final loaded = await widget.api.chatTransferDetail(widget.transferId);
      if (mounted) setState(() => detail = loaded);
    } catch (businessError) {
      if (mounted) {
        setState(() =>
            error = businessError is BusinessApiException
                ? businessError.message
                : '转账状态查询失败，请稍后重试');
      }
    }
  }

  Future<void> _act(Future<Map<String, dynamic>> Function() action) async {
    if (working) return;
    setState(() => working = true);
    try {
      final updated = await action();
      if (mounted) setState(() => detail = updated);
      widget.onSettled?.call();
    } catch (businessError) {
      if (mounted) {
        setState(() {
          error = businessError is BusinessApiException
              ? businessError.message
              : '操作失败，请稍后重试';
        });
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isReceiver = detail?['receiver_id']?.toString() == widget.viewerId;
    final isSender = detail?['sender_id']?.toString() == widget.viewerId;
    final status = detail?['status']?.toString();
    final pending = status == null || status == 'PENDING';
    return CupertinoPopupSurface(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: detail == null && error == null
              ? const SizedBox(
                  height: 220,
                  child: Center(child: CupertinoActivityIndicator()))
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: WeChatColors.warning,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(children: [
                      const Icon(ChangliaoIcons.transferFilled,
                          color: CupertinoColors.white, size: 30),
                      const SizedBox(height: 8),
                      Text(
                          '${detail?['amount'] ?? '--'} 点钻',
                          style: const TextStyle(
                              color: CupertinoColors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Text(chatTransferStatusLabel(status),
                          style: const TextStyle(
                              color: CupertinoColors.white, fontSize: 14)),
                      if (detail?['note']?.toString().isNotEmpty == true) ...[
                        const SizedBox(height: 6),
                        Text(detail!['note'].toString(),
                            style: TextStyle(
                                color: CupertinoColors.white
                                    .withValues(alpha: .9),
                                fontSize: 13)),
                      ],
                    ]),
                  ),
                  const SizedBox(height: 12),
                  if (detail != null)
                    Text(
                      isSender
                          ? '手续费 ${detail!['fee']} 点钻 · 24小时未收款将自动退回'
                          : '24小时内未收款将自动退回给对方',
                      style: const TextStyle(
                          color: WeChatColors.textSecondary, fontSize: 12),
                    ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(error!,
                        style: const TextStyle(color: WeChatColors.danger)),
                  ],
                  const SizedBox(height: 16),
                  if (pending && isReceiver)
                    Row(children: [
                      Expanded(
                        child: ModernActionButton(
                          icon: ChangliaoIcons.close,
                          label: '退还',
                          onPressed: working
                              ? null
                              : () => _act(() => widget.api
                                  .declineChatTransfer(widget.transferId)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ModernActionButton(
                          icon: ChangliaoIcons.confirm,
                          label: '收款',
                          onPressed: working
                              ? null
                              : () => _act(() => widget.api
                                  .acceptChatTransfer(widget.transferId)),
                        ),
                      ),
                    ])
                  else if (pending && isSender)
                    const Text('等待对方收款',
                        style:
                            TextStyle(color: WeChatColors.textSecondary)),
                ]),
        ),
      ),
    );
  }
}
