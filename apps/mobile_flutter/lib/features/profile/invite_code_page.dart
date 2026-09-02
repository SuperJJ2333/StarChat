import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ui/components/wechat_nav_title.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'invite_controller.dart';

/// 邀请码页（“我”→ 邀请码）：
/// - 展示当前用户专属邀请码，30 分钟窗口倒计时，到点自动同步新码；
/// - 分享：复制邀请码 / 复制邀请链接 / 保存分享图片 / 跳转微信 / 跳转 QQ；
///   未安装对应应用时回退为“已复制邀请码”，可直接粘贴发送；
/// - 好友注册时填写此码即建立邀请关系。
final class InviteCodePage extends StatefulWidget {
  const InviteCodePage({super.key, required this.controller});

  final InviteCodeController controller;

  @override
  State<InviteCodePage> createState() => _InviteCodePageState();
}

final class _InviteCodePageState extends State<InviteCodePage> {
  final _shareCardKey = GlobalKey();
  Timer? _messageTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    if (widget.controller.state.status == InviteCodeStatus.idle) {
      widget.controller.load();
    }
  }

  @override
  void didUpdateWidget(covariant InviteCodePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// 页面级轻提示（3 秒自动消失）。
  void _toast(String message) {
    _messageTimer?.cancel();
    widget.controller.showMessage(message);
    _messageTimer = Timer(const Duration(seconds: 3), () {
      widget.controller.clearMessage();
    });
  }

  Future<void> _copy(String label, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _toast('$label已复制');
  }

  /// 生成分享图片（邀请码卡片渲染为 PNG）并保存到系统相册。
  Future<void> _saveShareImage() async {
    try {
      final boundary = _shareCardKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 3);
      final data =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw StateError('share image capture failed');
      final result = await PhotoManager.editor.saveImage(
        data.buffer.asUint8List(),
        filename:
            'changliao-invite-${DateTime.now().millisecondsSinceEpoch}.png',
      );
      _toast(result.id.isNotEmpty ? '分享图片已保存到相册' : '保存失败，请检查相册权限');
    } catch (_) {
      _toast('保存失败，请检查相册权限');
    }
  }

  /// 跳转微信/QQ（复制邀请码后调起）；未安装时提示直接粘贴发送。
  Future<void> _openExternalApp(String scheme, String appName) async {
    final invite = widget.controller.state.invite;
    if (invite == null) return;
    await Clipboard.setData(ClipboardData(text: invite.code));
    try {
      final launched = await launchUrl(
        Uri.parse(scheme),
        mode: LaunchMode.externalApplication,
      );
      if (launched) {
        _toast('已复制邀请码，去$appName粘贴给好友吧');
        return;
      }
    } catch (_) {
      // 未安装或无法调起：走下方兜底提示。
    }
    _toast('未找到$appName，邀请码已复制，可直接粘贴发送');
  }

  String _formatCountdown(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final state = widget.controller.state;
    return WeChatPageScaffold.navigation(
      backgroundColor:
          dark ? WeChatColors.darkPageBackground : WeChatColors.lightPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.chatNavigationBackground,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: const WeChatNavTitle('邀请码'),
        trailing: state.status == InviteCodeStatus.ready
            ? CupertinoButton(
                key: const Key('invite-refresh'),
                padding: EdgeInsets.zero,
                onPressed: widget.controller.load,
                child: const Icon(CupertinoIcons.refresh,
                    size: 20, color: WeChatColors.brandPrimary),
              )
            : null,
      ),
      child: SafeArea(
        child: switch (state.status) {
          InviteCodeStatus.idle ||
          InviteCodeStatus.loading =>
            const Center(child: CupertinoActivityIndicator()),
          InviteCodeStatus.failed => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(state.message ?? '邀请码加载失败，请重试',
                      style: const TextStyle(
                          fontSize: 13, color: WeChatColors.textSecondary)),
                  const SizedBox(height: 12),
                  CupertinoButton(
                    onPressed: widget.controller.load,
                    child: const Text('重试',
                        style: TextStyle(color: WeChatColors.brandPrimary)),
                  ),
                ],
              ),
            ),
          InviteCodeStatus.ready => _body(context, state),
        },
      ),
    );
  }

  Widget _body(BuildContext context, InviteCodeState state) {
    final invite = state.invite!;
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return Stack(
      children: [
        ListView(
          key: const Key('invite-code-list'),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            _shareCard(context, invite, state, dark),
            const SizedBox(height: 12),
            CupertinoListSection.insetGrouped(
              backgroundColor: dark
                  ? WeChatColors.darkPageBackground
                  : WeChatColors.lightPageBackground,
              header: const Text('分享给好友'),
              children: [
                _actionTile(
                  key: const Key('invite-copy-code'),
                  icon: CupertinoIcons.doc_on_doc,
                  label: '复制邀请码',
                  onTap: () => _copy('邀请码', invite.code),
                ),
                _actionTile(
                  key: const Key('invite-copy-link'),
                  icon: CupertinoIcons.link,
                  label: '复制邀请链接',
                  onTap: () => _copy('邀请链接', invite.shareUrl),
                ),
                _actionTile(
                  key: const Key('invite-save-image'),
                  icon: CupertinoIcons.photo,
                  label: '保存分享图片',
                  onTap: _saveShareImage,
                ),
                _actionTile(
                  key: const Key('invite-wechat'),
                  icon: CupertinoIcons.chat_bubble_2,
                  label: '微信',
                  onTap: () => _openExternalApp('weixin://', '微信'),
                ),
                _actionTile(
                  key: const Key('invite-qq'),
                  icon: CupertinoIcons.chat_bubble,
                  label: 'QQ',
                  onTap: () => _openExternalApp('mqq://', 'QQ'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                '好友注册时填写你的邀请码，即可完成邀请关系绑定。'
                '为保障账号安全，邀请码每 30 分钟自动更换，旧码立即失效。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: dark
                      ? WeChatColors.textSecondary
                      : WeChatColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
        if (state.message != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(
              child: Container(
                key: const Key('invite-toast'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: CupertinoColors.systemGrey6.withValues(alpha: .95),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(state.message!,
                    style: const TextStyle(
                        fontSize: 13,
                        color: CupertinoColors.black)),
              ),
            ),
          ),
      ],
    );
  }

  /// 邀请码卡片（被 [RepaintBoundary] 包裹：分享图片直接渲染此卡片）。
  Widget _shareCard(
      BuildContext context, ReferralInvite invite, InviteCodeState state, bool dark) {
    final foreground =
        dark ? WeChatColors.darkTextPrimary : WeChatColors.lightTextPrimary;
    return RepaintBoundary(
      key: _shareCardKey,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        decoration: BoxDecoration(
          color: dark ? WeChatColors.darkElevated : WeChatColors.lightElevated,
          borderRadius: BorderRadius.circular(WeChatRadius.dialog),
        ),
        child: Column(
          children: [
            Text('我的邀请码',
                style: TextStyle(
                    fontSize: 14,
                    color: dark
                        ? WeChatColors.textSecondary
                        : WeChatColors.textSecondary)),
            const SizedBox(height: 14),
            Text(
              invite.code,
              key: const Key('invite-code-value'),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 34,
                letterSpacing: 10,
                fontWeight: FontWeight.w700,
                color: foreground,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CupertinoIcons.timer,
                    size: 13,
                    color: dark
                        ? WeChatColors.textSecondary
                        : WeChatColors.textSecondary),
                const SizedBox(width: 5),
                Text(
                  '${_formatCountdown(state.remainingSeconds)} 后自动更新',
                  key: const Key('invite-countdown'),
                  style: TextStyle(
                      fontSize: 12,
                      color: dark
                          ? WeChatColors.textSecondary
                          : WeChatColors.textSecondary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionTile({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final foreground =
        dark ? WeChatColors.darkTextPrimary : WeChatColors.lightTextPrimary;
    return CupertinoButton(
      key: key,
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        height: 52,
        child: Row(
          children: [
            Icon(icon, size: 21, color: WeChatColors.brandPrimary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 16, color: foreground)),
            ),
            const Icon(CupertinoIcons.chevron_right,
                size: 12, color: WeChatColors.textSecondary),
          ],
        ),
      ),
    );
  }
}
