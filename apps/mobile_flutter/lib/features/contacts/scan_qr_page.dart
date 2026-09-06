import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';

import '../../ui/components/wechat_nav_title.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'contact_models.dart';
import 'friend_qr.dart';
import 'group_qr.dart';
import 'group_join_confirm_page.dart';
import 'request_friend_page.dart';
import '../../core/business_api_client.dart';
import '../../core/notification/notification_feedback.dart';
import '../../core/notification/sound_type.dart';
import '../matrix/image_picker_page.dart';
import '../profile/profile_controller.dart';
import '../profile/my_qr_code_page.dart';

/// 「扫一扫」页（微信式）：识别好友二维码 → 进入「申请添加朋友」页。
///
/// 安全与交互约定（需求）：扫码**只做识别与跳转**，绝不会自动发送好友
/// 请求；只有用户在申请页内手动点「发送」才发起 request。
final class ScanQrPage extends StatefulWidget {
  const ScanQrPage({
    super.key,
    required this.api,
    this.groupJoinApi,
    this.onGroupJoined,
  });

  final AddFriendGateway api;

  /// 群码兑换所需的完整业务客户端（null = 群码不可用，提示并忽略）。
  final BusinessApiClient? groupJoinApi;

  /// 群码加入成功回调（roomId）：组合根同步并打开会话。
  final void Function(String roomId)? onGroupJoined;

  @override
  State<ScanQrPage> createState() => _ScanQrPageState();
}

final class _ScanQrPageState extends State<ScanQrPage>
    with WidgetsBindingObserver {
  MobileScannerController? _controller;
  bool _handling = false;
  String? hint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_resumeCamera());
    } else {
      unawaited(_pauseCamera());
    }
  }

  Future<void> _pauseCamera() async {
    try {
      await _controller?.stop();
    } catch (_) {/* Gallery remains available without a camera. */}
  }

  void _guardCameraRoute() {
    if (!mounted || _controller?.value.isRunning != true) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (_handling ||
        ModalRoute.of(context)?.isCurrent != true ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      unawaited(_pauseCamera());
    }
  }

  Future<void> _resumeCamera() async {
    if (!mounted || _handling || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    try {
      await _controller?.start();
    } catch (_) {/* Camera widget displays its permission/error state. */}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.removeListener(_guardCameraRoute);
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling || !mounted) return;
    final raw = _payloadOf(capture);
    if (raw == null || raw.isEmpty) return;
    await _handlePayload(raw);
  }

  String? _payloadOf(BarcodeCapture capture) {
    final values = capture.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toList();
    for (final value in values) {
      if (parseGroupQrPayload(value) != null ||
          parseFriendQrPayload(value) != null) {
        return value;
      }
    }
    return values.isEmpty ? null : values.first;
  }

  Future<void> _handlePayload(String raw) async {
    if (_handling || !mounted) return;
    setState(() => _handling = true);
    await _pauseCamera();
    try {
      await _resolvePayload(raw);
    } finally {
      if (mounted) {
        setState(() => _handling = false);
        await _resumeCamera();
      }
    }
  }

  Future<void> _resolvePayload(String raw) async {
    if (!mounted) return;
    // 扫码识别音：纯前台 UI 反馈。
    NotificationFeedback.shared.play(SoundType.scan);
    // BUG2 分流：群码优先（changliao://g/）→ 群资料确认页；
    // 好友码（changliao://u/）→ 申请添加朋友页（原有行为不变）。
    final groupToken = parseGroupQrPayload(raw);
    if (groupToken != null) {
      await _openGroupJoin(groupToken);
      return;
    }
    final username = parseFriendQrPayload(raw);
    if (username == null) {
      setState(() => hint = '这不是畅聊二维码');
      return;
    }
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
        });
      }
    }
  }

  Future<void> _openGroupJoin(String token) async {
    final api = widget.groupJoinApi;
    if (api == null) {
      setState(() => hint = '当前环境暂不支持扫码入群');
      return;
    }
    await Navigator.of(context, rootNavigator: true).push(
      CupertinoPageRoute(
        fullscreenDialog: true,
        builder: (_) => GroupJoinConfirmPage(
          api: api,
          token: token,
          onJoined: widget.onGroupJoined,
        ),
      ),
    );
  }

  Future<void> _openMyQr() async {
    if (_handling) return;
    setState(() {
      _handling = true;
      hint = null;
    });
    await _pauseCamera();
    try {
      final gateway = widget.api;
      if (gateway is! ProfileGateway) throw StateError('Profile unavailable');
      final profile = await (gateway as ProfileGateway).loadProfile();
      if (!mounted) return;
      await Navigator.of(context, rootNavigator: true).push(CupertinoPageRoute(
        builder: (_) => MyQrCodePage(profile: profile),
      ));
    } catch (_) {
      if (mounted) setState(() => hint = '个人二维码加载失败，请重试');
    } finally {
      if (mounted) {
        setState(() => _handling = false);
        await _resumeCamera();
      }
    }
  }

  Future<void> _openGallery() async {
    if (_handling) return;
    setState(() {
      _handling = true;
      hint = null;
    });
    await _pauseCamera();
    try {
      if (!mounted) return;
      final picked = await Navigator.of(context, rootNavigator: true)
          .push<({List<GalleryPhoto> photos, bool original})>(
        CupertinoPageRoute(
            builder: (_) => const ImagePickerPage(
                  photosOnly: true,
                  maxCount: 1,
                  confirmLabel: '识别',
                  showOriginalToggle: false,
                )),
      );
      if (!mounted || picked == null || picked.photos.isEmpty) return;
      final photo = picked.photos.single;
      if (photo.isVideo) throw StateError('Only photos can be scanned');
      final directory =
          await (await getTemporaryDirectory()).createTemp('chatflow-qr-');
      BarcodeCapture? capture;
      try {
        final file = File('${directory.path}/scan-image');
        await file.writeAsBytes(await photo.originalBytes(), flush: true);
        if (!mounted) return;
        capture = await _controller!.analyzeImage(file.path);
      } finally {
        await directory.delete(recursive: true);
      }
      if (!mounted) return;
      final payload = capture == null ? null : _payloadOf(capture);
      if (payload == null) {
        setState(() => hint = '未在所选照片中识别到二维码，请更换照片');
      } else {
        await _resolvePayload(payload);
      }
    } catch (_) {
      if (mounted) setState(() => hint = '照片识别失败，请重试');
    } finally {
      if (mounted) {
        setState(() => _handling = false);
        await _resumeCamera();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _controller ??= MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
    )..addListener(_guardCameraRoute);
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
              bottom: 16,
              child: Column(
                children: [
                  Text(
                    '对准二维码，可加好友或加入群聊',
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
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _action('scan-my-qr', CupertinoIcons.qrcode, '我的二维码',
                          _openMyQr),
                      _action('scan-gallery', CupertinoIcons.photo_on_rectangle,
                          '图库', _openGallery),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _action(String key, IconData icon, String label, VoidCallback onTap) =>
      CupertinoButton(
        key: Key(key),
        onPressed: _handling ? null : onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 28, color: CupertinoColors.white),
          const SizedBox(height: 8),
          Text(label,
              style:
                  const TextStyle(fontSize: 13, color: CupertinoColors.white)),
        ]),
      );
}
