import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../finance/finance_message_presentation.dart';
import '../ledger/ledger_business_gateway.dart';
import '../ledger/ledger_gateway.dart';
import '../ledger/ledger_pages.dart';
import 'chat_transfer_detail_controller.dart';

String chatTransferStatusLabel(String? status) => switch (status) {
      'ACCEPTED' => '对方已收款',
      'DECLINED' => '已退还',
      'EXPIRED' => '已超时退回',
      _ => '待收款',
    };

final class ChatTransferDetailSheet extends StatefulWidget {
  const ChatTransferDetailSheet({
    super.key,
    this.api,
    required this.transferId,
    required this.viewerId,
    this.onSettled,
    this.gateway,
    this.ledgerGateway,
  }) : assert(api != null || gateway != null);

  final BusinessApiClient? api;
  final String transferId;
  final String viewerId;
  final VoidCallback? onSettled;
  final ChatTransferDetailGateway? gateway;
  final LedgerGateway? ledgerGateway;

  @override
  State<ChatTransferDetailSheet> createState() =>
      _ChatTransferDetailSheetState();
}

final class _ChatTransferDetailSheetState
    extends State<ChatTransferDetailSheet> {
  late final ChatTransferDetailController _controller;
  late final LedgerGateway? _ledgerGateway;

  @override
  void initState() {
    super.initState();
    final api = widget.api;
    _controller = ChatTransferDetailController(
      gateway: widget.gateway ?? BusinessChatTransferDetailGateway(api!),
      transferId: widget.transferId,
      viewerId: widget.viewerId,
      onSettled: widget.onSettled,
    );
    _ledgerGateway = widget.ledgerGateway ??
        (api == null ? null : BusinessLedgerGateway(api));
    unawaited(_controller.load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold(
        title: '收款',
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => _body(_controller.state),
        ),
      );

  Widget _body(ChatTransferDetailState state) {
    if (state.ended) {
      return const Center(child: Text('会话已结束，请重新打开转账详情'));
    }
    if (state.detail == null) {
      if (state.loading) {
        return const Center(child: CupertinoActivityIndicator());
      }
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(state.message ?? '转账状态查询失败，请稍后重试'),
        const SizedBox(height: WeChatSpacing.md),
        ModernActionButton(
          key: const Key('chat-transfer-detail-retry'),
          icon: ChangliaoIcons.retry,
          label: '重试',
          onPressed: _controller.retry,
        ),
      ]));
    }
    final detail = state.detail!;
    final status = '${detail['status'] ?? ''}';
    final sender = '${detail['sender_id'] ?? ''}';
    final receiver = '${detail['receiver_id'] ?? ''}';
    final isReceiver = receiver == widget.viewerId;
    final pending = status == 'PENDING';
    final label = transferLabel(
      status: status,
      viewerId: widget.viewerId,
      senderId: sender,
      receiverId: receiver,
    );
    final billId = detail['bill_id'];
    final hasBillId =
        billId is String && billId.isNotEmpty && _ledgerGateway != null;
    return ListView(
      key: const Key('chat-transfer-detail-page'),
      padding: const EdgeInsets.all(WeChatSpacing.lg),
      children: [
        _receiptHeader(_amount(detail['amount']), label),
        const SizedBox(height: WeChatSpacing.lg),
        _detailRows(detail, status),
        if (state.message != null) ...[
          const SizedBox(height: WeChatSpacing.md),
          Text(state.message!,
              key: const Key('chat-transfer-detail-message'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: WeChatColors.textSecondary)),
          CupertinoButton(
            key: const Key('chat-transfer-detail-refresh-retry'),
            onPressed: _controller.retry,
            child: const Text('重试'),
          ),
        ],
        const SizedBox(height: WeChatSpacing.xl),
        if (pending && isReceiver)
          Row(children: [
            Expanded(
              child: ModernActionButton(
                key: const Key('chat-transfer-detail-decline'),
                icon: ChangliaoIcons.close,
                label: '退还',
                kind: ModernActionKind.secondary,
                loading: state.loading,
                onPressed: state.loading ? null : _controller.decline,
              ),
            ),
            const SizedBox(width: WeChatSpacing.md),
            Expanded(
              child: ModernActionButton(
                key: const Key('chat-transfer-detail-accept'),
                icon: ChangliaoIcons.confirm,
                label: '收款',
                loading: state.loading,
                onPressed: state.loading ? null : _controller.accept,
              ),
            ),
          ]),
        if (hasBillId)
          CupertinoButton(
            key: const Key('chat-transfer-detail-ledger'),
            onPressed: () => _openLedgerDetail(billId),
            child: const Text('账单详情'),
          ),
        if (_ledgerGateway != null)
          CupertinoButton(
            key: const Key('chat-transfer-detail-all-bills'),
            onPressed: _openAllBills,
            child: const Text('全部账单'),
          ),
      ],
    );
  }

  /// 收款页顶部（demo 一比一）：白底 hero + 品牌绿圆形图标 +
  /// 大字金额 + 状态胶囊（已收款=绿底，其他=灰底）。
  Widget _receiptHeader(String amount, String label) {
    final accepted = label.contains('已收款');
    return Container(
      key: const Key('chat-transfer-receipt-hero'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      decoration: BoxDecoration(
        color: CupertinoTheme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(children: [
        Container(
          width: 52,
          height: 52,
          decoration: const BoxDecoration(
            color: WeChatColors.brandPrimary,
            shape: BoxShape.circle,
          ),
          child: const Icon(CupertinoIcons.arrow_left_right,
              color: CupertinoColors.white, size: 26),
        ),
        const SizedBox(height: 10),
        Text.rich(
          TextSpan(children: [
            TextSpan(
              text: amount,
              style: TextStyle(
                color: WeChatColors.resolveTextPrimary(context),
                fontSize: 44,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
            const TextSpan(
              text: ' 点钻',
              style: TextStyle(
                  fontSize: 15, color: WeChatColors.textSecondary),
            ),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: accepted
                ? const Color(0x1407C160)
                : const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            key: const Key('chat-transfer-receipt-status'),
            style: TextStyle(
              fontSize: 12,
              color: accepted
                  ? WeChatColors.brandPrimary
                  : WeChatColors.textSecondary,
            ),
          ),
        ),
      ]),
    );
  }

  Widget _detailRows(Map<String, dynamic> detail, String status) {
    final rows = <(String, String)>[
      ('说明', _text(detail['note'])),
      ('转账时间', _time(detail['created_at'])),
      (
        '收款时间',
        status == 'ACCEPTED' ? _time(detail['accepted_at']) : '尚未收款',
      ),
    ];
    return Column(
      children: rows.map((row) => _row(row.$1, row.$2)).toList(),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: WeChatSpacing.sm),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 88,
            child: Text(label,
                style: const TextStyle(color: WeChatColors.textSecondary)),
          ),
          Expanded(child: Text(value, textAlign: TextAlign.right)),
        ]),
      );

  String _amount(Object? value) => formatLedgerAmount(value);

  String _text(Object? value) =>
      value is String && value.isNotEmpty ? value : '--';

  String _time(Object? value) {
    final date = value is String ? DateTime.tryParse(value)?.toLocal() : null;
    if (date == null) return '--';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
  }

  void _openLedgerDetail(String billId) {
    if (!mounted || !_controller.isAlive) return;
    final gateway = _ledgerGateway;
    if (gateway == null) return;
    Navigator.of(context).push(CupertinoPageRoute<void>(
        builder: (_) => LedgerDetailPage(
              gateway: gateway,
              transactionId: billId,
            )));
  }

  void _openAllBills() {
    if (!mounted || !_controller.isAlive) return;
    final gateway = _ledgerGateway;
    if (gateway == null) return;
    Navigator.of(context).push(CupertinoPageRoute<void>(
        builder: (_) => LedgerListPage(gateway: gateway)));
  }
}
