import 'dart:async';
import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../redpacket/red_packet_claim_detail_page.dart';
import '../redpacket/red_packet_claim_dialog.dart';
import '../transfer/chat_transfer_detail_sheet.dart';
import '../matrix/profile_repository.dart';
import 'finance_card_store.dart';
import 'finance_message_card.dart';
import '../../ui/motion/motion_page_route.dart';

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
    this.identityCache,
    this.redPacketMode,
    this.restrictedRecipientName,
    this.packetOwnerMatrixId,
    this.sendClaimNotice,
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
  final ProfileRepository? identityCache;

  /// 红包类型（EQUAL/RANDOM/EXCLUSIVE，旧消息为 null）。
  final String? redPacketMode;

  /// 第三方视角（非收款人/非指定成员）展示名，由当前账号本机解析。
  final String? restrictedRecipientName;

  /// 红包发起者的 Matrix ID（来自会话消息发送者）：领取成功后据此发送
  /// 「领取了你的红包」提示事件。
  final String? packetOwnerMatrixId;
  /// 领取提示发送通道（由会话页注入，走加密房间时间线）。
  final Future<void> Function({required String packetId,
          required String ownerMatrixId})? sendClaimNotice;

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
      // E2-C（微信式）：暖缓存点击**立即**路由——弹层/详情页自带加载，
      // 不再先等一轮强制明细往返（领取卡顿根因）。只有冷缓存才先取明细。
      final cached = lease.notifier.value;
      if (cached.hasData && !cached.ended && !cached.restricted) {
        if (!live()) return;
        await _route(
            kind: kind, id: id, state: cached, store: store, live: live);
        if (live()) store.invalidate(key);
        return;
      }
      final state = await lease.ensureFresh();
      if (!live() ||
          state.ended ||
          state.restricted ||
          state.error != null ||
          state.detail == null) {
        return;
      }
      if (!live()) return;
      await _route(kind: kind, id: id, state: state, store: store, live: live);
      if (live()) store.invalidate(key);
    } finally {
      lease.dispose();
      if (live()) _routing = false;
    }
  }

  Future<void> _route({
    required FinanceCardKind kind,
    required String id,
    required FinanceCardState state,
    required FinanceCardStore store,
    required bool Function() live,
  }) async {
    final api = widget.api;
    final key = FinanceCardKey(kind, id);
    if (kind == FinanceCardKind.redPacket) {
      final detail = state.detail!;
      final ownPrivatePacket = detail.containsKey('room_id') &&
          detail['room_id'] == null &&
          detail['sender_id']?.toString() == state.viewerId;
      if (detail['viewer_claim'] != null || ownPrivatePacket) {
        if (!mounted) return;
        await Navigator.of(context).push<void>(MotionPageRoute<void>(
          builder: (_) => RedPacketClaimDetailPage(api: api, packetId: id),
        ));
        return;
      }
      if (!mounted) return;
      await showRedPacketClaimDialog(
        context,
        api: api,
        packetId: id,
        senderName: widget.senderName,
        greeting: widget.greeting,
        senderAvatar: widget.senderAvatar,
        onClaimed: () {
          if (!live()) return;
          // E2-C：乐观翻转（已领取），权威数据随后由 invalidate 刷新。
          store.patchDetail(key, (detail) => {
                ...detail,
                'viewer_claim': const <String, dynamic>{'amount': ''},
              });
          store.invalidate(key);
          final owner = widget.packetOwnerMatrixId;
          final sendNotice = widget.sendClaimNotice;
          if (owner != null && owner.isNotEmpty && sendNotice != null) {
            unawaited(sendNotice(packetId: id, ownerMatrixId: owner)
                .catchError((_) {}));
          }
        },
      );
      return;
    }
    final viewerId = state.viewerId;
    if (viewerId == null || viewerId.isEmpty || !mounted) return;
    await Navigator.of(context).push<void>(MotionPageRoute<void>(
      builder: (_) => ChatTransferDetailSheet(
        api: api,
        transferId: id,
        viewerId: viewerId,
        onSettled: () {
          if (!live()) return;
          store.patchDetail(
              key, (detail) => {...detail, 'status': 'ACCEPTED'});
          store.invalidate(key);
        },
        identityCache: widget.identityCache,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) => FinanceMessageCard(
        store: widget.store,
        kind: widget.kind,
        id: widget.id,
        greeting: widget.greeting,
        amount: widget.amount,
        isOwn: widget.isOwn,
        redPacketMode: widget.redPacketMode,
        restrictedRecipientName: widget.restrictedRecipientName,
        onTap: _open,
      );
}
