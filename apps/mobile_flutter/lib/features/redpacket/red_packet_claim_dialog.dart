import 'dart:ui';

import 'package:flutter/cupertino.dart';

import '../../ui/foundation/wechat_tokens.dart';
import 'red_packet_claim_detail_page.dart';
import 'red_packet_controller.dart';
import '../../core/notification/notification_feedback.dart';
import '../../core/notification/sound_type.dart';

/// WeChat-style centered red-packet claim dialog:
/// scales out from the center (250ms ease-out) over a frosted-glass backdrop,
/// closes on the X button below the card or on any tap outside the card.
Future<void> showRedPacketClaimDialog(
  BuildContext context, {
  required RedPacketViewGateway api,
  required String packetId,
  String senderName = '好友',
  String greeting = '恭喜发财，大吉大利',
  Widget? senderAvatar,
  VoidCallback? onClaimed,
}) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭红包弹窗',
    barrierColor: const Color(0x00000000),
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (dialogContext, animation, secondaryAnimation) =>
        RedPacketClaimDialog(
      api: api,
      packetId: packetId,
      senderName: senderName,
      greeting: greeting,
      senderAvatar: senderAvatar,
      onClaimed: onClaimed,
    ),
    transitionBuilder:
        (dialogContext, animation, secondaryAnimation, dialogChild) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return ScaleTransition(
        scale: Tween(begin: .6, end: 1.0).animate(curved),
        child: FadeTransition(
          opacity: curved,
          child: dialogChild,
        ),
      );
    },
  );
}

final class RedPacketClaimDialog extends StatefulWidget {
  const RedPacketClaimDialog({
    super.key,
    required this.api,
    required this.packetId,
    this.senderName = '好友',
    this.greeting = '恭喜发财，大吉大利',
    this.senderAvatar,
    this.onClaimed,
  });

  final RedPacketViewGateway api;
  final String packetId;
  final String senderName;
  final String greeting;
  final Widget? senderAvatar;
  final VoidCallback? onClaimed;

  @override
  State<RedPacketClaimDialog> createState() => _RedPacketClaimDialogState();
}

final class _RedPacketClaimDialogState extends State<RedPacketClaimDialog> {
  late final RedPacketController controller = RedPacketController(widget.api)
    ..addListener(_changed);
  bool claiming = false;
  String? claimedAmount;
  String? claimError;
  bool _notifiedClaimed = false;

  void _changed() {
    if (controller.ended) {
      claimedAmount = null;
      claimError = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    controller.load(widget.packetId);
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  bool get _available {
    final status = effectiveRedPacketStatus(controller.detail);
    return controller.detail != null &&
        status == 'OPEN' &&
        controller.detail?['viewer_claim'] == null &&
        !controller.loading &&
        controller.error == null &&
        !controller.ended;
  }

  Future<void> _claim() async {
    if (claiming ||
        claimedAmount != null ||
        !_available ||
        !controller.isAlive) {
      return;
    }
    setState(() {
      claiming = true;
      claimError = null;
    });
    try {
      final amount = await controller.claim(widget.packetId);
      // 红包开启音（PRD §4）：经统一通知入口的纯前台反馈。
      if (!controller.isAlive || !mounted) {
        return;
      }
      NotificationFeedback.shared.play(SoundType.redpacketOpen);
      if (mounted) {
        setState(() => claimedAmount = amount);
        if (!_notifiedClaimed) {
          _notifiedClaimed = true;
          try {
            widget.onClaimed?.call();
          } catch (_) {}
        }
      }
    } catch (businessError) {
      if (!controller.isAlive || !mounted) {
        return;
      }
      if (mounted) {
        setState(() {
          claimError = businessError.toString();
        });
      }
    } finally {
      if (mounted) setState(() => claiming = false);
    }
  }

  void _openClaimRecords() {
    if (!mounted || !controller.isAlive) return;
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.push(
      CupertinoPageRoute<void>(
        builder: (_) => RedPacketClaimDetailPage(
          api: widget.api,
          packetId: widget.packetId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = controller.detail;
    final status = effectiveRedPacketStatus(detail);
    if (controller.ended) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: const Center(
            child:
                Text('会话已结束', style: TextStyle(color: CupertinoColors.white))),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          color: const Color(0x66000000),
          alignment: Alignment.center,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            GestureDetector(
              onTap: () {},
              child: _claimCard(detail, status),
            ),
            CupertinoButton(
              key: const Key('red-packet-claim-close'),
              padding: const EdgeInsets.only(top: 24),
              minimumSize: Size.zero,
              onPressed: () => Navigator.of(context).pop(),
              child: const Icon(
                CupertinoIcons.xmark,
                size: 26,
                color: CupertinoColors.white,
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _claimCard(Map<String, dynamic>? detail, String? status) => Container(
        key: const Key('red-packet-claim-dialog'),
        width: 272,
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              WeChatColors.redPacketGradientTop,
              WeChatColors.redPacketGradientBottom,
            ],
          ),
          borderRadius: BorderRadius.circular(WeChatRadius.dialog + 4),
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 24,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.senderAvatar != null)
            SizedBox.square(dimension: 40, child: widget.senderAvatar)
          else
            const SizedBox(height: 40),
          const SizedBox(height: 8),
          Text(
            '${widget.senderName}的红包',
            style: const TextStyle(
              color: CupertinoColors.white,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            widget.greeting,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFFFF3D9),
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (detail != null && status != null && status != 'OPEN') ...[
            const SizedBox(height: 8),
            Text(
              redPacketStatusText(status),
              style: TextStyle(
                color: CupertinoColors.white.withValues(alpha: .9),
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 18),
          _openButton(),
          const SizedBox(height: 16),
          if (claimedAmount != null)
            Text(
              '已领取 $claimedAmount 点钻，存入点钻余额',
              key: const Key('red-packet-claim-result'),
              style: const TextStyle(
                color: CupertinoColors.white,
                fontSize: 13,
              ),
            )
          else if (detail != null && detail['room_id'] != null)
            // 私聊红包（room_id 为 null）不显示“看看大家的手气”入口。
            CupertinoButton(
              key: const Key('red-packet-claim-luck-entry'),
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: _openClaimRecords,
              child: Text(
                '看看大家的手气 >',
                style: TextStyle(
                  color: CupertinoColors.white.withValues(alpha: .92),
                  fontSize: 13,
                ),
              ),
            ),
          if (claimError != null) ...[
            const SizedBox(height: 8),
            Text(
              claimError!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: CupertinoColors.white.withValues(alpha: .9),
                fontSize: 12,
              ),
            ),
          ],
        ]),
      );

  Widget _openButton() {
    final detail = controller.detail;
    final status = effectiveRedPacketStatus(detail);
    final ownClaim = claimedAmount != null || detail?['viewer_claim'] != null;
    final label = controller.loading && detail == null
        ? '加载中'
        : ownClaim
            ? '已领取'
            : status == 'COMPLETED'
                ? '已领完'
                : status == 'EXPIRED'
                    ? '已过期'
                    : status == 'CANCELLED'
                        ? '已撤回'
                        : controller.error != null
                            ? '重试'
                            : _available
                                ? '開'
                                : '加载中';
    return GestureDetector(
      onTap: ownClaim
          ? _openClaimRecords
          : controller.error != null
              ? () => controller.load(widget.packetId)
              : _claim,
      child: Container(
        key: const Key('red-packet-claim-open-button'),
        width: 76,
        height: 76,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: WeChatColors.redPacketAction,
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(color: Color(0x33000000), blurRadius: 8),
          ],
        ),
        child: claiming
            ? const CupertinoActivityIndicator(color: CupertinoColors.white)
            : Text(
                label,
                style: TextStyle(
                  color: const Color(0xFF7A4A0D),
                  fontSize: label == '開' ? 30 : 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}

/// 领取详情页 entry rendered by [RedPacketClaimDialog]; see
/// red_packet_claim_detail_page.dart.
