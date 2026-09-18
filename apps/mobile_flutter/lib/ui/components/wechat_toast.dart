import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

enum WeChatToastSemanticType { success, error, info }

/// 显示一条微信样式浮层提示（黑底胶囊 + 图标），`duration` 后自动消失。
///
/// 提示挂在根 Overlay 上，因此触发它的页面即使立即 pop（例如「设置拍一拍」
/// 保存后返回），提示仍会完整显示，属于一次性反馈而不是页面内状态。
void showWeChatToast(
  BuildContext context,
  String message, {
  WeChatToastSemanticType semanticType = WeChatToastSemanticType.info,
  Duration duration = const Duration(seconds: 2),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late final OverlayEntry entry;
  var removed = false;
  void remove() {
    if (removed) return;
    removed = true;
    entry.remove();
  }

  entry = OverlayEntry(
    builder: (_) => _WeChatToastOverlay(
      message: message,
      semanticType: semanticType,
      duration: duration,
      reduceMotion: MediaQuery.maybeDisableAnimationsOf(context) ?? false,
      onFinished: remove,
    ),
  );
  overlay.insert(entry);
}

final class _WeChatToastOverlay extends StatefulWidget {
  const _WeChatToastOverlay({
    required this.message,
    required this.semanticType,
    required this.duration,
    required this.reduceMotion,
    required this.onFinished,
  });

  final String message;
  final WeChatToastSemanticType semanticType;
  final Duration duration;
  final bool reduceMotion;
  final VoidCallback onFinished;

  @override
  State<_WeChatToastOverlay> createState() => _WeChatToastOverlayState();
}

final class _WeChatToastOverlayState extends State<_WeChatToastOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );
  Timer? _timer;
  var _finished = false;

  @override
  void initState() {
    super.initState();
    // 「减少动态效果」下直接呈现，不播放淡入淡出。
    if (widget.reduceMotion) {
      _fade.value = 1;
    } else {
      _fade.forward();
    }
    _timer = Timer(widget.duration, _finish);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    if (widget.reduceMotion) {
      widget.onFinished();
      return;
    }
    _fade.reverse().whenComplete(widget.onFinished);
  }

  @override
  Widget build(BuildContext context) => Positioned(
        left: 0,
        right: 0,
        bottom: MediaQuery.paddingOf(context).bottom + WeChatSpacing.xxl * 2,
        child: IgnorePointer(
          child: Center(
            child: FadeTransition(
              opacity: _fade,
              child: WeChatToast(
                  message: widget.message, semanticType: widget.semanticType),
            ),
          ),
        ),
      );
}

final class WeChatToast extends StatelessWidget {
  const WeChatToast(
      {super.key,
      required this.message,
      this.semanticType = WeChatToastSemanticType.info});
  final String message;
  final WeChatToastSemanticType semanticType;

  @override
  Widget build(BuildContext context) {
    final icon = switch (semanticType) {
      WeChatToastSemanticType.success => CupertinoIcons.check_mark_circled,
      WeChatToastSemanticType.error => CupertinoIcons.exclamationmark_circle,
      WeChatToastSemanticType.info => CupertinoIcons.info_circle,
    };
    return Semantics(
      liveRegion: true,
      label: message,
      child: DecoratedBox(
        decoration: BoxDecoration(
            color: WeChatColors.darkSurface,
            borderRadius: BorderRadius.circular(WeChatRadius.dialog)),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: WeChatSpacing.lg, vertical: WeChatSpacing.md),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                color: WeChatColors.darkTextPrimary,
                size: WeChatTypography.callout),
            const SizedBox(width: WeChatSpacing.sm),
            Text(message,
                style: const TextStyle(
                    color: WeChatColors.darkTextPrimary,
                    fontSize: WeChatTypography.subhead)),
          ]),
        ),
      ),
    );
  }
}
