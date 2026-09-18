import 'package:flutter/foundation.dart';

/// 拉黑（黑名单）状态的客户端投影。
///
/// 权威来源是业务 API 的 `GET /blocks`（服务端持久化，重装/重启后仍存在）；
/// 本投影只做进程内缓存，用来让「好友设置里的开关」「聊天发送门」在拉黑/
/// 取消拉黑后**立即**看到同一结果，而不必等下一次整表刷新。
///
/// 说明：拉黑是账号级关系，登出时会清空（见 SessionBootstrapController）。
final class BlockedContacts extends ChangeNotifier {
  Set<String> _userIds = const <String>{};

  Set<String> get userIds => _userIds;

  bool isBlocked(String? userId) =>
      userId != null && userId.isNotEmpty && _userIds.contains(userId);

  /// 用 `GET /blocks` 的结果替换本地投影。
  void replaceAll(Iterable<String> userIds) {
    final next = userIds.where((id) => id.isNotEmpty).toSet();
    if (setEquals(next, _userIds)) return;
    _userIds = Set.unmodifiable(next);
    notifyListeners();
  }

  void markBlocked(String userId) => replaceAll({..._userIds, userId});

  void markUnblocked(String userId) =>
      replaceAll(_userIds.where((id) => id != userId));

  void clear() => replaceAll(const <String>[]);
}

/// 进程级单例；与 `momentsPrivacyChanges` 等既有跨页面投影保持一致。
final blockedContacts = BlockedContacts();
