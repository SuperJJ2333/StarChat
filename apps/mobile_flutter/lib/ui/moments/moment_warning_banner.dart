import 'package:flutter/cupertino.dart';

/// Matches the warning treatment on the recharge and withdrawal screens.
final class MomentWarningBanner extends StatelessWidget {
  const MomentWarningBanner({
    super.key,
    required this.message,
    this.messageKey,
  });

  final String message;
  final Key? messageKey;

  @override
  Widget build(BuildContext context) {
    final red = CupertinoColors.systemRed.resolveFrom(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: red.withValues(alpha: 0.08),
          border: Border.all(color: red.withValues(alpha: 0.25)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(CupertinoIcons.exclamationmark_triangle_fill,
                size: 17, color: red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  key: messageKey,
                  style: TextStyle(fontSize: 13, height: 1.4, color: red)),
            ),
          ],
        ),
      ),
    );
  }
}
