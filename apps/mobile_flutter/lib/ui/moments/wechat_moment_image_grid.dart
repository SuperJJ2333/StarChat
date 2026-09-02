import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';
import 'moment_image_viewer_page.dart';

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
        itemBuilder: (_, index) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 点击朋友圈图片 → 全屏查看大图（支持双指缩放）。
            onTap: () => Navigator.push(
                context,
                CupertinoPageRoute(
                  fullscreenDialog: true,
                  builder: (_) => MomentImageViewerPage(
                      imageUrls: imageUrls, initialIndex: index),
                )),
            child: SizedBox(
                key: const ValueKey('moment-image'),
                child: Image.network(imageUrls[index],
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        Container(color: WeChatColors.divider)))),
      ),
    );
  }
}
