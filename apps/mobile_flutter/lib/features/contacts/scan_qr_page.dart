import 'package:flutter/cupertino.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../ui/components/wechat_nav_title.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'contact_models.dart';
import 'friend_qr.dart';
import 'request_friend_page.dart';
import '../../core/notification/notification_feedback.dart';
import '../../core/notification/sound_type.dart';

/// 「扫一扫」页（微信式）：识别好友二维码 → 进入「申请添加朋友」页。
///
/// 安全与交互约定（需求）：扫码**只做识别与跳转**，绝不会自动发送好友
/// 请求；只有用户在申请页内手动点「发送」才发起 request。
final class ScanQrPage extends StatefulWidget {
  const ScanQrPage({super.key, required this.api});

  final AddFriendGateway api;

  @override
  State<ScanQrPage> createState() => _ScanQrPageState();
}

final class _ScanQrPageState extends State<ScanQrPage> {
  MobileScannerController? _controller;
  bool _handling = false;
  String? hint;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling || !mounted) return;
    final raw =
        capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
    if (raw == null || raw.isEmpty) return;
    // 扫码识别音：纯前台 UI 反馈。
    NotificationFeedback.shared.play(SoundType.scan);
    final username = parseFriendQrPayload(raw);
    if (username == null) {
      setState(() => hint = '这不是畅聊好友二维码');
      return;
    }
    _handling = true;
    setState(() => hint = '正在识别好友信息…');
    try {
      final response = await widget.api.searchUsers(username);
      final items = (response['items'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      if (!mounted) return;
      final match = items.firstWhere(
        (item) => item['username']?.toString() == username,
        orElse: () => items.isEmpty ? <String, dynamic>{} : items.first,
      );
      if (match.isEmpty || match['user_id'] == null) {
        setState(() {
          hint = '未找到该好友，请确认二维码有效';
          _handling = false;
        });
        return;
      }
      // 识别成功：预填用户信息进入「申请添加朋友」页（不自动发送）。
      await Navigator.of(context, rootNavigator: true).push(
        CupertinoPageRoute(
          fullscreenDialog: true,
          builder: (_) => RequestFriendPage(
            api: widget.api,
            userId: match['user_id']!.toString(),
            username: match['username']?.toString() ?? username,
            nickname: match['nickname']?.toString() ?? username,
            avatarUrl: match['avatar_url']?.toString(),
          ),
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          hint = '识别失败，请重试';
          _handling = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 相册/手电筒等扩展暂不开放；保持与微信一致的极简扫一扫。
    _controller ??= MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
    );
    return WeChatPageScaffold.navigation(
      backgroundColor: CupertinoColors.black,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.black,
        middle: const WeChatNavTitle('扫一扫'),
        transitionBetweenRoutes: false,
      ),
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: MobileScanner(
                controller: _controller,
                onDetect: _onDetect,
                errorBuilder: (context, error, child) => const Center(
                  child: Padding(
                    key: Key('scan-camera-error'),
                    padding: EdgeInsets.all(32),
                    child: Text(
                      '无法启动相机，请检查相机权限后重试',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: CupertinoColors.systemGrey, fontSize: 14),
                    ),
                  ),
                ),
              ),
            ),
            // 取景框：中央 240×240 方框。
            Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border:
                      Border.all(color: WeChatColors.brandPrimary, width: 1.5),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 48,
              child: Column(
                children: [
                  Text(
                    '对准好友的二维码，即可加为朋友',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13,
                        color: CupertinoColors.white.withValues(alpha: .85)),
                  ),
                  if (hint != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      key: const Key('scan-hint'),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: CupertinoColors.black.withValues(alpha: .65),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(hint!,
                          style: const TextStyle(
                              fontSize: 12,
                              color: CupertinoColors.systemGrey5)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
