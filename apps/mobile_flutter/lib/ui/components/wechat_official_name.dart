import 'dart:async';
import 'package:flutter/cupertino.dart';

import '../../core/support_identity_repository.dart';
import '../foundation/wechat_tokens.dart';

/// Renders the public contact name and an independently sourced support mark.
/// It never parses [name], so a Matrix nickname containing “@官方客服” remains
/// ordinary text. Page owners refresh the shared repository in batches.
final class WeChatOfficialName extends StatefulWidget {
  const WeChatOfficialName({
    super.key,
    required this.name,
    this.supportIdentities,
    this.userId,
    this.matrixUserId,
    this.nameStyle,
    this.maxLines = 1,
    this.badgeBelow = false,
  });

  final String name;
  final SupportIdentityRepository? supportIdentities;
  final String? userId;
  final String? matrixUserId;
  final TextStyle? nameStyle;
  final int maxLines;
  final bool badgeBelow;

  @override
  State<WeChatOfficialName> createState() => _WeChatOfficialNameState();
}

final class _WeChatOfficialNameState extends State<WeChatOfficialName> {
  @override
  void initState() {
    super.initState();
    _warm();
  }

  @override
  void didUpdateWidget(covariant WeChatOfficialName oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.supportIdentities != widget.supportIdentities ||
        oldWidget.userId != widget.userId ||
        oldWidget.matrixUserId != widget.matrixUserId) {
      _warm();
    }
  }

  void _warm() {
    // Defer repository notifications until the owning frame has completed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
          widget.supportIdentities?.warm([widget.userId, widget.matrixUserId]));
    });
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.supportIdentities;
    if (names == null) return _nameOnly();
    return AnimatedBuilder(
      animation: names,
      builder: (context, _) {
        final badge = names.badgeFor(
          userId: widget.userId,
          matrixUserId: widget.matrixUserId,
        );
        if (badge == null) return _nameOnly();
        final suffix = Text(
          '@$badge',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: WeChatColors.supportIdentityYellow,
            fontSize: WeChatTypography.caption,
            height: 1.2,
          ),
        );
        if (widget.badgeBelow) {
          return Column(mainAxisSize: MainAxisSize.min, children: [
            _nameOnly(),
            const SizedBox(height: 2),
            suffix,
          ]);
        }
        return LayoutBuilder(builder: (context, constraints) {
          // Reserve only a bounded portion for the badge; even compact member
          // cells must never overflow with a long name or large text scale.
          return Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: _nameOnly()),
            const SizedBox(width: WeChatSpacing.xs),
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxWidth: constraints.hasBoundedWidth
                      ? ((constraints.maxWidth - WeChatSpacing.xs) * .55)
                          .clamp(0, 120)
                      : 120),
              child: suffix,
            ),
          ]);
        });
      },
    );
  }

  Widget _nameOnly() => Text(
        widget.name,
        maxLines: widget.maxLines,
        overflow: TextOverflow.ellipsis,
        style: widget.nameStyle,
      );
}
