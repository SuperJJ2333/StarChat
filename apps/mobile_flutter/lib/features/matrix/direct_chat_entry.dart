import '../contacts/contact_models.dart';
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

/// 同一好友「发消息」的单飞闸门。
///
/// `DirectChatController` 已按 `matrixUserId` 合并并发的房间打开请求，但每个
/// 调用方随后仍会各自 push 一个 RoomPage；同一好友连续快速点击会产生多个
/// route。此闸门从打开请求开始一直持有到 RoomPage 关闭（`push` 完成）或流程
/// 失败为止，保证一个好友同时只有一个打开流程。
final class DirectMessageOpenGate {
  final _openings = <String>{};

  /// 认领该键；已有打开流程在途时返回 false（调用方直接返回）。
  /// 空键（身份未知）不参与去重，交由身份解析给出失败提示。
  bool claim(String key) => key.isEmpty || _openings.add(key);

  void release(String key) {
    if (key.isNotEmpty) _openings.remove(key);
  }

  bool isOpen(String key) => key.isNotEmpty && _openings.contains(key);
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
ContactDetails _withMatrixBinding(
        ContactSummary known, String matrixUserId) =>
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
