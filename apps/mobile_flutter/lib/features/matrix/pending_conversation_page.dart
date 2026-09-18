import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

import '../../core/network_state_manager.dart';
import '../../core/outbox/outbox_message.dart';
import '../../core/outbox/outbox_recovery_service.dart';
import '../../core/outbox/outbox_store.dart';
import '../../core/outbox/persistent_outbox_manager.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../contacts/contact_models.dart';
import 'direct_chat_controller.dart';
import 'direct_chat_failure.dart';

/// 结果：房间就绪时把 roomId 与 pending 期间输入的消息交回组合根。
///
/// 组合根（AppHome）负责 pop 本页后按既有 `RoomNavigationCoordinator` 流程
/// 打开 RoomPage，并把 [queued] 作为初始 outbox 交给页面自动发送。
final class PendingConversationResult {
  const PendingConversationResult({
    required this.roomId,
    required this.queued,
    this.outboxLocalIds = const <String>[],
  });

  final String roomId;

  /// 用户在等待期间输入、尚未发送的文本（保持输入顺序）。
  ///
  /// 只用于**降级路径**：正文已经落盘为 outbox 行时，RoomPage 按内容抵扣，
  /// 不会再发一次。
  final List<String> queued;

  /// 本页写入 outbox 的本地行 ID（测试与诊断可见）。
  final List<String> outboxLocalIds;
}

/// **Pending conversation**（Offline First 第三步）。
///
/// 当好友会话在本地不存在时，用户**立即**进入本页，而不是等一次网络仲裁：
/// - 页面展示好友身份、当前网络状态与后台建立会话的进度；
/// - 输入的消息**立刻写入持久化 outbox**（不依赖页面生命周期），显示“等待发送”；
/// - 后台 `openRoom()` 拿到真实房间号后，把房间号绑定到该接收方所有还没有
///   房间号的 outbox 行，再交回组合根 → RoomPage，由发送状态机继续派发
///   （弱网/无网时保持“等待网络”，恢复后自动重试）。
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
    this.outbox,
    this.recovery,
  });

  /// 权威好友（业务 userId 已解析、matrixUserId 有效）。
  final ContactDetails contact;

  /// 后台建立/查找真实 Matrix 房间；可被“重试”再次调用。
  final Future<DirectChatRoom> Function() openRoom;

  /// 统一网络状态（可空：测试与无网环境）。
  final ValueListenable<NetworkState>? networkState;

  /// 失败时的可见反馈（默认用会话失败分类文案内联展示）。
  final void Function(Object error)? onFailure;

  /// 持久化 outbox 管理器；为空时回退 [PersistentOutboxManager.shared]，
  /// 两者都为空时退化为页内内存队列（测试/无持久层环境）。
  final PersistentOutboxManager? outbox;

  /// 启动/恢复服务：房间建立后用它把行绑定房间号并立即尝试派发。
  final OutboxRecoveryService? recovery;

  @override
  State<PendingConversationPage> createState() => _PendingConversationPageState();
}

final class _PendingConversationPageState extends State<PendingConversationPage> {
  final _input = TextEditingController();

  /// 展示用行（权威来自持久化 outbox；乐观插入先行避免输入闪烁）。
  final _rows = <OutboxMessage>[];
  late final PersistentOutboxManager _outbox;
  bool _ownsOutbox = false;
  Object? _error;
  bool _opening = false;
  bool _settled = false;

  String get _receiverId => widget.contact.matrixUserId.trim();

  @override
  void initState() {
    super.initState();
    final injected = widget.outbox ?? PersistentOutboxManager.shared;
    _ownsOutbox = injected == null;
    // 没有可用持久层时退化为页内内存队列：至少保持本页语义一致
    // （真正的持久化由组合根注入 shared 实例保证）。
    _outbox = injected ?? PersistentOutboxManager(InMemoryOutboxStore());
    _outbox.addListener(_onOutboxChanged);
    widget.networkState?.addListener(_onNetworkChanged);
    unawaited(_reloadRows());
    _start();
  }

  @override
  void dispose() {
    _outbox.removeListener(_onOutboxChanged);
    if (_ownsOutbox) _outbox.dispose();
    widget.networkState?.removeListener(_onNetworkChanged);
    _input.dispose();
    super.dispose();
  }

  void _onOutboxChanged() {
    if (mounted) unawaited(_reloadRows());
  }

  Future<void> _reloadRows() async {
    List<OutboxMessage> rows;
    try {
      rows = await _outbox.store.query(
        unsent: true,
        receiverId: _receiverId,
        accountId: _outbox.accountId.isEmpty ? null : _outbox.accountId,
      );
    } catch (_) {
      // 持久层暂时不可用：保留当前展示（乐观行还在），不抛到 Zone 之外。
      return;
    }
    if (!mounted) return;
    setState(() {
      _rows
        ..clear()
        ..addAll(rows);
    });
  }

  void _onNetworkChanged() {
    if (mounted) setState(() {});
  }

  /// 后台建立会话。**绝不阻塞首帧**：本页已经可见，进度只体现在状态文案上。
  void _start() {
    if (_opening) return;
    _opening = true;
    unawaited(widget.openRoom().then<void>((room) async {
      if (!mounted || _settled) return;
      if (room.roomId.trim().isEmpty) {
        setState(() {
          _opening = false;
          _error = StateError('规范私聊成员或加密状态尚未就绪');
        });
        return;
      }
      _settled = true;
      final roomId = room.roomId.trim();
      // 房间号绑定到该接收方**所有**还没有房间号的行（含上一次进程留下的），
      // 这样"离线输入 → 杀进程 → 重开 → 建会话"也能续发。
      //
      // 刻意**不 await**：进入会话不能被本地写盘拖住。绑定本身是幂等的，
      // RoomPage 打开时还会再绑一次（同一个接收方 → 同一个房间号），
      // 因此不依赖这里的完成顺序。
      unawaited(_bindRoomAndResume(roomId));
      Navigator.of(context).pop(
        PendingConversationResult(
          roomId: roomId,
          queued: List.of(_queuedTexts),
          outboxLocalIds: [for (final row in _rows) row.localId],
        ),
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

  List<String> get _queuedTexts =>
      [for (final row in _rows) row.content];

  /// 房间就绪后的收尾：绑定房间号 + 让恢复服务立刻尝试派发。
  ///
  /// 只在后台跑（页面随即 pop）；[OutboxRecoveryService.resumeRoom] 会再做
  /// 一次同样的绑定，两者幂等。
  Future<void> _bindRoomAndResume(String roomId) async {
    await _outbox.bindRoomForReceiver(_receiverId, roomId);
    await widget.recovery?.resumeUnsent();
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

  /// 用户点击发送：**先落盘**（乐观展示先行，同一 localId/txid），
  /// 再等后台会话就绪。页面/进程在此之后任何时候消失都不丢消息。
  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final now = DateTime.now();
    final localId = _outbox.newLocalId();
    final txid = _outbox.newTxid();
    setState(() {
      _rows.add(OutboxMessage(
        localId: localId,
        txid: txid,
        receiverId: _receiverId,
        content: text,
        createdAt: now,
        updatedAt: now,
      ));
    });
    unawaited(_outbox
        .save(
          receiverId: _receiverId,
          content: text,
          localId: localId,
          txid: txid,
        )
        .then((_) => _reloadRows()));
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
                  for (final row in _rows.reversed)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        key: ValueKey('pending-outbox-${row.localId}'),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemGreen.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(row.content),
                            const SizedBox(height: 2),
                            // 网络问题只显示"等待发送/等待网络"，绝不显示红色感叹号
                            // （红色只留给服务端明确拒绝的 failed）。
                            Text(
                              row.status.label,
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
