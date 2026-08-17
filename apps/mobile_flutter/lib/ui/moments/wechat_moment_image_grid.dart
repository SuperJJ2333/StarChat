import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

final class WeChatMomentImageGrid extends StatelessWidget {
  const WeChatMomentImageGrid({super.key, required this.imageUrls});
  final List<String> imageUrls;
  @override
  Widget build(BuildContext context) {
    final count = imageUrls.length.clamp(0, 9);
    if (count == 0) return const SizedBox.shrink();
    final columns = count == 1
        ? 1
        : count == 4
            ? 2
            : 3;
    final size = count == 1 ? 180.0 : 90.0;
    return SizedBox(
      width: columns * size + (columns - 1) * WeChatSpacing.xs,
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: count,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: WeChatSpacing.xs,
            mainAxisSpacing: WeChatSpacing.xs),
        itemBuilder: (_, index) => SizedBox(
            key: const ValueKey('moment-image'),
            child: Image.network(imageUrls[index],
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    Container(color: WeChatColors.divider))),
      ),
    );
  }
}
