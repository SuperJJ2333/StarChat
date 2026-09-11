import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../redpacket/red_packet_claim_detail_page.dart';
import '../redpacket/red_packet_claim_dialog.dart';
import '../transfer/chat_transfer_detail_sheet.dart';
import 'finance_card_store.dart';
import 'finance_message_card.dart';

/// The real message-timeline entry for a business-authoritative finance card.
///
/// Card rendering remains scoped to [FinanceMessageCard]. A tap takes a short
/// explicit lease to refresh only this business key before choosing its route.
final class FinanceMessageEntry extends StatefulWidget {
  const FinanceMessageEntry({
    super.key,
    required this.store,
    required this.api,
    required this.kind,
    required this.id,
    required this.greeting,
    required this.amount,
    required this.isOwn,
    this.senderName = '好友',
    this.senderAvatar,
  });

  final FinanceCardStore store;
  final BusinessApiClient api;
  final FinanceCardKind kind;
  final String id;
  final String greeting;
  final String amount;
  final bool isOwn;
  final String senderName;
  final Widget? senderAvatar;

  @override
  State<FinanceMessageEntry> createState() => _FinanceMessageEntryState();
}

final class _FinanceMessageEntryState extends State<FinanceMessageEntry> {
  bool _routing = false;
  int _operationGeneration = 0;

  @override
  void didUpdateWidget(covariant FinanceMessageEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store ||
        oldWidget.api != widget.api ||
        oldWidget.kind != widget.kind ||
        oldWidget.id != widget.id) {
      _operationGeneration++;
      _routing = false;
    }
  }

  Future<void> _open() async {
    if (_routing || !mounted) return;
    _routing = true;
    final store = widget.store;
    final api = widget.api;
    final kind = widget.kind;
    final id = widget.id;
    final key = FinanceCardKey(kind, id);
    final greeting = widget.greeting;
    final senderName = widget.senderName;
    final senderAvatar = widget.senderAvatar;
    final epoch = api.sessionEpoch;
    final operation = _operationGeneration;
    bool live() =>
        mounted &&
        identical(widget.store, store) &&
        identical(widget.api, api) &&
        widget.kind == kind &&
        widget.id == id &&
        api.sessionEpoch == epoch &&
        _operationGeneration == operation;
    final lease = store.lease(key);
    try {
      final state = await lease.ensureFresh();
      if (!live() ||
          state.ended ||
          state.error != null ||
          state.detail == null) {
        return;
      }
      if (kind == FinanceCardKind.redPacket) {
        final detail = state.detail!;
        final ownPrivatePacket = detail.containsKey('room_id') &&
            detail['room_id'] == null &&
            detail['sender_id']?.toString() == state.viewerId;
        if (detail['viewer_claim'] != null || ownPrivatePacket) {
          if (!mounted) return;
          if (!live()) return;
          await Navigator.of(context).push<void>(CupertinoPageRoute<void>(
            builder: (_) => RedPacketClaimDetailPage(api: api, packetId: id),
          ));
        } else {
          if (!mounted) return;
          if (!live()) return;
          await showRedPacketClaimDialog(
            context,
            api: api,
            packetId: id,
            senderName: senderName,
            greeting: greeting,
            senderAvatar: senderAvatar,
            onClaimed: () {
              if (live()) store.invalidate(key);
            },
          );
        }
      } else {
        final viewerId = state.viewerId;
        if (viewerId == null || viewerId.isEmpty || !mounted) return;
        if (!live()) return;
        await Navigator.of(context).push<void>(CupertinoPageRoute<void>(
          builder: (_) => ChatTransferDetailSheet(
            api: api,
            transferId: id,
            viewerId: viewerId,
            onSettled: () {
              if (live()) store.invalidate(key);
            },
          ),
        ));
      }
      if (live()) store.invalidate(key);
    } finally {
      lease.dispose();
      if (live()) _routing = false;
    }
  }

  @override
  Widget build(BuildContext context) => FinanceMessageCard(
        store: widget.store,
        kind: widget.kind,
        id: widget.id,
        greeting: widget.greeting,
        amount: widget.amount,
        isOwn: widget.isOwn,
        onTap: _open,
      );
}
