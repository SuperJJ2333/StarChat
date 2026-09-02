import 'package:flutter/cupertino.dart';

/// 朋友圈图片全屏查看页：网络大图 + 双指缩放 + 左右切换 + 点击关闭。
final class MomentImageViewerPage extends StatefulWidget {
  const MomentImageViewerPage({
    super.key,
    required this.imageUrls,
    required this.initialIndex,
  });

  final List<String> imageUrls;
  final int initialIndex;

  @override
  State<MomentImageViewerPage> createState() => _MomentImageViewerPageState();
}

final class _MomentImageViewerPageState extends State<MomentImageViewerPage> {
  late int index = widget.initialIndex.clamp(0, widget.imageUrls.length - 1);

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        backgroundColor: CupertinoColors.black,
        child: SafeArea(
          child: Stack(children: [
            PageView.builder(
              itemCount: widget.imageUrls.length,
              controller: PageController(initialPage: index),
              onPageChanged: (value) {
                if (mounted) setState(() => index = value);
              },
              itemBuilder: (context, i) => GestureDetector(
                onTap: () => Navigator.pop(context),
                child: InteractiveViewer(
                  maxScale: 4,
                  child: Center(
                    child: Image.network(
                      widget.imageUrls[i],
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Center(
                        child: Text('图片加载失败',
                            style: TextStyle(
                                color: CupertinoColors.systemGrey)),
                      ),
                      loadingBuilder: (_, child, progress) {
                        if (progress == null) return child;
                        return const Center(
                            child: CupertinoActivityIndicator());
                      },
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 16,
              child: Text(
                widget.imageUrls.length > 1
                    ? '${index + 1} / ${widget.imageUrls.length}'
                    : '',
                style: const TextStyle(
                    fontSize: 13, color: CupertinoColors.systemGrey),
              ),
            ),
          ]),
        ),
      );
}
