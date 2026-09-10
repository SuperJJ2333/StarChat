import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';
import 'moment_image_viewer_page.dart';
import 'moment_media_cache.dart';

final class WeChatMomentImageGrid extends StatefulWidget {
  const WeChatMomentImageGrid(
      {super.key,
      required this.imageUrls,
      this.imageCacheKeys = const [],
      this.mediaAccountKey,
      this.mediaOrigin,
      this.cacheNamespace = ''});
  final String cacheNamespace;
  final List<String> imageUrls;
  final List<String?> imageCacheKeys;
  final String? mediaAccountKey, mediaOrigin;
  @override
  State<WeChatMomentImageGrid> createState() => _WeChatMomentImageGridState();
}

final class _WeChatMomentImageGridState extends State<WeChatMomentImageGrid> {
  final _retries = <int, int>{};
  @override
  Widget build(BuildContext context) {
    final imageUrls = widget.imageUrls;
    final imageCacheKeys = widget.imageCacheKeys;
    final mediaAccountKey = widget.mediaAccountKey;
    final mediaOrigin = widget.mediaOrigin;
    final cacheNamespace = widget.cacheNamespace;
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
                      imageUrls: imageUrls,
                      imageCacheKeys: imageCacheKeys,
                      mediaAccountKey: mediaAccountKey,
                      mediaOrigin: mediaOrigin,
                      cacheNamespace: cacheNamespace,
                      initialIndex: index),
                )),
            child: SizedBox(
                key: const ValueKey('moment-image'),
                child: Image(
                    key: ValueKey((
                      MomentMediaCache.imageIdentity(imageUrls[index],
                          accountKey: mediaAccountKey ?? cacheNamespace,
                          trustedOrigin: mediaOrigin,
                          cacheKey: index < imageCacheKeys.length
                              ? imageCacheKeys[index]
                              : null),
                      _retries[index] ?? 0
                    )),
                    gaplessPlayback: true,
                    image: MomentMediaCache.imageProvider(imageUrls[index],
                        accountKey: mediaAccountKey ?? cacheNamespace,
                        trustedOrigin: mediaOrigin,
                        cacheKey: index < imageCacheKeys.length
                            ? imageCacheKeys[index]
                            : null),
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    frameBuilder: (_, child, frame, synchronous) =>
                        frame != null || synchronous
                            ? child
                            : ColoredBox(
                                color: WeChatColors.resolve(
                                    context, WeChatColors.divider)),
                    errorBuilder: (_, __, ___) => ColoredBox(
                        color:
                            WeChatColors.resolve(context, WeChatColors.divider),
                        child: CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: () async {
                            await MomentMediaCache.retry(
                                MomentMediaCache.imageProvider(imageUrls[index],
                                    accountKey:
                                        mediaAccountKey ?? cacheNamespace,
                                    trustedOrigin: mediaOrigin,
                                    cacheKey: index < imageCacheKeys.length
                                        ? imageCacheKeys[index]
                                        : null));
                            if (mounted) {
                              setState(() =>
                                  _retries[index] = (_retries[index] ?? 0) + 1);
                            }
                          },
                          child: const Icon(CupertinoIcons.arrow_clockwise,
                              semanticLabel: '重新加载图片'),
                        ))))),
      ),
    );
  }
}
