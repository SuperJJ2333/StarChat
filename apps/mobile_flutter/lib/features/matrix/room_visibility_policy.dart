/// 房间可见性 / 可打开性策略（**唯一实现**）。
///
/// 为什么需要它（架构审计 P2-1）：控制房间的判定此前只存在于消息列表的
/// `build` 里，并且依赖**展示名白名单**（`'畅聊表情仓库'` / `'畅聊提醒同步'`）。
/// 结果是：
/// - 全局搜索的「群聊」分组没有同样的过滤，账号级系统房间可被搜索到并打开；
/// - 任何人给群聊改名（或与该名字相同）都会改变过滤结果，判定与身份脱钩。
///
/// 本策略把判定收敛到一处，并且**只用身份事实**：
/// - `roomId`：打开时的唯一键；
/// - `accountData`：控制房间在账号数据里的 `room_id` 引用
///   （`com.changliao.emoji.vault` / `com.changliao.reminders.control`），
///   这是控制房间的权威身份（房间改名不影响它）；
/// - room metadata（`isDirect`、成员数）由调用方在需要更细粒度时补充，
///   但**绝不**用展示名。
///
/// 策略是**纯值对象**：不持有客户端、不做 I/O、可自由构造与测试。
/// 它不创建页面、不管理租约——那是 `RoomNavigationCoordinator` 的职责。
final class RoomVisibilityPolicy {
  const RoomVisibilityPolicy({this.controlRoomIds = const <String>{}});

  /// 由 accountData 引用解析出的控制房间 roomId 集合（已 trim，忽略空值）。
  factory RoomVisibilityPolicy.forRoomIds(Iterable<String?> roomIds) {
    final ids = <String>{};
    for (final roomId in roomIds) {
      final id = roomId?.trim() ?? '';
      if (id.isNotEmpty) ids.add(id);
    }
    return RoomVisibilityPolicy(controlRoomIds: Set.unmodifiable(ids));
  }

  /// 账号级系统房间（表情仓库 / 提醒同步控制房间）的 roomId 集合。
  final Set<String> controlRoomIds;

  /// 控制房间：账号内部使用的系统房间，**永远不出现在用户可见列表里**，
  /// 也**永远不能**被任何入口打开成会话页。
  bool isControlRoom(String roomId) {
    final id = roomId.trim();
    return id.isNotEmpty && controlRoomIds.contains(id);
  }

  /// 是否允许在用户可见列表（会话列表、搜索结果、转发目标）中展示。
  bool isVisible(String roomId) => !isControlRoom(roomId);

  /// 是否允许被打开。当前与 [isVisible] 同义（可见性即打开权限），
  /// 单独留出方法名是为了让"列表过滤"与"打开判定"共用同一条规则。
  bool isOpenable(String roomId) => !isControlRoom(roomId);

  RoomVisibilityPolicy merge(RoomVisibilityPolicy other) =>
      RoomVisibilityPolicy.forRoomIds([
        ...controlRoomIds,
        ...other.controlRoomIds,
      ]);

  @override
  bool operator ==(Object other) =>
      other is RoomVisibilityPolicy &&
      other.controlRoomIds.length == controlRoomIds.length &&
      other.controlRoomIds.containsAll(controlRoomIds);

  @override
  int get hashCode => Object.hashAllUnordered(controlRoomIds);
}
