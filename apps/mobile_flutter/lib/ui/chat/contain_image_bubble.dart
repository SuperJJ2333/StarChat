import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;

import '../../features/matrix/image_contain_layout.dart';
import '../foundation/wechat_tokens.dart';

/// 规格 #10：任意比例图片气泡——按解码后的实际宽高 contain 布局。
///
/// 替代旧的固定 200x150 cover 裁剪：
/// - 宽 ≤ min(聊天宽 72%, 320dp)、高 ≤ min(可用高 45%, 420dp)；
/// - 等比 contain（禁止 cover/拉伸/裁剪）；小图不放大；
/// - 宽高未知先占位，解码后更新尺寸（FutureBuilder 两阶段）；
/// - 点击进入大图（查看完整图片 + 缩放平移）。
final class ContainImageBubble extends StatefulWidget {
  const ContainImageBubble({
    super.key,
    required this.load,
    this.initialBytes,
    this.refreshFromSource = false,
    this.availableWidth = 400,
    this.availableHeight = 800,
    this.onTap,
  });

  final Future<Uint8List> Function() load;
  final Uint8List? initialBytes;

  /// A thumbnail can paint immediately, but must not replace the original
  /// stream: GIF content may be mislabeled by the sender as image/jpeg.
  final bool refreshFromSource;

  /// 可用聊天宽/高（调用方传 MediaQuery/LayoutBuilder 实际约束）。
  final double availableWidth;
  final double availableHeight;

  /// 点击回调（进入大图查看器由调用方组装）。
  final VoidCallback? onTap;

  @override
  State<ContainImageBubble> createState() => _ContainImageBubbleState();
}

final class _ContainImageBubbleState extends State<ContainImageBubble> {
  late Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = widget.initialBytes != null && !widget.refreshFromSource
        ? SynchronousFuture<Uint8List>(widget.initialBytes!)
        : widget.load();
  }

  @override
  Widget build(BuildContext context) {
    final constraints = ChatBubbleImageConstraints(
      availableWidth: widget.availableWidth,
      availableHeight: widget.availableHeight,
    );
    return FutureBuilder<Uint8List>(
      future: _bytes,
      initialData: widget.initialBytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () => setState(() => _bytes = widget.load()),
            child: const Text('图片加载失败，点击重试',
                style:
                    TextStyle(fontSize: 13, color: WeChatColors.brandPrimary)),
          );
        }
        if (!snapshot.hasData) {
          // 占位容器（等最大尺寸；解码后收缩到 contain 尺寸）。
          return SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight * 0.5,
            child: const Center(child: CupertinoActivityIndicator()),
          );
        }
        final bytes = snapshot.data!;
        return GestureDetector(
          onTap: widget.onTap,
          child: _ContainImage(
            bytes: bytes,
            maxWidth: constraints.maxWidth,
            maxHeight: constraints.maxHeight,
          ),
        );
      },
    );
  }
}

/// 解码实际宽高后 contain 布局的图片（内部组件）。
final class _ContainImage extends StatefulWidget {
  const _ContainImage({
    required this.bytes,
    required this.maxWidth,
    required this.maxHeight,
  });

  final Uint8List bytes;
  final double maxWidth;
  final double maxHeight;

  @override
  State<_ContainImage> createState() => _ContainImageState();
}

final class _ContainImageState extends State<_ContainImage> {
  ImageContainLayout? _layout;
  ImageStream? _sizeStream;
  ImageStreamListener? _sizeListener;
  int _layoutGeneration = 0;

  @override
  void initState() {
    super.initState();
    _resolveLayout();
  }

  void _removeSizeListener() {
    final listener = _sizeListener;
    if (listener != null) _sizeStream?.removeListener(listener);
    _sizeListener = null;
    _sizeStream = null;
  }

  @override
  void dispose() {
    _layoutGeneration++;
    _removeSizeListener();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ContainImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // R13：字节或约束变化都需重算（旋屏/视口变化后仍用旧尺寸）。
    if (!identical(oldWidget.bytes, widget.bytes) ||
        oldWidget.maxWidth != widget.maxWidth ||
        oldWidget.maxHeight != widget.maxHeight) {
      _layout = null;
      _resolveLayout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final layout = _layout;
    if (layout != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(WeChatRadius.bubble),
        child: SizedBox(
          width: layout.width,
          height: layout.height,
          child: Image.memory(
            widget.bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        ),
      );
    }
    // 先用解码器取实际宽高（不渲染整帧），再按 contain 公式布局。
    return LayoutBuilder(builder: (context, constraints) {
      return Image.memory(
        widget.bytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      );
    });
  }

  void _resolveLayout() {
    _removeSizeListener();
    final generation = ++_layoutGeneration;
    final stream =
        MemoryImage(widget.bytes).resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      try {
        if (!mounted || generation != _layoutGeneration) return;
        final corrected =
            applyExifOrientation(1, info.image.width, info.image.height);
        final layout = computeContainLayout(
          imageWidth: corrected.width,
          imageHeight: corrected.height,
          maxWidth: widget.maxWidth,
          maxHeight: widget.maxHeight,
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _layoutGeneration) {
            setState(() => _layout = layout);
          }
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      } finally {
        info.dispose();
      }
    }, onError: (Object _, StackTrace? __) {
      stream.removeListener(listener);
    });
    _sizeStream = stream;
    _sizeListener = listener;
    stream.addListener(listener);
  }
}

/// 规格 #10：三列媒体网格单元——统一外框，框内图片完整适配（不裁切）。
final class ContainGridCell extends StatelessWidget {
  const ContainGridCell({
    super.key,
    required this.bytes,
    required this.cellSize,
    this.onTap,
    this.overlay,
  });

  final Uint8List bytes;
  final double cellSize;
  final VoidCallback? onTap;

  /// 叠加层（播放按钮/时长角标等，完整覆盖在适配图之上）。
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: cellSize,
        height: cellSize,
        color: WeChatColors.darkSurface,
        child: Stack(
          alignment: Alignment.center,
          fit: StackFit.loose,
          children: [
            Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const Icon(CupertinoIcons.photo,
                  color: WeChatColors.textTertiary),
            ),
            if (overlay != null) Positioned.fill(child: overlay!),
          ],
        ),
      ),
    );
  }
}
