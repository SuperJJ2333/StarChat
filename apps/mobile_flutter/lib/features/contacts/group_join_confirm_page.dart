import 'package:flutter/cupertino.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';

/// BUG2 扫码入群确认页：群安全摘要（群名/人数/是否需审批）+「加入群聊」
/// 显式确认；兑换（直加或提交审批）成功后回调打开会话。
final class GroupJoinConfirmPage extends StatefulWidget {
  const GroupJoinConfirmPage({
    super.key,
    required this.api,
    required this.token,
    this.onJoined,
  });

  final BusinessApiClient api;
  final String token;

  /// 加入成功回调（roomId）；组合根用于同步并打开会话。
  final void Function(String roomId)? onJoined;

  @override
  State<GroupJoinConfirmPage> createState() => _GroupJoinConfirmPageState();
}

final class _GroupJoinConfirmPageState extends State<GroupJoinConfirmPage> {
  Map<String, dynamic>? _info;
  String? _error;
  bool _loading = false;
  bool _joining = false;
  String? _resultMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await widget.api.groupJoinInfo(token: widget.token);
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(error);
        _loading = false;
      });
    }
  }

  /// 明确错误文案：过期/撤销/关闭/无效不互相混淆。
  String _friendlyError(Object error) {
    final message = error is BusinessApiException ? error.message : '';
    if (message.contains('过期')) return '二维码已过期，请联系群成员重新生成';
    if (message.contains('撤销')) return '二维码已被撤销';
    if (message.contains('关闭')) return '该群已关闭二维码进群';
    if (message.contains('无效')) return '二维码无效';
    return '二维码暂时无法使用，请稍后重试';
  }

  Future<void> _join() async {
    if (_joining) return;
    setState(() {
      _joining = true;
      _resultMessage = null;
    });
    try {
      final result = await widget.api.redeemGroupJoinToken(
        token: widget.token,
      );
      if (!mounted) return;
      final status = result['status']?.toString() ?? '';
      if (status == 'joined' || status == 'already_joined') {
        final roomId = result['room_id']?.toString();
        setState(() => _joining = false);
        widget.onJoined?.call(roomId ?? '');
        if (roomId != null && roomId.isNotEmpty && mounted) {
          Navigator.of(context).pop(true);
        }
        return;
      }
      if (status == 'pending_approval') {
        setState(() {
          _joining = false;
          _resultMessage = '已提交入群申请，等待群管理员确认';
        });
        return;
      }
      setState(() {
        _joining = false;
        _resultMessage = '已提交，请稍后查看';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _resultMessage = _friendlyError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: const CupertinoNavigationBar(middle: Text('加入群聊')),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_loading) ...[
                      const CupertinoActivityIndicator(),
                      const SizedBox(height: 12),
                      const Text('正在获取群信息…',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: WeChatColors.textSecondary)),
                    ] else if (_error != null) ...[
                      const Icon(CupertinoIcons.exclamationmark_triangle,
                          size: 44, color: CupertinoColors.systemOrange),
                      const SizedBox(height: 12),
                      Text(_error!,
                          key: const Key('group-join-error'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 15)),
                      const SizedBox(height: 16),
                      CupertinoButton(
                        key: const Key('group-join-retry'),
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    ] else ...[
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: WeChatColors.elevatedSurface(context),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: CupertinoColors.white,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: QrImageView(
                                data:
                                    'changliao://g/${widget.token}',
                                version: QrVersions.auto,
                                size: 64,
                                backgroundColor: CupertinoColors.white,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _info?['group_name']?.toString().trim().isEmpty ??
                                      true
                                  ? '畅聊群聊'
                                  : _info!['group_name'].toString().trim(),
                              key: const Key('group-join-name'),
                              style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${_info?['member_count'] ?? 0} 位成员',
                              key: const Key('group-join-count'),
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: WeChatColors.textSecondary),
                            ),
                            if (_info?['join_approval_required'] == true)
                              const Padding(
                                padding: EdgeInsets.only(top: 6),
                                child: Text(
                                  '该群需要管理员确认后加入',
                                  key: Key('group-join-approval-hint'),
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: WeChatColors.textTertiary),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (_resultMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            _resultMessage!,
                            key: const Key('group-join-result'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: WeChatColors.textSecondary,
                                fontSize: 13),
                          ),
                        ),
                      CupertinoButton(
                        key: const Key('group-join-confirm'),
                        color: WeChatColors.brandPrimary,
                        borderRadius: BorderRadius.circular(10),
                        onPressed: _joining ? null : () => _join(),
                        child: _joining
                            ? const CupertinoActivityIndicator(
                                color: CupertinoColors.white)
                            : const Text('加入群聊',
                                style: TextStyle(
                                    color: CupertinoColors.white)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
