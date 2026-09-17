import 'package:flutter/cupertino.dart';

import '../../core/notification/notification_feedback.dart';
import '../../core/notification/sound_type.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'red_packet_claim_detail_page.dart';
import 'red_packet_controller.dart';

/// 整页红包页（与微信一致）：点红包封面**整页进入**，而不是弹出居中弹窗。
///
/// - 未领取且红包仍在进行中：显示「開」，点击领取并展示金额；
/// - 领取后：展示金额与「看看大家的手气 >」，进入 [RedPacketClaimDetailPage]；
/// - 已领取 / 已领完 / 已过期 / 已撤回：由入口直接进领取详情，不再进本页。
final class RedPacketClaimPage extends StatefulWidget {
  const RedPacketClaimPage({
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
  State<RedPacketClaimPage> createState() => _RedPacketClaimPageState();
}

final class _RedPacketClaimPageState extends State<RedPacketClaimPage> {
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
    Navigator.of(context).push(
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
    return WeChatPageScaffold.navigation(
      backgroundColor: WeChatColors.redPacketGradientBottom,
      navigationBar: const CupertinoNavigationBar(
        backgroundColor: CupertinoColors.transparent,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        border: null,
        middle: Text('红包', style: TextStyle(color: CupertinoColors.white)),
      ),
      child: Container(
        key: const Key('red-packet-claim-page'),
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              WeChatColors.redPacketGradientTop,
              WeChatColors.redPacketGradientBottom,
            ],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: controller.ended
                  ? const Text('会话已结束',
                      style: TextStyle(color: CupertinoColors.white))
                  : _claimCard(detail, status),
            ),
          ),
        ),
      ),
    );
  }

  Widget _claimCard(Map<String, dynamic>? detail, String? status) => Column(
        key: const Key('red-packet-claim-card'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.senderAvatar != null)
            SizedBox.square(dimension: 56, child: widget.senderAvatar)
          else
            const SizedBox(height: 56),
          const SizedBox(height: 14),
          Text(
            '${widget.senderName}的红包',
            style: const TextStyle(color: CupertinoColors.white, fontSize: 15),
          ),
          const SizedBox(height: 12),
          Text(
            widget.greeting,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFFFF3D9),
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (detail != null && status != null && status != 'OPEN') ...[
            const SizedBox(height: 10),
            Text(
              redPacketStatusText(status),
              style: TextStyle(
                color: CupertinoColors.white.withValues(alpha: .9),
                fontSize: 13,
              ),
            ),
          ],
          const SizedBox(height: 28),
          _openButton(),
          const SizedBox(height: 20),
          if (claimedAmount != null)
            Text(
              '已领取 $claimedAmount 点钻，存入点钻余额',
              key: const Key('red-packet-claim-result'),
              style: const TextStyle(color: CupertinoColors.white, fontSize: 14),
            ),
          // 与微信一致：领取后金额与「看看大家的手气」同时可见。
          if (detail != null && detail['room_id'] != null) ...[
            const SizedBox(height: 12),
            CupertinoButton(
              key: const Key('red-packet-claim-luck-entry'),
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: _openClaimRecords,
              child: Text(
                '看看大家的手气 >',
                style: TextStyle(
                  color: CupertinoColors.white.withValues(alpha: .92),
                  fontSize: 14,
                ),
              ),
            ),
          ],
          if (claimError != null) ...[
            const SizedBox(height: 10),
            Text(
              claimError!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: CupertinoColors.white.withValues(alpha: .9),
                fontSize: 13,
              ),
            ),
          ],
        ]);

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
        width: 92,
        height: 92,
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
                  fontSize: label == '開' ? 36 : 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}
