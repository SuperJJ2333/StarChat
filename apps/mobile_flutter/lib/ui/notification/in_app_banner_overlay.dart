import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../core/notification/in_app_banner_controller.dart';
import '../foundation/wechat_tokens.dart';

/// 应用内顶部通知横幅（PRD §7）。
///
/// 安全区域下方、左右 12px、高约 68、圆角 14；进入动效
/// Y-20→0 + 淡入 200ms，退出淡出 150ms；默认停留 3 秒；
/// 点击进入会话。头像未缓存时先显示占位（PRD §23/§48）。
final class InAppBannerOverlay extends StatefulWidget {
  const InAppBannerOverlay({
    super.key,
    required this.controller,
    required this.onOpenConversation,
    this.displayDuration = const Duration(seconds: 3),
  });

  final InAppBannerController controller;
  final void Function(String conversationId) onOpenConversation;
  final Duration displayDuration;

  @override
  State<InAppBannerOverlay> createState() => _InAppBannerOverlayState();
}

final class _InAppBannerOverlayState extends State<InAppBannerOverlay> {
  Timer? _autoDismiss;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    _cancelAutoDismiss();
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    _cancelAutoDismiss();
    if (widget.controller.current != null) {
      _autoDismiss = Timer(widget.displayDuration, () {
        if (mounted) widget.controller.dismissCurrent();
      });
    }
    setState(() {});
  }

  void _cancelAutoDismiss() {
    _autoDismiss?.cancel();
    _autoDismiss = null;
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          reverseDuration: const Duration(milliseconds: 150),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -0.35),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: _buildBanner(),
        ),
      ),
    );
  }

  Widget? _buildBanner() {
    final item = widget.controller.current;
    if (item == null) return null;
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      key: ValueKey(item.id),
      onTap: () {
        widget.controller.dismissCurrent();
        widget.onOpenConversation(item.conversationId);
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: const BoxConstraints(minHeight: 56),
        decoration: BoxDecoration(
          color: dark ? WeChatColors.darkElevated : CupertinoColors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: const Color(0x1A000000),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            _AvatarPlaceholder(name: item.title),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color:
                          dark ? CupertinoColors.white : CupertinoColors.black,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: dark
                          ? CupertinoColors.systemGrey5
                          : CupertinoColors.systemGrey,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '现在',
              style: TextStyle(
                fontSize: 12,
                color: dark
                    ? CupertinoColors.systemGrey5
                    : CupertinoColors.systemGrey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 占位头像：头像未缓存时先以首字符呈现，缓存就绪后由调用方无感替换
/// （PRD §23：不得为等头像延迟通知显示）。
final class _AvatarPlaceholder extends StatelessWidget {
  const _AvatarPlaceholder({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().characters.firstOrNull ?? '聊';
    return Container(
      width: 38,
      height: 38,
      decoration: const BoxDecoration(
        color: WeChatColors.brandPrimary,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          color: CupertinoColors.white,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
