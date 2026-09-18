import 'dart:async';

import '../contacts/contact_models.dart';
import 'direct_chat_controller.dart';
import 'profile_repository.dart';

/// 好友资料「发消息 / 通话」的统一身份入口。
///
/// 业务 `userId` 是联系人身份主键，`matrixUserId` 只是通信映射。资料页入口
/// 传入的快照可能来自旧缓存、群成员实时快照、朋友圈作者、刚接受的好友，或
/// Matrix 绑定更新前的旧数据，因此「发消息」一律回到好友目录取权威条目
/// （[resolveFriendContact]），只有目录里确实没有这个好友时才判定为
/// “已不是当前好友”。
///
/// 本文件只做身份解析与打开去重；canonical 私聊房间仍由
/// `DirectChatController` + `CoordinatedDirectChatGateway` 仲裁，
/// RoomLease/RoomPage 的推送与释放仍由 AppHome（composition root）承担。

/// 仅有 Matrix ID 的入口（通话、通知、房间成员）确认该 Matrix 用户仍是当前
/// 好友；本地目录缺失时按矩阵索引刷新一次目录，仍缺失则说明已不是好友。
///
/// 与 [resolveFriendContact] 的分工：这里没有业务 `userId`，只能按 Matrix 映射
/// 判定，因此不解决“Matrix ID 已更新”的旧快照场景；资料页「发消息」入口必须
/// 使用 [resolveFriendContact]。
Future<void> ensureCurrentFriendIdentity(
    ProfileRepository cache, String matrixUserId) async {
  await cache.hydrate();
  if (cache.contactsByMatrixId.containsKey(matrixUserId)) return;
  if (cache.profile == null) await cache.preload();
  if (!cache.contactsByMatrixId.containsKey(matrixUserId)) {
    try {
      await cache.refreshContactsQuietly(minInterval: Duration.zero);
    } catch (_) {
      // 断网时静默：本地已有该好友映射即可继续打开会话。
    }
  }
  if (!cache.contactsByMatrixId.containsKey(matrixUserId)) {
    throw StateError('The contact is no longer a current friend');
  }
}

/// 好友资料入口的权威联系人解析（「发消息」唯一实现）。
///
/// 顺序：业务 `userId` 命中本地好友目录 → 未命中先 `preload` 再静默刷新一次
/// → 仍无该好友（userId 与 Matrix ID 都不在当前目录）抛
/// `StateError('The contact is no longer a current friend')`
/// （失败分类见 [classifyDirectChatFailure]，重试无意义）。
///
/// 目录里存在该好友但其 Matrix 绑定尚未同步时，用入口快照补齐通信映射，
/// 并保留目录中的备注/标签等本机字段（备注是查看者私有数据，不能被入口
/// 快照覆盖）。
Future<ContactDetails> resolveFriendContact(
    ProfileRepository cache, ContactDetails entry) async {
  await cache.hydrate();
  var authoritative = _currentFriend(cache, entry);
  if (authoritative == null) {
    if (cache.profile == null) await cache.preload();
    authoritative = _currentFriend(cache, entry);
  }
  if (authoritative == null) {
    try {
      await cache.refreshContactsQuietly(minInterval: Duration.zero);
    } catch (_) {
      // 断网时静默：本地已有该好友映射即可继续打开会话。
    }
    authoritative = _currentFriend(cache, entry);
  }
  if (authoritative == null) {
    throw StateError('The contact is no longer a current friend');
  }
  if (authoritative.matrixUserId.trim().isNotEmpty) return authoritative;

  // 好友已在目录但 Matrix 绑定未同步（例如刚接受好友、绑定尚未回填）：
  // 仅当入口快照带有效 Matrix ID 时才可继续，否则无法打开会话。
  final matrixUserId = entry.matrixUserId.trim();
  if (matrixUserId.isEmpty) {
    throw StateError('The contact is no longer a current friend');
  }
  final known = cache.contactsByUserId[authoritative.userId];
  if (known != null) {
    await cache.upsertContactDetails(_withMatrixBinding(known, matrixUserId));
  }
  final resolved = cache.contactDetailsByUserId(authoritative.userId);
  if (resolved == null || resolved.matrixUserId.trim().isEmpty) {
    throw StateError('The contact is no longer a current friend');
  }
  return resolved;
}

/// 同一好友「发消息」的打开键：业务 `userId` 优先，缺失时退回 Matrix ID。
String directMessageOpenKey(ContactDetails contact) {
  final userId = contact.userId.trim();
  return userId.isNotEmpty ? userId : contact.matrixUserId.trim();
}

/// 好友资料「语音/视频通话」入口的权威目标解析。
///
/// 与「发消息」同一规则（业务 `userId` 为主键，见 [resolveFriendContact]）：
/// 入口快照里可能过期的 `matrixUserId` 绝不直接用于开房或发起呼叫，
/// 否则会把通话拨给用户旧的 Matrix 身份。返回的权威联系人同时供通话页
/// 展示使用（避免「房间用新身份、页面显示旧资料」）。
Future<({ContactDetails contact, String roomId})> resolveCallTarget({
  required ProfileRepository cache,
  required DirectChatController directChats,
  required ContactDetails entry,
}) async {
  final authoritative = await resolveFriendContact(cache, entry);
  final matrixUserId = authoritative.matrixUserId.trim();
  if (matrixUserId.isEmpty) {
    throw StateError('The contact is no longer a current friend');
  }
  final room = await directChats.open(matrixUserId);
  return (contact: authoritative, roomId: room.roomId);
}

/// 「发消息」在闸门内解析出的目标：权威联系人 + canonical 房间号。
///
/// 只承载数据：**不放** BuildContext / Navigator / Route / RoomLease。
/// RoomPage 的 push、租约、复用与 popUntil 全部属于 AppHome 的
/// `RoomNavigationCoordinator`（按 roomId 负责），不属于本对象。
final class DirectMessageTarget {
  const DirectMessageTarget({required this.roomId, required this.contact});

  /// canonical 私聊房间号（由 `DirectChatController` + 网关仲裁得到）。
  final String roomId;

  /// 目录中的权威联系人（含补齐/更新后的 `matrixUserId`）。
  final ContactDetails contact;
}

/// 同一好友「发消息」的**身份解析 + canonical 房间获取**单飞闸门。
///
/// 锁定范围**只覆盖** [DirectMessageTarget] 的解析过程：
/// `业务 userId → resolveFriendContact → directChats.open → canonical roomId`。
/// 拿到 roomId 即释放；失败同样立即释放，以便弹窗「重试」可以重新进入。
///
/// 绝不把 `Navigator.push(RoomPage)` 纳入锁定范围：`await push` 只在页面**关闭**
/// 后才完成，一旦纳入，Room A 打开期间同一好友的第二次「发消息」会被静默吞掉，
/// 根本到不了 `RoomNavigationCoordinator` 的 `popUntil`（真机 BUG：Room A 内再次
/// 「发消息」完全没反应）。
///
/// 并发语义为 single-flight：同一好友的在途请求复用同一个 Future 与同一个
/// [DirectMessageTarget]，不重复解析身份、不重复查询 canonical 房间，也不再
/// 丢弃第二次请求。房间页面级的去重由 `RoomNavigationCoordinator` 按 roomId 负责，
/// 两者分工不重叠。
///
/// 2026-09-18 Offline First：解析结果可为 null（本地优先路径下“本地还没有会话”
/// 是正常结果，不是失败）；单飞语义不变。
final class DirectMessageOpenGate {
  final _flights = <String, Future<DirectMessageTarget?>>{};

  /// 认领该键并发起 [operation]；同键在途时返回**同一个** Future。
  /// 空键（身份未知）不参与去重，交由身份解析给出失败提示。
  Future<DirectMessageTarget?> run(
    String key,
    Future<DirectMessageTarget?> Function() operation,
  ) {
    if (key.isEmpty) return operation();
    final existing = _flights[key];
    if (existing != null) return existing;

    // 先登记 flight 再启动解析：operation 在第一个 await 之前可能是同步的，
    // 必须先占位才能被同一帧内的第二次点击合并。
    final completer = Completer<DirectMessageTarget?>();
    final pending = completer.future;
    _flights[key] = pending;
    unawaited(Future<DirectMessageTarget?>.sync(operation).then((target) {
      if (identical(_flights[key], pending)) _flights.remove(key);
      if (!completer.isCompleted) completer.complete(target);
    }, onError: (Object error, StackTrace stackTrace) {
      if (identical(_flights[key], pending)) _flights.remove(key);
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }));
    return pending;
  }

  /// 该好友是否仍在解析中（在途 flight 未释放）。页面打开**不算**在途。
  bool isOpen(String key) => key.isNotEmpty && _flights.containsKey(key);
}

/// 本地目录中的当前好友：业务 `userId` 优先，Matrix ID 兜底（群成员/朋友圈
/// 入口可能出现业务 userId 为空或形态不同的快照）。
ContactDetails? _currentFriend(ProfileRepository cache, ContactDetails entry) {
  final userId = entry.userId.trim();
  if (userId.isNotEmpty) {
    final byUserId = cache.contactsByUserId[userId];
    if (byUserId != null) return byUserId.toDetails();
  }
  final matrixUserId = entry.matrixUserId.trim();
  if (matrixUserId.isEmpty) return null;
  return cache.contactsByMatrixId[matrixUserId];
}

/// 用入口快照的 Matrix ID 补齐目录条目的通信映射，保留目录中的本机字段
/// （备注/标签/朋友圈权限/在线状态）。
ContactDetails _withMatrixBinding(ContactSummary known, String matrixUserId) =>
    ContactDetails(
      userId: known.userId,
      username: known.username,
      matrixUserId: matrixUserId,
      nickname: known.nickname,
      remark: known.remark,
      avatarUrl: known.avatarUrl,
      avatarIsKnown: known.avatarIsKnown,
      nudgeSuffix: known.nudgeSuffix,
      momentsPermission: known.momentsPermission,
      tags: known.tags,
      starred: known.starred,
      lastSeenAt: known.lastSeenAt,
      lastSeenKnown: known.lastSeenKnown,
    );
