import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

import '../../core/network_state_manager.dart';
import '../../core/performance_trace.dart';
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
/// 打开 RoomPage，并按 [outboxLocalIds] 接管持久化消息。
final class PendingConversationResult {
  const PendingConversationResult({
    required this.roomId,
    required this.queued,
    this.outboxLocalIds = const <String>[],
  });

  final String roomId;

  /// 兼容旧调用者的展示快照；不得据此新建发送或按文本推断投递身份。
  final List<String> queued;

  /// 本页接管的持久化行身份；即使后台已完成并清理正文，身份也不变。
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
    this.performanceTrace,
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
  final PerformanceTrace? performanceTrace;

  @override
  State<PendingConversationPage> createState() =>
      _PendingConversationPageState();
}

final class _PendingConversationPageState
    extends State<PendingConversationPage> {
  final _input = TextEditingController();

  /// 展示用行（权威来自持久化 outbox；乐观插入先行避免输入闪烁）。
  final _rows = <OutboxMessage>[];
  late final PersistentOutboxManager _outbox;
  bool _ownsOutbox = false;
  Object? _error;
  bool _opening = false;
  bool _settled = false;
  bool _recoveryRequested = false;
  bool _finishing = false;
  int _openAttempts = 0;
  String? _resolvedRoomId;
  Object? _storageError;
  final _saving = <String, Future<void>>{};
  final _unsaved = <String, OutboxMessage>{};
  final _handoffIds = <String>{};

  String get _receiverId => widget.contact.matrixUserId.trim();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.performanceTrace?.mark(PerformanceStage.firstFrameRendered);
      }
    });
    final injected = widget.outbox ?? PersistentOutboxManager.shared;
    _ownsOutbox = injected == null;
    // 没有可用持久层时退化为页内内存队列：至少保持本页语义一致
    // （真正的持久化由组合根注入 shared 实例保证）。
    _outbox = injected ?? PersistentOutboxManager(InMemoryOutboxStore());
    _outbox.addListener(_onOutboxChanged);
    widget.networkState?.addListener(_onNetworkChanged);
    _lastNetworkState = widget.networkState?.value;
    unawaited(_reloadRows());
    _start();
  }

  @override
  void dispose() {
    final trace = widget.performanceTrace;
    if (!_settled && trace != null && trace.isRecording) {
      trace.finish(result: _abandonedPerformanceResult);
    }
    _outbox.removeListener(_onOutboxChanged);
    if (_ownsOutbox) _outbox.dispose();
    widget.networkState?.removeListener(_onNetworkChanged);
    _input.dispose();
    super.dispose();
  }

  PerformanceResult get _abandonedPerformanceResult {
    if (_storageError != null) return PerformanceResult.failed;
    if (_error == null) return PerformanceResult.cancelled;
    final state = widget.networkState?.value;
    return state == NetworkState.offline || state == NetworkState.weak
        ? PerformanceResult.waitingNetwork
        : PerformanceResult.failed;
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
      _handoffIds.addAll(rows.map((row) => row.localId));
      final byId = {for (final row in rows) row.localId: row, ..._unsaved};
      _rows
        ..clear()
        ..addAll(byId.values.toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt)));
    });
  }

  NetworkState? _lastNetworkState;

  void _onNetworkChanged() {
    if (!mounted) return;
    final state = widget.networkState?.value;
    final previous = _lastNetworkState;
    _lastNetworkState = state;
    setState(() {});
    // 项5-3（缺陷 0919）：首次建房因断网/弱网失败后，网络恢复时自动继续，
    // 不再要求用户手点「重试」。只在「离线/弱 → online/recovering」的恢复
    // 沿触发，且上一次尝试已失败；_opening/_settled 守卫防止风暴重试。
    if (_settled) return;
    final recovered =
        (state == NetworkState.online || state == NetworkState.recovering) &&
            previous != null &&
            previous != state &&
            (previous == NetworkState.offline || previous == NetworkState.weak);
    if (recovered) {
      if (_opening) {
        _recoveryRequested = true;
      } else if (_error != null) {
        setState(() => _error = null);
        _start();
      }
    }
  }

  /// 后台建立会话。**绝不阻塞首帧**：本页已经可见，进度只体现在状态文案上。
  void _start() {
    if (_opening) return;
    if (_openAttempts > 0 && widget.performanceTrace?.isRecording == true) {
      widget.performanceTrace!.retryCount = _openAttempts;
    }
    _openAttempts++;
    _opening = true;
    _recoveryRequested = false;
    unawaited(widget.openRoom().then<void>((room) async {
      if (!mounted || _settled) return;
      if (room.roomId.trim().isEmpty) {
        final failure = StateError('规范私聊成员或加密状态尚未就绪');
        widget.onFailure?.call(failure);
        setState(() {
          _opening = false;
          _error = failure;
        });
        return;
      }
      _opening = false;
      _resolvedRoomId = room.roomId.trim();
      await _finishReady();
    }, onError: (Object error, StackTrace stackTrace) {
      if (!mounted) return;
      widget.onFailure?.call(error);
      setState(() {
        _opening = false;
        _error = error;
      });
      final state = widget.networkState?.value;
      if (_recoveryRequested &&
          (state == NetworkState.online || state == NetworkState.recovering)) {
        _error = null;
        _start();
      }
    }));
  }

  List<String> get _queuedTexts => [for (final row in _rows) row.content];

  Future<void> _finishReady() async {
    final roomId = _resolvedRoomId;
    if (_finishing || _settled || roomId == null) return;
    _finishing = true;
    try {
      do {
        while (_saving.isNotEmpty) {
          await Future.wait(List<Future<void>>.of(_saving.values));
        }
        if (!mounted || _unsaved.isNotEmpty) return;
        await _outbox.bindRoomForReceiver(_receiverId, roomId);
        if (_outbox.lastError != null) {
          if (mounted) setState(() => _storageError = _outbox.lastError);
          return;
        }
      } while (_saving.isNotEmpty);
      if (!mounted || _unsaved.isNotEmpty) return;
      _settled = true;
      unawaited(widget.recovery?.resumeUnsent());
      Navigator.of(context).pop(PendingConversationResult(
        roomId: roomId,
        queued: List.of(_queuedTexts),
        outboxLocalIds: List.of(_handoffIds),
      ));
    } finally {
      _finishing = false;
    }
  }

  String get _statusLabel {
    if (_storageError != null) return '消息保存失败，请重试；离开页面前请保留消息内容。';
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
  /// 保存确认前显示“正在保存”，失败保留正文并阻止自动离开页面。
  void _send() {
    if (_settled) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final now = DateTime.now();
    final localId = _outbox.newLocalId();
    final txid = _outbox.newTxid();
    final row = OutboxMessage(
      localId: localId,
      txid: txid,
      receiverId: _receiverId,
      content: text,
      createdAt: now,
      updatedAt: now,
    );
    setState(() {
      _rows.add(row);
      _unsaved[localId] = row;
      _handoffIds.add(localId);
    });
    _persistRow(row);
  }

  void _persistRow(OutboxMessage row) {
    if (_saving.containsKey(row.localId)) return;
    final save = _outbox.saveMessage(row).then<void>((saved) {
      if (saved == null) {
        if (mounted) {
          setState(() => _storageError =
              _outbox.lastError ?? StateError('Message could not be saved'));
        }
        return;
      }
      _unsaved.remove(row.localId);
      if (mounted) {
        setState(() => _storageError = _unsaved.isEmpty ? null : _storageError);
      }
    }).whenComplete(() {
      _saving.remove(row.localId);
      if (mounted) unawaited(_reloadRows());
    });
    _saving[row.localId] = save;
  }

  void _retry() {
    if (_storageError != null) {
      for (final row in List<OutboxMessage>.of(_unsaved.values)) {
        _persistRow(row);
      }
      unawaited(_finishReady());
      return;
    }
    setState(() => _error = null);
    _start();
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
                      style: CupertinoTheme.of(context)
                          .textTheme
                          .textStyle
                          .copyWith(
                            fontSize: 13,
                            color: CupertinoColors.secondaryLabel
                                .resolveFrom(context),
                          ),
                    ),
                  ),
                  if (_error != null || _storageError != null)
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      onPressed: _retry,
                      child: const Text('重试'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                reverse: true,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                children: [
                  for (final row in _rows.reversed)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        key: ValueKey('pending-outbox-${row.localId}'),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemGreen
                              .withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(row.content),
                            const SizedBox(height: 2),
                            if (_error != null ||
                                _storageError != null ||
                                widget.networkState?.value ==
                                    NetworkState.offline ||
                                row.status == OutboxStatus.failed ||
                                row.status == OutboxStatus.waitingNetwork)
                              const Icon(
                                  CupertinoIcons.exclamationmark_circle_fill,
                                  semanticLabel: '发送未成功',
                                  color: CupertinoColors.systemRed,
                                  size: 16),
                            Text(
                              _unsaved.containsKey(row.localId)
                                  ? (_saving.containsKey(row.localId)
                                      ? '正在保存'
                                      : '保存失败')
                                  : row.status.label,
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
