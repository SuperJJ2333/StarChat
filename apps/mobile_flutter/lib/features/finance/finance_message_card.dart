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
      this.redPacketMode,
      this.restrictedRecipientName,
      this.onTap});
  final FinanceCardStore store;
  final FinanceCardKind kind;
  final String id;
  final String greeting;
  final String amount;
  final bool isOwn;

  /// 红包类型（EQUAL/RANDOM/EXCLUSIVE）；旧消息缺少该字段时为 null。
  final String? redPacketMode;

  /// 群聊里转账收款人 / 专属红包指定成员的**本机**展示名（备注 → 昵称 →
  /// 房间显示名）。业务明细对该查看者不可见时用它渲染「转给xx」/「给xxx
  /// 的专属红包」，绝不使用消息里他人写入的备注。
  final String? restrictedRecipientName;
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
    // 业务明细不可见（群聊里别人发的转账 / 指定他人的专属红包）不是错误：
    // 卡片按消息里的公开信息只读呈现，不显示错误文案，也不提供重试。
    final restricted = state.restricted;
    final enabled = state.detail != null &&
        state.error == null &&
        !state.ended &&
        !restricted;
    // BUG-41 回归（用户指令）：弱网/断网下的「重试」按钮移除——
    // 卡片按消息公开信息只读呈现（状态未知），点击卡片即可重新拉取明细。
    if (widget.kind == FinanceCardKind.redPacket) {
      // 点击卡片即可重新拉取明细（原「重试」按钮移除）。
      return WeChatRedPacketCard(
          greeting: widget.greeting,
          state: redPacketVisualState(state.detail),
          labelOverride: restricted
              ? exclusiveRedPacketLabel(
                  mode: widget.redPacketMode,
                  recipientName: widget.restrictedRecipientName)
              : state.detail == null
                  ? state.ended
                      ? '会话已结束'
                      : state.error ?? (state.loading ? '加载中' : '状态未知')
                  : null,
          onTap: enabled
              ? widget.onTap
              : (!restricted && state.error != null && !state.ended)
                  ? _lease.retry
                  : null);
    }
    final detail = state.detail;
    final status = '${detail?['status'] ?? ''}';
    final sender = '${detail?['sender_id'] ?? ''}';
    final receiver = '${detail?['receiver_id'] ?? ''}';
    final label = detail == null
        ? restricted
            ? transferCounterpartyLabel(widget.restrictedRecipientName)
            : state.ended
                ? '会话已结束'
                : state.error ?? (state.loading ? '加载中' : '状态未知')
        : transferLabel(
            status: status,
            viewerId: state.viewerId,
            senderId: sender,
            receiverId: receiver);
    return WeChatTransferCard(
        // 明细不可见时用会话消息里的金额（本来就发给了整个房间）。
        amount: detail?['amount'] is String
            ? detail!['amount'] as String
            : widget.amount,
        state: switch (status) {
          'ACCEPTED' => TransferCardState.accepted,
          'DECLINED' || 'EXPIRED' => TransferCardState.returned,
          _ => TransferCardState.pending
        },
        isOwn: widget.isOwn,
        labelOverride: label,
        // 第三方视角状态未知：底部左侧「转账」，右侧不臆造状态。
        footerLabel: restricted ? '转账' : null,
        statusLabel: restricted ? '' : null,
        onTap: enabled
            ? widget.onTap
            : (!restricted && state.error != null && !state.ended)
                ? _lease.retry
                : null);
  }
}
