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

  /// 业务 ID → Matrix ID 映射（BUG-11 回归）：拉黑/取消拉黑都必须同时
  /// 维护两侧——业务 ID 供发送门/好友设置，Matrix ID 供通知/未读抑制
  /// 与 Matrix 忽略列表同步。运行时立即生效，不等下次 /blocks 水合。
  final _matrixIdByUser = <String, String>{};
  bool _hasSnapshot = false;

  Set<String> get userIds => _userIds;

  Set<String> get matrixUserIds => Set.unmodifiable(_matrixIdByUser.values);

  String? matrixIdOf(String? userId) =>
      userId == null ? null : _matrixIdByUser[userId];

  /// Matrix ID 视角的是否拉黑（会话 directPeerId / 事件 senderId 比对用）。
  bool isMatrixIdBlocked(String? matrixUserId) =>
      matrixUserId != null &&
      matrixUserId.isNotEmpty &&
      _matrixIdByUser.containsValue(matrixUserId);

  /// 是否已经拿到过一份服务端来源的黑名单快照。
  ///
  /// 「好友设置」页据此判断能否**在断网/请求未回来之前**先用本地投影渲染开关：
  /// 只有真的读过服务端，才允许把 `isBlocked == false` 当成已知状态，
  /// 否则会用一个默认 false 冒充权威结果（BUG-10 的教训）。
  bool get hasSnapshot => _hasSnapshot;

  bool isBlocked(String? userId) =>
      userId != null && userId.isNotEmpty && _userIds.contains(userId);

  /// 用 `GET /blocks` 的结果替换本地投影。[matrixUserIds] 为对应的
  /// Matrix ID 集合（服务端返回的投影；缺省时保留旧值）。
  void replaceAll(Iterable<String> userIds,
      {bool fromServer = false,
      Map<String, String> matrixIdByUser = const {},
      Set<String> matrixUserIds = const {}}) {
    final next = userIds.where((id) => id.isNotEmpty).toSet();
    if (fromServer) _hasSnapshot = true;
    if (matrixIdByUser.isNotEmpty) {
      _matrixIdByUser.addAll(matrixIdByUser);
      _matrixIdByUser.removeWhere((businessId, _) => !next.contains(businessId));
    } else {
      // 兼容：未提供映射的调用方按旧集合裁剪（只保留仍在拉黑中的）。
      _matrixIdByUser.removeWhere((businessId, _) => !next.contains(businessId));
    }
    if (matrixUserIds.isNotEmpty) {
      for (final matrixId in matrixUserIds) {
        final owner = _matrixIdByUser.values.contains(matrixId);
        if (!owner) _matrixIdByUser[matrixId] = matrixId;
      }
    }
    _userIds = Set.unmodifiable(next);
    notifyListeners();
  }

  void markBlocked(String userId, {String? matrixUserId}) {
    if (matrixUserId != null && matrixUserId.startsWith('@')) {
      _matrixIdByUser[userId] = matrixUserId;
    }
    _userIds = {..._userIds, userId};
    notifyListeners();
  }

  void markUnblocked(String userId, {String? matrixUserId}) {
    _userIds = _userIds.where((id) => id != userId).toSet();
    if (matrixUserId != null) _matrixIdByUser.remove(userId);
    notifyListeners();
  }

  /// 登出：清空投影并作废快照标记（下一个账号不得继承）。
  void clear() {
    _hasSnapshot = false;
    _matrixIdByUser.clear();
    replaceAll(const <String>[]);
  }
}

/// 进程级单例；与 `momentsPrivacyChanges` 等既有跨页面投影保持一致。
final blockedContacts = BlockedContacts();
