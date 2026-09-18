import 'package:flutter/foundation.dart';

/// 会话内已知的控制房间（**创建即登记**）。
///
/// 为什么需要它：控制房间的身份来自 accountData 引用（唯一权威、与展示名
/// 无关），但 "房间已创建" 与 "accountData 已写入并对本机可读" 之间存在一个
/// 很短的窗口（刚创建、刚登录、刚切换账号）。窗口内房间会短暂出现在会话
/// 列表/搜索结果里。
///
/// 名字白名单已按要求删除，因此这里用**房间号登记**来补窗口：控制房间由本
/// 进程创建时立刻登记；判定仍然只看身份（roomId / accountData），不看名字，
/// 也不修改任何 Matrix 协议或房间状态。
///
/// 本文件刻意不依赖任何 Matrix/业务模块（只用 `foundation`），因此既可以被
/// 可见性解析引用，也可以被控制房间的创建方引用而不产生循环依赖。
abstract final class ControlRoomRegistry {
  static final Set<String> _sessionRoomIds = <String>{};

  /// 登记一个控制房间（幂等；空值忽略）。
  static void register(String? roomId) {
    final id = roomId?.trim() ?? '';
    if (id.isNotEmpty) _sessionRoomIds.add(id);
  }

  /// 本次会话已知的控制房间（不可变视图）。
  static Set<String> get sessionRoomIds => Set.unmodifiable(_sessionRoomIds);

  /// 账号切换/退出登录/清空本地数据：控制房间是账号级的，登记不得跨账号
  /// 累积（房间号全局唯一，陈旧登记本身无害，但不应无限增长）。
  static void clear() => _sessionRoomIds.clear();

  @visibleForTesting
  static void resetForTest() => _sessionRoomIds.clear();
}
