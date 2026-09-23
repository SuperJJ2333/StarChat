/// 持久化出站消息（Outbox）状态机。
///
/// 与 `RoomDeliveryState`（内存里的乐观行状态）一一对应，但**只有**这里的
/// 状态会跨进程存活。语义严格按产品定义：
///
/// - [queued]（等待发送）：消息已创建并**先落盘**，还没交给传输层；
/// - [sending]（发送中）：已交给传输层，等待服务端确认；
/// - [waitingNetwork]（等待网络）：网络原因失败，等待网络恢复后自动重发；
///   **绝不是终局失败**，UI 不许显示红色感叹号；
/// - [failed]（发送失败）：服务端明确拒绝（无权限、内容非法、房间不存在），
///   只能手动重试；
/// - [sent]（正常）：服务端已确认。
enum OutboxStatus {
  queued,
  sending,
  waitingNetwork,
  failed,
  sent,
}

extension OutboxStatusSemantics on OutboxStatus {
  /// 用户可见文案（与产品词汇表一一对应）。
  String get label => switch (this) {
        OutboxStatus.queued => '等待发送',
        OutboxStatus.sending => '发送中',
        OutboxStatus.waitingNetwork => '等待网络',
        OutboxStatus.failed => '发送失败',
        OutboxStatus.sent => '正常',
      };

  /// 服务端已确认，不再需要任何重试。
  bool get isSettled => this == OutboxStatus.sent;

  /// 可以（且应该）被调度器自动派发的状态。
  bool get isAutoDispatchable =>
      this == OutboxStatus.queued || this == OutboxStatus.waitingNetwork;

  /// 传输层已收到、等待确认的状态（进程中途死亡时会被复位为 queued）。
  bool get isInFlight => this == OutboxStatus.sending;

  /// 持久化名称（数据库里的 `status` 列）。
  String get wireName => name;

  /// 从数据库读取；未知值按最保守的 [OutboxStatus.queued] 处理，让消息
  /// 仍然有机会被重发，而不是被静默当成"已送达"或"硬失败"。
  static OutboxStatus fromWire(String? raw) {
    for (final status in OutboxStatus.values) {
      if (status.name == raw) return status;
    }
    return OutboxStatus.queued;
  }
}

/// 一条待发送的文本消息。
///
/// 设计约束（防止恢复后重复发送）：
/// - [localId]：本行主键，创建时生成一次；
/// - [txid]：Matrix 事务 ID，**创建时生成一次，之后所有重试/重启/重复派发
///   一律复用**，绝不重新生成——这是幂等性的关键；
/// - [content]：用户原文（本层只覆盖文本；媒体/红包/转账有各自的带外载荷，
///   不能靠重放正文恢复，因此不进 outbox）。
final class OutboxMessage {
  const OutboxMessage({
    required this.localId,
    required this.txid,
    required this.receiverId,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
    this.roomId,
    this.status = OutboxStatus.queued,
    this.retryCount = 0,
    this.serverRetryCount = 0,
    this.nextServerRetryAt,
    this.lastError,
    this.accountId = '',
  });

  /// 本地主键（UUID）；每次"创建一条新消息"都是新值。
  final String localId;

  /// Matrix 事务 ID（幂等键）。创建时生成一次，重试永不重新生成。
  final String txid;

  /// 目标房间；会话尚未建立时为 null（等待 pending conversation 绑定）。
  final String? roomId;

  /// 接收方：单聊为对端 Matrix 用户 ID，群聊为房间 ID。
  final String receiverId;

  /// 消息正文（仅文本消息进入本层）。
  final String content;

  final OutboxStatus status;

  /// 累计认领次数（含准入/租约尝试），也是结果 CAS 的持久化所有权代次。
  /// 每次认领 +1；与仅计服务器重试预算的 serverRetryCount 独立。
  final int retryCount;

  /// Consumed automatic server retries; survives process and page restarts.
  final int serverRetryCount;
  final DateTime? nextServerRetryAt;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// 最近一次失败原因（诊断用，不面向用户逐字展示）。
  final String? lastError;

  /// 账号命名空间（`matrix.userId`），避免切号后把上一账号的消息发出去。
  final String accountId;

  bool get hasRoom => roomId != null && roomId!.trim().isNotEmpty;

  /// 可被调度器自动继续派发（房间已知 + 状态允许）。
  bool get isResumable => hasRoom && status.isAutoDispatchable;

  OutboxMessage copyWith({
    String? localId,
    String? txid,
    String? roomId,
    String? receiverId,
    String? content,
    OutboxStatus? status,
    int? retryCount,
    int? serverRetryCount,
    DateTime? nextServerRetryAt,
    bool clearNextServerRetryAt = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? lastError,
    String? accountId,
    bool clearRoom = false,
    bool clearLastError = false,
  }) =>
      OutboxMessage(
        localId: localId ?? this.localId,
        txid: txid ?? this.txid,
        roomId: clearRoom ? null : (roomId ?? this.roomId),
        receiverId: receiverId ?? this.receiverId,
        content: content ?? this.content,
        status: status ?? this.status,
        retryCount: retryCount ?? this.retryCount,
        serverRetryCount: serverRetryCount ?? this.serverRetryCount,
        nextServerRetryAt: clearNextServerRetryAt
            ? null
            : (nextServerRetryAt ?? this.nextServerRetryAt),
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        lastError: clearLastError ? null : (lastError ?? this.lastError),
        accountId: accountId ?? this.accountId,
      );

  /// 数据库行（列名与 `outbox_messages` 表一致）。
  Map<String, Object?> toRow() => <String, Object?>{
        'local_id': localId,
        'txid': txid,
        'room_id': roomId,
        'receiver_id': receiverId,
        'account_id': accountId,
        'content': content,
        'status': status.wireName,
        'retry_count': retryCount,
        'server_retry_count': serverRetryCount,
        'next_server_retry_at': nextServerRetryAt?.millisecondsSinceEpoch,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'last_error': lastError,
      };

  static OutboxMessage fromRow(Map<String, Object?> row) => OutboxMessage(
        localId: row['local_id']! as String,
        txid: row['txid']! as String,
        roomId: row['room_id'] as String?,
        receiverId: (row['receiver_id'] ?? '') as String,
        accountId: (row['account_id'] ?? '') as String,
        content: (row['content'] ?? '') as String,
        status: OutboxStatusSemantics.fromWire(row['status'] as String?),
        retryCount: (row['retry_count'] as int?) ?? 0,
        serverRetryCount: (row['server_retry_count'] as int?) ?? 0,
        nextServerRetryAt: row['next_server_retry_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                row['next_server_retry_at']! as int),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (row['created_at'] as int?) ?? 0),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (row['updated_at'] as int?) ?? 0),
        lastError: row['last_error'] as String?,
      );

  @override
  String toString() => 'OutboxMessage($localId, tx=$txid, room=$roomId, '
      'status=${status.name}, retries=$retryCount)';
}

/// 从 [texts] 里挑出**没有对应 outbox 行**的原文（按内容多重集抵扣）。
///
/// 用途：pending conversation 交回的原文与已经落盘的行可能描述同一条消息；
/// 房间页必须只对"没有落盘行"的原文新建发送，否则同一条消息会发两次。
/// 重复内容按出现次数逐个抵扣（用户连打两条"你好"也不会互相顶掉）。
List<String> textsWithoutOutboxRows({
  required Iterable<String> texts,
  required Iterable<OutboxMessage> rows,
}) {
  final owned = <String, int>{};
  for (final row in rows) {
    owned.update(row.content, (count) => count + 1, ifAbsent: () => 1);
  }
  final orphaned = <String>[];
  for (final text in texts) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) continue;
    final remaining = owned[trimmed] ?? 0;
    if (remaining > 0) {
      owned[trimmed] = remaining - 1;
      continue;
    }
    orphaned.add(trimmed);
  }
  return orphaned;
}
