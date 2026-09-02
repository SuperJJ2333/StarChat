/// 统计助手的「当前可见会话」作用域栈。
///
/// 会话页（RoomPage）进入/离开时维护这个栈，顶部即用户正看到的会话。
/// 工具 onTap 是上下文无关的（模块级全局注册），点击时从这里读取当前会话，
/// 从而避免「多会话页叠放时注册被覆盖 / 上层销毁后工具指向过期会话」的问题。
abstract final class StatisticsRoomScope {
  static final List<String> _stack = <String>[];

  /// 当前可见会话的 roomId；无会话页时为 null。
  static String? get current => _stack.isEmpty ? null : _stack.last;

  /// 进入会话页时调用；同一会话重复进入先移除旧位置再压栈。
  static void enter(String roomId) {
    _stack.removeWhere((id) => id == roomId);
    _stack.add(roomId);
  }

  /// 离开会话页时调用。
  static void leave(String roomId) {
    _stack.removeWhere((id) => id == roomId);
  }
}
