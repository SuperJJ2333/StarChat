import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'group_chat_info_controller.dart';

/// BUG2 群二维码实装：
/// - 从服务端签发的安全令牌生成真实二维码（`changliao://g/<token>`，
///   默认 7 天过期、可撤销；绝不是 Matrix 房间 ID）；
/// - 群开启「二维码进群」才可签发/展示；关闭态明确提示；
/// - 「刷新二维码」= 新签发 + 撤销旧令牌（轮换，旧码立即失效）；
/// - 无权限（非群主/管理员）或服务端失败给明确错误，不显示假码。
final class GroupQrCodePage extends StatefulWidget {
  const GroupQrCodePage({
    super.key,
    required this.snapshot,
    required this.api,
  });

  final GroupChatInfoSnapshot snapshot;
  final BusinessApiClient? api;

  @override
  State<GroupQrCodePage> createState() => _GroupQrCodePageState();
}

final class _GroupQrCodePageState extends State<GroupQrCodePage> {
  String? _payload;
  String? _expiresAt;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.snapshot.qrJoinEnabled && widget.snapshot.canManage) {
      unawaited(_issue());
    }
  }

  Future<void> _issue() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.api!
          .issueGroupJoinToken(roomId: widget.snapshot.roomId ?? '');
      if (!mounted) return;
      setState(() {
        _payload = response['token_payload']?.toString();
        _expiresAt = response['expires_at']?.toString();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '二维码生成失败，请稍后重试';
        _loading = false;
      });
    }
  }

  /// 轮换 = 新签发 + 撤销旧令牌（旧码立即失效）。
  Future<void> _refresh() async {
    final oldPayload = _payload;
    if (oldPayload != null) {
      final token =
          oldPayload.contains('://g/') ? oldPayload.split('://g/').last : '';
      if (token.isNotEmpty) {
        try {
          await widget.api!.revokeGroupJoinToken(token: token);
        } catch (_) {
          // 撤销失败仍继续签发新令牌；旧码在过期/下次轮换时失效。
        }
      }
    }
    await _issue();
  }

  String _computeExpiry() {
    final raw = _expiresAt;
    if (raw == null || raw.isEmpty) return '';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return '';
    final local = parsed.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '有效期至 ${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            backgroundColor: WeChatColors.chatNavigationBackground,
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: const Text('群二维码'),
            trailing: widget.snapshot.qrJoinEnabled && widget.snapshot.canManage
                ? CupertinoButton(
                    key: const Key('group-qr-refresh'),
                    padding: EdgeInsets.zero,
                    onPressed: _loading ? null : () => unawaited(_refresh()),
                    child: const Text('刷新'),
                  )
                : null),
        child: SafeArea(
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                groupInfoDisplayName(widget.snapshot.name),
                style: const TextStyle(fontSize: 17),
              ),
              const SizedBox(height: 20),
              if (!widget.snapshot.qrJoinEnabled) ...[
                const Icon(CupertinoIcons.qrcode, size: 150,
                    color: WeChatColors.textTertiary),
                const SizedBox(height: 12),
                const Text('群二维码已关闭',
                    style:
                        TextStyle(color: WeChatColors.textSecondary)),
                const SizedBox(height: 6),
                const Text('可在 群管理 → 二维码进群 中开启',
                    style: TextStyle(
                        fontSize: 12, color: WeChatColors.textTertiary)),
              ] else if (!widget.snapshot.canManage) ...[
                const Icon(CupertinoIcons.qrcode, size: 150,
                    color: WeChatColors.textTertiary),
                const SizedBox(height: 12),
                const Text('仅群主和管理员可生成群二维码',
                    style:
                        TextStyle(color: WeChatColors.textSecondary)),
              ] else if (_loading) ...[
                const CupertinoActivityIndicator(),
                const SizedBox(height: 12),
                const Text('正在生成二维码…',
                    style:
                        TextStyle(color: WeChatColors.textSecondary)),
              ] else if (_error != null) ...[
                Text(_error!,
                    style: const TextStyle(color: CupertinoColors.systemRed)),
                const SizedBox(height: 12),
                CupertinoButton(
                  key: const Key('group-qr-retry'),
                  onPressed: () => unawaited(_issue()),
                  child: const Text('重试'),
                ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: CupertinoColors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    key: const Key('group-qr-image'),
                    data: _payload ?? '',
                    version: QrVersions.auto,
                    size: 220,
                    backgroundColor: CupertinoColors.white,
                  ),
                ),
                const SizedBox(height: 12),
                const Text('扫描二维码加入群聊',
                    style:
                        TextStyle(color: WeChatColors.textSecondary)),
                if (_computeExpiry().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _computeExpiry(),
                      key: const Key('group-qr-expiry'),
                      style: const TextStyle(
                          fontSize: 12, color: WeChatColors.textTertiary),
                    ),
                  ),
              ],
            ]),
          ),
        ),
      );
}
