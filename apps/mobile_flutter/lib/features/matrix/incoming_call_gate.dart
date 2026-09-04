import 'dart:async';

/// 来电安全门（P0：来电 UI 不被服务器请求阻塞）。
///
/// 校验不变量（与旧实现完全一致，绝不削弱）：
/// 本地用户在房、房间已 join、房间加密、成员恰好双方、远端与信令
/// 声明一致。变化只在成员数据来源：
/// 1. **本地优先**：直接用已同步的房间成员状态（onSync 已把成员合入
///    内存），绝大多数来电零网络请求、立即放行来电 UI；
/// 2. 本地成员为空（如房间刚入同步）才回退服务器 /members，
///    4 秒超时；仍拿不到成员 → 维持旧语义：拒接（安全优先）。
final class IncomingCallGate {
  IncomingCallGate({
    required this.localMembers,
    required this.remoteMembers,
    this.serverFetchTimeout = const Duration(seconds: 4),
  });

  /// 已同步的本地成员（room.getParticipants 的 id 集）。
  final Set<String> Function() localMembers;

  /// 服务器成员获取（返回 null 表示失败/超时）。
  final Future<Set<String>?> Function() remoteMembers;

  final Duration serverFetchTimeout;

  /// 校验通过返回远端用户 ID；否则 null（调用方拒接）。
  Future<String?> validate({
    required String? localUserId,
    required String? advertisedRemoteUserId,
    required bool roomJoined,
    required bool roomEncrypted,
  }) async {
    if (localUserId == null || !roomJoined || !roomEncrypted) return null;

    var participants = localMembers();
    if (participants.isEmpty) {
      participants = await _fetchWithTimeout() ?? const <String>{};
    }
    return resolveRemote(participants,
        localUserId: localUserId,
        advertisedRemoteUserId: advertisedRemoteUserId);
  }

  Future<Set<String>?> _fetchWithTimeout() async {
    try {
      return await remoteMembers().timeout(serverFetchTimeout);
    } catch (_) {
      return null;
    }
  }

  /// 纯函数：从成员集合解析合法远端（供单测直接覆盖）。
  static String? resolveRemote(
    Set<String> participants, {
    required String localUserId,
    String? advertisedRemoteUserId,
  }) {
    if (participants.length != 2 || !participants.contains(localUserId)) {
      return null;
    }
    final remote =
        participants.where((id) => id != localUserId).toList(growable: false);
    if (remote.length != 1) return null;
    if (advertisedRemoteUserId != null &&
        advertisedRemoteUserId != remote.single) {
      return null;
    }
    return remote.single;
  }
}
