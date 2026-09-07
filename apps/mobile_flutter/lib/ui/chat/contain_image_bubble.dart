import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable;

import '../../features/matrix/image_contain_layout.dart';

import '../../features/matrix/gif_image_policy.dart';
import '../foundation/wechat_tokens.dart';

/// Bound both decoded axes without changing aspect ratio or animated frames.
ImageProvider boundedChatImageProvider(Uint8List bytes, {int maxEdge = 720}) {
  var displayBytes = bytes;
  try {
    validateGifForSend(bytes);
  } on FormatException {
    // Reject unsafe received/cached GIF before Flutter allocates its codec.
    // Keep caller-owned original bytes intact for download/forwarding.
    displayBytes = _unavailableImagePixel;
  }
  return ResizeImage(MemoryImage(displayBytes),
      width: maxEdge, height: maxEdge, policy: ResizeImagePolicy.fit);
}

final _unavailableImagePixel = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');

/// 规格 #10：任意比例图片气泡——按解码后的实际宽高 contain 布局。
///
/// 替代旧的固定 200x150 cover 裁剪：
/// - 宽 ≤ min(聊天宽 72%, 320dp)、高 ≤ min(可用高 45%, 420dp)；
/// - 等比 contain（禁止 cover/拉伸/裁剪）；小图不放大；
/// - 事件尺寸预留外框；未知尺寸保持稳定占位，完成后不跳动；
/// - 点击进入大图（查看完整图片 + 缩放平移）。
final class ContainImageBubble extends StatefulWidget {
  const ContainImageBubble({
    super.key,
    required this.load,
    this.loadCached,
    this.initialBytes,
    this.isScrolling,
    this.sourceSize,
    this.deferLoading = false,
    this.refreshFromSource = false,
    this.availableWidth = 400,
    this.availableHeight = 800,
    this.onTap,
  });

  final Future<Uint8List> Function() load;
  final Future<Uint8List?> Function()? loadCached;
  final Uint8List? initialBytes;
  final ValueListenable<bool>? isScrolling;
  final Size? sourceSize;

  /// A local outgoing echo has no downloadable SDK event until acknowledged.
  final bool deferLoading;

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
  Uint8List? _bytes;
  ImageProvider? _provider;
  bool _started = false;
  bool _failed = false;
  bool _checkingCache = false;
  int _generation = 0;
  late final Size? _sourceSize = widget.sourceSize;

  @override
  void initState() {
    super.initState();
    _accept(widget.initialBytes);
    widget.isScrolling?.addListener(_startWhenIdle);
    _probeLocalCache();
    _startWhenIdle();
  }

  void _probeLocalCache() {
    final read = widget.loadCached;
    if (_bytes != null || read == null) return;
    _checkingCache = true;
    final generation = _generation;
    void complete(Uint8List? bytes) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _checkingCache = false;
        if (_bytes == null && bytes != null) _accept(bytes);
      });
      _startWhenIdle();
    }

    Future<Uint8List?>.sync(read)
        .then(complete, onError: (Object _) => complete(null));
  }

  void _accept(Uint8List? bytes) {
    _bytes = bytes;
    _provider = bytes == null ? null : boundedChatImageProvider(bytes);
  }

  @override
  void didUpdateWidget(covariant ContainImageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isScrolling != widget.isScrolling) {
      oldWidget.isScrolling?.removeListener(_startWhenIdle);
      widget.isScrolling?.addListener(_startWhenIdle);
    }
    if (widget.initialBytes != null &&
        !identical(oldWidget.initialBytes, widget.initialBytes)) {
      _accept(widget.initialBytes);
    }
    _startWhenIdle();
  }

  void _startWhenIdle() {
    if (_started ||
        _checkingCache ||
        _failed ||
        widget.deferLoading ||
        widget.isScrolling?.value == true ||
        (_bytes != null && !widget.refreshFromSource)) {
      return;
    }
    _started = true;
    final generation = ++_generation;
    Future<Uint8List>.sync(widget.load).then((bytes) {
      if (!mounted || generation != _generation) return;
      setState(() => _accept(bytes));
    }, onError: (Object _) {
      if (!mounted || generation != _generation) return;
      setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _generation++;
    widget.isScrolling?.removeListener(_startWhenIdle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final constraints = ChatBubbleImageConstraints(
      availableWidth: widget.availableWidth,
      availableHeight: widget.availableHeight,
    );
    final size = _sourceSize;
    // Reserve geometry from event metadata before any IO. Missing/invalid
    // metadata gets a stable frame; decode completion never moves the timeline.
    final layout = size != null &&
            size.width.isFinite &&
            size.height.isFinite &&
            size.width > 0 &&
            size.height > 0
        ? computeContainLayout(
            imageWidth: size.width,
            imageHeight: size.height,
            maxWidth: constraints.maxWidth,
            maxHeight: constraints.maxHeight)
        : ImageContainLayout(
            width: constraints.maxWidth, height: constraints.maxHeight * .5);
    return SizedBox(
      width: layout.width,
      height: layout.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(WeChatRadius.bubble),
        child: _provider != null
            ? GestureDetector(
                onTap: widget.onTap,
                child: Image(
                  image: _provider!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) =>
                      const Center(child: Icon(CupertinoIcons.photo)),
                ))
            : _failed
                ? CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      setState(() {
                        _failed = false;
                        _started = false;
                      });
                      _startWhenIdle();
                    },
                    child: const Text('图片加载失败，点击重试',
                        style: TextStyle(
                            fontSize: 13, color: WeChatColors.brandPrimary)))
                : const Center(
                    child: Icon(CupertinoIcons.photo,
                        color: WeChatColors.textTertiary)),
      ),
    );
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
            Image(
              image: boundedChatImageProvider(bytes),
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
