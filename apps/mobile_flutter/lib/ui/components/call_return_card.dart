import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../../features/matrix/call_controller.dart';
import '../foundation/changliao_icons.dart';
import '../foundation/wechat_tokens.dart';
import 'user_avatar.dart';

/// Presentation only. The original connectedAt survives route restoration.
final class WeChatCallReturnCard extends StatefulWidget {
  const WeChatCallReturnCard(
      {super.key,
      required this.identity,
      required this.type,
      required this.connectedAt,
      required this.now,
      required this.onPressed});
  final CallIdentity? identity;
  final CallMediaType type;
  final DateTime? connectedAt;
  final DateTime Function() now;
  final VoidCallback onPressed;
  @override
  State<WeChatCallReturnCard> createState() => _WeChatCallReturnCardState();
}

final class _WeChatCallReturnCardState extends State<WeChatCallReturnCard> {
  Timer? _ticker;
  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.connectedAt != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final identity = widget.identity;
    final duration = widget.connectedAt == null
        ? '等待接通'
        : formatCallDuration(widget.now().difference(widget.connectedAt!));
    return Semantics(
        button: true,
        label: '返回通话 ${identity?.displayName ?? ''} $duration',
        child: CupertinoButton(
          padding: const EdgeInsets.all(WeChatSpacing.sm),
          color: WeChatColors.elevatedSurface(context),
          borderRadius: BorderRadius.circular(WeChatRadius.dialog),
          onPressed: widget.onPressed,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            UserAvatar(
                nickname: identity?.displayName ?? '通话',
                fallbackSeed: identity?.fallbackSeed ?? 'active-call',
                avatarUrl: identity?.avatarUrl,
                avatarHeaders: identity?.avatarHeaders,
                diagnosticSource: 'call-return',
                size: WeChatDimensions.conversationAvatar),
            const SizedBox(height: WeChatSpacing.xs),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                  widget.type == CallMediaType.video
                      ? ChangliaoIcons.videoCallFilled
                      : ChangliaoIcons.voiceCallFilled,
                  size: WeChatTypography.subhead,
                  color: WeChatColors.brandPrimary),
              const SizedBox(width: WeChatSpacing.xs),
              Text(duration,
                  style: TextStyle(
                      fontSize: WeChatTypography.caption,
                      color: WeChatColors.resolveTextPrimary(context))),
            ]),
          ]),
        ));
  }
}
