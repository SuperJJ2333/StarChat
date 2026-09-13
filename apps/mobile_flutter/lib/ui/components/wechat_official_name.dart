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
  });

  final String name;
  final SupportIdentityRepository? supportIdentities;
  final String? userId;
  final String? matrixUserId;
  final TextStyle? nameStyle;
  final int maxLines;

  @override
  State<WeChatOfficialName> createState() => _WeChatOfficialNameState();
}

final class _WeChatOfficialNameState extends State<WeChatOfficialName> {
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
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: _nameOnly()),
            const SizedBox(width: WeChatSpacing.xs),
            Text(
              '@$badge',
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: const TextStyle(
                color: WeChatColors.supportIdentityYellow,
                fontSize: WeChatTypography.caption,
                height: 1.2,
              ),
            ),
          ],
        );
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
