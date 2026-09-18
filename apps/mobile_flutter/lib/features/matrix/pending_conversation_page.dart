import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

import '../../core/network_state_manager.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../contacts/contact_models.dart';
import 'direct_chat_controller.dart';
import 'direct_chat_failure.dart';

/// 结果：房间就绪时把 roomId 与 pending 期间输入的消息交回组合根。
///
/// 组合根（AppHome）负责 pop 本页后按既有 `RoomNavigationCoordinator` 流程
/// 打开 RoomPage，并把 [queued] 作为初始 outbox 交给页面自动发送。
final class PendingConversationResult {
  const PendingConversationResult({required this.roomId, required this.queued});

  final String roomId;

  /// 用户在等待期间输入、尚未发送的文本（保持输入顺序）。
  final List<String> queued;
}

/// **Pending conversation**（Offline First 第三步）。
///
/// 当好友会话在本地不存在时，用户**立即**进入本页，而不是等一次网络仲裁：
/// - 页面展示好友身份、当前网络状态与后台建立会话的进度；
/// - 输入的消息进入本地队列并显示“等待发送”；
/// - 后台 `openRoom()` 拿到真实房间号后立即把结果交回组合根 → RoomPage，
///   队列消息随初始 outbox 自动发送（弱网/无网时由消息状态机继续等待网络）。
///
/// 本页**不做任何网络读写**（除 `openRoom` 注入的后台委托），不持有 RoomLease，
/// 也不构造 RoomPage（架构守卫要求 RoomPage 只在 `app_home.dart` 构造）。
final class PendingConversationPage extends StatefulWidget {
  const PendingConversationPage({
    super.key,
    required this.contact,
    required this.openRoom,
    this.networkState,
    this.onFailure,
  });

  /// 权威好友（业务 userId 已解析、matrixUserId 有效）。
  final ContactDetails contact;

  /// 后台建立/查找真实 Matrix 房间；可被“重试”再次调用。
  final Future<DirectChatRoom> Function() openRoom;

  /// 统一网络状态（可空：测试与无网环境）。
  final ValueListenable<NetworkState>? networkState;

  /// 失败时的可见反馈（默认用会话失败分类文案内联展示）。
  final void Function(Object error)? onFailure;

  @override
  State<PendingConversationPage> createState() => _PendingConversationPageState();
}

final class _PendingConversationPageState extends State<PendingConversationPage> {
  final _queued = <String>[];
  final _input = TextEditingController();
  Object? _error;
  bool _opening = false;
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    widget.networkState?.addListener(_onNetworkChanged);
    _start();
  }

  @override
  void dispose() {
    widget.networkState?.removeListener(_onNetworkChanged);
    _input.dispose();
    super.dispose();
  }

  void _onNetworkChanged() {
    if (mounted) setState(() {});
  }

  /// 后台建立会话。**绝不阻塞首帧**：本页已经可见，进度只体现在状态文案上。
  void _start() {
    if (_opening) return;
    _opening = true;
    unawaited(widget.openRoom().then<void>((room) {
      if (!mounted || _settled) return;
      if (room.roomId.trim().isEmpty) {
        setState(() {
          _opening = false;
          _error = StateError('规范私聊成员或加密状态尚未就绪');
        });
        return;
      }
      _settled = true;
      Navigator.of(context).pop(
        PendingConversationResult(roomId: room.roomId.trim(), queued: List.of(_queued)),
      );
    }, onError: (Object error, StackTrace stackTrace) {
      if (!mounted) return;
      widget.onFailure?.call(error);
      setState(() {
        _opening = false;
        _error = error;
      });
    }));
  }

  String get _statusLabel {
    if (_error != null) return describeDirectChatFailure(_error);
    final state = widget.networkState?.value;
    return switch (state) {
      NetworkState.offline => '当前没有网络，消息将在恢复后同步。',
      NetworkState.weak => '网络不稳定，正在建立加密会话…',
      NetworkState.recovering => '正在建立加密会话…',
      NetworkState.online => '正在建立加密会话…',
      null => '正在建立加密会话…',
    };
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _queued.add(text);
      _input.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.contact.displayName;
    return WeChatPageScaffold(
      title: name,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Icon(
                    _error == null
                        ? CupertinoIcons.clock
                        : CupertinoIcons.exclamationmark_circle,
                    size: 16,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _statusLabel,
                      key: const Key('pending-conversation-status'),
                      style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                            fontSize: 13,
                            color: CupertinoColors.secondaryLabel.resolveFrom(context),
                          ),
                    ),
                  ),
                  if (_error != null)
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      onPressed: () {
                        setState(() => _error = null);
                        _start();
                      },
                      child: const Text('重试'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                children: [
                  for (final text in _queued.reversed)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemGreen.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(text),
                            const SizedBox(height: 2),
                            Text(
                              '等待发送',
                              style: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .copyWith(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: CupertinoTextField(
                      key: const Key('composer-input'),
                      controller: _input,
                      placeholder: '发消息…',
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CupertinoButton(
                    key: const Key('composer-send'),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    color: CupertinoColors.systemGreen,
                    onPressed: _send,
                    child: const Text('发送'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
