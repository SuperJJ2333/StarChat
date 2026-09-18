import '../features/contacts/friend_acceptance_greeting_ledger.dart';

/// 同一个一次性记录（好友申请 id）正在发放时的进程内去重。
///
/// 账本本身是"读-改-写"，极短时间内的并发点击（同帧双击/两个入口同时触发）
/// 可能都读到"未发放"；这一层保证同一把键只有一个发放流程在跑。键由服务端
/// 权威的申请 id 派生，全局唯一，因此进程级集合不会误伤不同好友。
final _greetingClaimsInFlight = <String>{};

/// 通过好友验证后的**一次性**编排（BUG-3，2026-09-19）。
///
/// 背景：`AppHome._establishDirectChatAndGreet` 修复前无条件调用
/// `sendFriendAccepted`，于是「通过朋友验证」页每点一次「打开聊天」，会话里
/// 就多一条「你们已成为好友，现在可以开始聊天了。」和一次打招呼；Matrix 的
/// txid 去重只覆盖有限缓存窗口，重启/过期/多端仍会重复。
///
/// 行为约定（用户可见语义）：
/// - [openRoom] 每次都执行：重复点击「打开聊天」仍然解析/打开会话；
/// - [openConversation] 每次都执行：进入会话本身不受门控影响；
/// - [sendGreeting] 只在幂等账本 [FriendAcceptanceGreetingLedger.claim] 认领
///   成功时执行一次；重复点击、杀进程重启、重新登录同一账号都不会再发；
/// - 发送失败必须 [FriendAcceptanceGreetingLedger.release] 释放认领并向上抛，
///   让既有的"失败弹窗 + 重试"编排仍能补发（不丢系统提示）。
///
/// 抽成纯函数（不依赖 `AppHome` 的 widget 依赖图）是为了让"连续打开 N 次 →
/// 打开 N 次 / 发放 1 次"、"重启后仍只发放一次"、"首次失败释放后可补发"
/// 这些编排级行为可以被直接、稳定地测试。组合根（`lib/app_home.dart`）只做
/// 接线：把好友身份解析、`directChats.open`、`sendFriendAccepted`、
/// `_openConversationFromNotification` 作为回调传进来。
Future<void> establishAcceptedFriendChat({
  required FriendAcceptanceGreetingLedger ledger,
  required String acceptingUserId,
  required String? requestId,
  required Future<String> Function() openRoom,
  required Future<void> Function(String roomId) sendGreeting,
  required Future<void> Function(String roomId) openConversation,
}) async {
  final roomId = await openRoom();
  final key = friendAcceptanceGreetingKey(
    requestId: requestId,
    roomId: roomId,
    acceptingUserId: acceptingUserId,
  );
  // 幂等键不可用（房间号与账号都缺失，现实中不会出现）时不阻塞会话打开，
  // 保持旧行为：照常发送。
  final gateAvailable = key.trim().isNotEmpty;
  if (!gateAvailable) {
    await sendGreeting(roomId);
    await openConversation(roomId);
    return;
  }
  if (_greetingClaimsInFlight.contains(key)) {
    // 同一条一次性记录正在发放：会话照常打开，但不重复发送。
    await openConversation(roomId);
    return;
  }
  _greetingClaimsInFlight.add(key);
  try {
    if (await ledger.claim(key)) {
      try {
        await sendGreeting(roomId);
      } catch (_) {
        // 发送失败释放认领：重试仍能补发一次。
        await ledger.release(key);
        rethrow;
      }
    }
  } finally {
    _greetingClaimsInFlight.remove(key);
  }
  await openConversation(roomId);
}
