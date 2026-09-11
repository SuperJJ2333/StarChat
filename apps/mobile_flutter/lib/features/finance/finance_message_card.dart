import 'package:flutter/cupertino.dart';

import '../../ui/chat/media_visibility.dart';
import '../../ui/finance/wechat_red_packet_card.dart';
import '../../ui/finance/wechat_transfer_card.dart';
import 'finance_card_store.dart';
import 'finance_message_presentation.dart';

final class FinanceMessageCard extends StatefulWidget {
  const FinanceMessageCard(
      {super.key,
      required this.store,
      required this.kind,
      required this.id,
      required this.greeting,
      required this.amount,
      required this.isOwn,
      this.onTap});
  final FinanceCardStore store;
  final FinanceCardKind kind;
  final String id;
  final String greeting;
  final String amount;
  final bool isOwn;
  final VoidCallback? onTap;
  @override
  State<FinanceMessageCard> createState() => _FinanceMessageCardState();
}

final class _FinanceMessageCardState extends State<FinanceMessageCard> {
  late FinanceCardKey _key;
  late FinanceCardLease _lease;
  late ValueNotifier<FinanceCardState> _notifier;
  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _key = FinanceCardKey(widget.kind, widget.id);
    _lease = widget.store.lease(_key);
    _notifier = _lease.notifier;
  }

  @override
  void didUpdateWidget(covariant FinanceMessageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store ||
        oldWidget.kind != widget.kind ||
        oldWidget.id != widget.id) {
      final wasVisible = _lease.visible;
      _lease.dispose();
      _attach();
      if (wasVisible) _lease.setVisible(true);
    }
  }

  @override
  void dispose() {
    _lease.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MediaVisibility(
      onChanged: (visible) => _lease.setVisible(visible),
      child: ValueListenableBuilder<FinanceCardState>(
          valueListenable: _notifier,
          builder: (context, state, _) => _card(state)));
  Widget _card(FinanceCardState state) {
    final enabled = state.detail != null && state.error == null && !state.ended;
    final retry = state.error != null && !state.ended;
    if (widget.kind == FinanceCardKind.redPacket) {
      final card = WeChatRedPacketCard(
          greeting: widget.greeting,
          state: redPacketVisualState(state.detail),
          labelOverride: state.detail == null
              ? state.ended
                  ? '会话已结束'
                  : state.error ?? (state.loading ? '加载中' : '状态未知')
              : null,
          onTap: enabled ? widget.onTap : null);
      return retry
          ? Column(mainAxisSize: MainAxisSize.min, children: [
              card,
              CupertinoButton(onPressed: _lease.retry, child: const Text('重试'))
            ])
          : card;
    }
    final detail = state.detail;
    final status = '${detail?['status'] ?? ''}';
    final sender = '${detail?['sender_id'] ?? ''}';
    final receiver = '${detail?['receiver_id'] ?? ''}';
    final label = detail == null
        ? state.ended
            ? '会话已结束'
            : state.error ?? (state.loading ? '加载中' : '状态未知')
        : transferLabel(
            status: status,
            viewerId: state.viewerId,
            senderId: sender,
            receiverId: receiver);
    final card = WeChatTransferCard(
        amount:
            detail?['amount'] is String ? detail!['amount'] as String : '--',
        state: switch (status) {
          'ACCEPTED' => TransferCardState.accepted,
          'DECLINED' || 'EXPIRED' => TransferCardState.returned,
          _ => TransferCardState.pending
        },
        isOwn: widget.isOwn,
        labelOverride: label,
        onTap: enabled ? widget.onTap : null);
    return retry
        ? Column(mainAxisSize: MainAxisSize.min, children: [
            card,
            CupertinoButton(onPressed: _lease.retry, child: const Text('重试'))
          ])
        : card;
  }
}
