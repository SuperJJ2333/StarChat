import 'message_send_scheduler.dart';
import 'outbox_message.dart';
import 'persistent_outbox_manager.dart';

/// 一次启动/恢复动作的结果（诊断与测试可见）。
final class OutboxRecoveryReport {
  const OutboxRecoveryReport({
    this.unsent = 0,
    this.resetInFlight = 0,
    this.bound = 0,
    this.awaitingRoom = 0,
    this.dispatched = 0,
  });

  /// 本次动作后仍未送达的行数（含 failed）。
  final int unsent;

  /// 上次进程死在"派发中"、被复位为"等待发送"的行数。
  final int resetInFlight;

  /// 本次新绑定房间号的行数。
  final int bound;

  /// 仍然没有房间号、必须等会话建立后才能发的行数。
  final int awaitingRoom;

  /// 本次真正派发成功的行数。
  final int dispatched;

  @override
  String toString() => 'OutboxRecoveryReport(unsent=$unsent, '
      'resetInFlight=$resetInFlight, bound=$bound, '
      'awaitingRoom=$awaitingRoom, dispatched=$dispatched)';
}

/// 启动/恢复服务：把持久化的 outbox 重新接回发送路径。
///
/// 与调度器的分工：
/// - [recoverOnStartup]：进程启动调用一次——读取全部 `status != sent`，
///   把上次死在"派发中"的行复位为"等待发送"，房间号已知的行立刻交给调度器
///   尝试；房间号未知的行留在 outbox 等 [resumeRoom] 绑定；
/// - [resumeRoom]：pending conversation 建立/找到真实房间后调用——把该
///   接收方**所有还没有房间号**的行绑定到 [roomId] 并立刻尝试发送；
/// - [resumeUnsent]：单纯的派发尝试（例如刚进房间/网络刚恢复）。
///
/// 实际派发由 [scheduler] 完成：已打开的房间走会话句柄（时间线气泡），
/// 没有打开的房间由注入的 `OutboxLeaseFactory` 临时取租约发送后立即释放
/// ——不导航、不 push 页面，因此 `RoomOpeningPolicy` /
/// `RoomNavigationCoordinator` / 建房协议完全不变。
///
/// 因此"杀掉进程 → 重开 → 自动继续发送"在没有打开会话的情况下也能成立，
/// 而不是只能等用户再次进入会话。
final class OutboxRecoveryService {
  OutboxRecoveryService({
    required this.outbox,
    this.scheduler,
  });

  final PersistentOutboxManager outbox;
  final MessageSendScheduler? scheduler;
  Future<OutboxRecoveryReport>? _startup;

  /// 应用启动：恢复未送达行。
  Future<OutboxRecoveryReport> recoverOnStartup() =>
      _startup ??= _recoverOnStartup();

  Future<OutboxRecoveryReport> _recoverOnStartup() async {
    final before = await outbox.unsent();
    final resetInFlight = before.where((row) => row.status.isInFlight).length;
    final rows = await outbox.recoverOnStartup();
    // 已确认送达的行不再保留正文副本（隐私最小化）。
    await outbox.pruneSent();
    final dispatched = await scheduler?.drain() ?? 0;
    return OutboxRecoveryReport(
      unsent: rows.length,
      resetInFlight: resetInFlight,
      awaitingRoom:
          rows.where((row) => !row.hasRoom && !row.status.isSettled).length,
      dispatched: dispatched,
    );
  }

  /// 会话建立后：绑定房间号并继续发送。
  ///
  /// 绑定范围是**该接收方所有还没有房间号的行**（含本进程之前的会话里
  /// 留下的行），因此"离线输入 → 杀进程 → 重开 → 建会话成功"也能续发。
  Future<OutboxRecoveryReport> resumeRoom({
    required String receiverId,
    required String roomId,
    Iterable<String>? localIds,
  }) async {
    final bound = await outbox.bindRoomForReceiver(
      receiverId,
      roomId,
      localIds: localIds,
    );
    final dispatched = await scheduler?.drain() ?? 0;
    final pending = await outbox.queryPending(receiverId: receiverId);
    return OutboxRecoveryReport(
      unsent: pending.length,
      bound: bound,
      awaitingRoom: pending.where((row) => !row.hasRoom).length,
      dispatched: dispatched,
    );
  }

  /// 只做一次派发尝试（例如房间页打开、网络刚恢复）。
  Future<int> resumeUnsent() async => await scheduler?.drain() ?? 0;
}
