import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

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
import '../matrix/profile_repository.dart';

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
    this.identityCache,
    this.ledgerGateway,
  }) : assert(api != null || gateway != null);

  final BusinessApiClient? api;
  final String transferId;
  final String viewerId;
  final VoidCallback? onSettled;
  final ChatTransferDetailGateway? gateway;
  final ProfileRepository? identityCache;
  final LedgerGateway? ledgerGateway;

  @override
  State<ChatTransferDetailSheet> createState() =>
      _ChatTransferDetailSheetState();
}

final class _ChatTransferDetailSheetState
    extends State<ChatTransferDetailSheet> {
  late final ChatTransferDetailController _controller;
  late final LedgerGateway? _ledgerGateway;
  String? _copyFeedback;

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
        title: '转账',
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
      padding: const EdgeInsets.only(bottom: WeChatSpacing.md),
      children: [
        _receiptHeader(detail['amount'], status, label, isReceiver),
        _detailRows(detail, status, billId),
        if (_copyFeedback != null) ...[
          const SizedBox(height: WeChatSpacing.sm),
          Text(_copyFeedback!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: WeChatColors.textSecondary)),
        ],
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
        const SizedBox(height: WeChatSpacing.lg),
        if (pending && isReceiver)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: WeChatSpacing.md),
              child: Row(children: [
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
              ])),
        if (_ledgerGateway != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                WeChatSpacing.lg, WeChatSpacing.lg, WeChatSpacing.lg, 0),
            child: hasBillId
                ? Row(children: [
                    Expanded(
                        child: _plainAction(
                            key: const Key('chat-transfer-detail-all-bills'),
                            label: '全部账单',
                            onPressed: _openAllBills)),
                    const SizedBox(width: WeChatSpacing.md),
                    Expanded(
                        child: _plainAction(
                            key: const Key('chat-transfer-detail-ledger'),
                            label: '账单详情',
                            onPressed: () => _openLedgerDetail(billId))),
                  ])
                : _plainAction(
                    key: const Key('chat-transfer-detail-all-bills'),
                    label: '全部账单',
                    onPressed: _openAllBills),
          ),
      ],
    );
  }

  Widget _receiptHeader(
      Object? amount, String status, String label, bool isReceiver) {
    final successful = status == 'ACCEPTED';
    final active = status == 'PENDING' || successful;
    final iconColor =
        active ? WeChatColors.brandPrimary : WeChatColors.textTertiary;
    return Container(
      key: const Key('chat-transfer-receipt-hero'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 24),
      decoration: BoxDecoration(
        color: WeChatColors.elevatedSurface(context),
      ),
      child: Column(children: [
        Container(
          key: const Key('chat-transfer-receipt-icon'),
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: iconColor,
            shape: BoxShape.circle,
          ),
          child: const Icon(CupertinoIcons.arrow_left_right,
              color: CupertinoColors.white, size: 26),
        ),
        const SizedBox(height: 10),
        Text(_receiptSummary(status, isReceiver),
            style: const TextStyle(
                fontSize: 14, color: WeChatColors.textSecondary)),
        const SizedBox(height: 10),
        Text.rich(
          TextSpan(children: [
            TextSpan(
              text: _heroAmount(amount),
              style: TextStyle(
                color: WeChatColors.resolveTextPrimary(context),
                fontSize: 44,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
            const TextSpan(
              text: ' 点钻',
              style: TextStyle(fontSize: 16, color: WeChatColors.textSecondary),
            ),
          ]),
          key: const Key('chat-transfer-receipt-amount'),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: active ? const Color(0x1407C160) : const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            key: const Key('chat-transfer-receipt-status'),
            style: TextStyle(
              fontSize: 12,
              color: active
                  ? WeChatColors.brandPrimary
                  : WeChatColors.textSecondary,
            ),
          ),
        ),
      ]),
    );
  }

  String _receiptSummary(String status, bool isReceiver) => switch (status) {
        'ACCEPTED' => isReceiver ? '你已收款' : '对方已收款',
        'PENDING' => isReceiver ? '等待你收款' : '等待对方收款',
        _ => '转账收款',
      };

  Widget _detailRows(
      Map<String, dynamic> detail, String status, Object? billId) {
    final rows = <(String, String)>[
      ('转账状态', _receiptStatus(status)),
      ('说明', _text(detail['note'])),
      ('转账时间', _time(detail['created_at'])),
      (
        '收款时间',
        status == 'ACCEPTED' ? _time(detail['accepted_at']) : '尚未收款',
      ),
    ];
    return Container(
        margin: const EdgeInsets.fromLTRB(
            WeChatSpacing.md, 10, WeChatSpacing.md, 0),
        decoration: BoxDecoration(
            color: WeChatColors.elevatedSurface(context),
            borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          for (var index = 0; index < rows.length; index++)
            _row(rows[index].$1, rows[index].$2, showDivider: index > 0),
          if (billId is String && billId.isNotEmpty)
            CupertinoButton(
                key: const Key('chat-transfer-detail-copy-bill'),
                padding: EdgeInsets.zero,
                onPressed: () => _copyBillId(billId),
                child: Container(
                    decoration: const BoxDecoration(
                        border: Border(
                            top: BorderSide(color: WeChatColors.divider))),
                    padding: const EdgeInsets.symmetric(
                        horizontal: WeChatSpacing.lg,
                        vertical: WeChatSpacing.md),
                    child: Row(children: [
                      const SizedBox(
                          width: 88,
                          child: Text('账单ID',
                              style: TextStyle(
                                  color: WeChatColors.textSecondary))),
                      Expanded(child: Text(billId, textAlign: TextAlign.right)),
                      const SizedBox(width: WeChatSpacing.xs),
                      const Icon(CupertinoIcons.doc_on_doc,
                          size: 16, color: WeChatColors.textSecondary),
                    ]))),
        ]));
  }

  Widget _row(String label, String value, {bool showDivider = false}) =>
      Container(
        decoration: showDivider
            ? const BoxDecoration(
                border: Border(top: BorderSide(color: WeChatColors.divider)))
            : null,
        padding: const EdgeInsets.symmetric(
            horizontal: WeChatSpacing.lg, vertical: WeChatSpacing.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 88,
            child: Text(label,
                style: const TextStyle(color: WeChatColors.textSecondary)),
          ),
          Expanded(child: Text(value, textAlign: TextAlign.right)),
        ]),
      );

  Widget _plainAction(
          {required Key key,
          required String label,
          required VoidCallback onPressed}) =>
      CupertinoButton(
          key: key,
          padding: EdgeInsets.zero,
          onPressed: onPressed,
          child: Container(
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  border: Border.all(color: WeChatColors.textTertiary),
                  borderRadius: BorderRadius.circular(6)),
              child: Text(label,
                  style: const TextStyle(color: WeChatColors.textSecondary))));

  String _receiptStatus(String status) => switch (status) {
        'ACCEPTED' => '已收款',
        'DECLINED' => '已退回',
        'EXPIRED' => '已超时退回',
        'PENDING' => '待收款',
        _ => '状态未知',
      };

  String _heroAmount(Object? value) =>
      formatLedgerAmount(value).replaceFirst(RegExp(r' 点钻$'), '');

  String _text(Object? value) =>
      value is String && value.isNotEmpty ? value : '--';

  String _time(Object? value) {
    final date = value is String ? DateTime.tryParse(value)?.toLocal() : null;
    if (date == null) return '--';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
  }

  Future<void> _copyBillId(String billId) async {
    if (!_controller.isAlive) return;
    try {
      await Clipboard.setData(ClipboardData(text: billId));
      if (mounted && _controller.isAlive) {
        setState(() => _copyFeedback = '账单ID已复制');
      }
    } catch (_) {
      if (mounted && _controller.isAlive) {
        setState(() => _copyFeedback = '无法复制账单ID');
      }
    }
  }

  void _openLedgerDetail(String billId) {
    if (!mounted || !_controller.isAlive) return;
    final gateway = _ledgerGateway;
    if (gateway == null) return;
    Navigator.of(context).push(CupertinoPageRoute<void>(
        builder: (_) => LedgerDetailPage(
              gateway: gateway,
              transactionId: billId,
              identityCache: widget.identityCache,
            )));
  }

  void _openAllBills() {
    if (!mounted || !_controller.isAlive) return;
    final gateway = _ledgerGateway;
    if (gateway == null) return;
    Navigator.of(context).push(CupertinoPageRoute<void>(
        builder: (_) => LedgerListPage(
              gateway: gateway, identityCache: widget.identityCache)));
  }
}
