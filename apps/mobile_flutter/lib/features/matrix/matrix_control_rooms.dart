import 'package:matrix/matrix.dart';

import 'control_room_registry.dart';
import 'matrix_emoji_vault.dart';
import 'matrix_message_reminder_backend.dart';
import 'room_visibility_policy.dart';

export 'control_room_registry.dart' show ControlRoomRegistry;

/// 控制房间（账号级系统房间）身份的**唯一解析点**。
///
/// 以前这里用**展示名白名单**（`'畅聊表情仓库'` / `'畅聊提醒同步'`）判断，
/// 有两个问题：
/// 1. 判定与身份脱钩——改名即失效，同名即误判；
/// 2. 只有消息列表用了它，全局搜索没有，于是控制房间能被搜索到并打开。
///
/// 现在改为**只用事实**：
/// - roomId；
/// - accountData 引用（`com.changliao.emoji.vault` /
///   `com.changliao.reminders.control` 的 `room_id`）——账号级权威身份；
/// - 本会话的创建登记（[ControlRoomRegistry]，补 accountData 可读前的窗口）。
///
/// 解析结果交给 [RoomVisibilityPolicy]，由同一条规则同时服务于
/// "列表是否展示"与"是否允许打开"。
RoomVisibilityPolicy roomVisibilityFromAccountData(Client client) =>
    RoomVisibilityPolicy.forRoomIds([
      ...ControlRoomRegistry.sessionRoomIds,
      client.accountData[emojiVaultAccountDataType]?.content['room_id']
          ?.toString(),
      client.accountData[messageReminderAccountDataType]?.content['room_id']
          ?.toString(),
    ]);

/// 便捷判定：给定客户端与房间号，该房间是否为不可打开的控制房间。
///
/// 语义等价于 `!roomVisibilityFromAccountData(client).isOpenable(roomId)`；
/// 保留此函数是为了让调用方读起来是"控制房间判定"而不是"可见性取反"。
bool isMatrixControlRoom({required Client client, required String roomId}) =>
    !roomVisibilityFromAccountData(client).isOpenable(roomId);
