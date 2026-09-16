# 「清空聊天记录」误删会话 + 文字居中修复计划

生效：2026-09-16。用户授权来源：用户在本会话中明确选择方案「新增 clearedOnly /
historyClearedThrough 键，`_snapshotRoom` 的 `locallyDeleted` 只读『删除该聊天』
写的那一个键」，并要求「聊天信息」页「清空聊天记录」文字改为居中对齐。

基线 commit：`8ef5cbac4c80b49a9ad43f54f84a01bedf8dc9c8`。

## 1. 现象与根因

**现象**：在「聊天信息」页点击「清空聊天记录」后，私聊会话（及群聊会话）从「消息」
列表消失，看起来像被删除。

**根因**：`清空聊天记录` 与 `删除该聊天` 共用了同一个 `cleared-through` 截止时间键。

1. `RoomPage._clearLocalHistory` 调用 `LocalClearedHistory.clearThrough`，把清空
   截止时间写进 `changliao.hidden-events.v1.<scope>.cleared-through`。
2. `MatrixConversationCapability._snapshotRoom` 把「存在 cutoff 且最后一条事件不晚于
   cutoff」判定为 `locallyDeleted`。
3. `locallyDeleted` 会把偏好投影成 `hidden: true`。
4. `MatrixHomePage.build` 过滤掉 `preference.hidden` 的会话。

房间本身从未 `leave`/`forget`，`m.direct` 与规范房间目录都未被清理——只是被本地投影
隐藏。新入站消息到达后 `locallyDeleted` 变回 false，会话自愈。

## 2. 设计

引入与「删除」分离的「清空本机历史」信号：

- 新增 `LocalHistoryClearance` 接口与 `history-cleared-through` 存储键。
- `SharedPreferencesLocalHiddenEvents` 同时实现两者；消息可见性读取两者中较晚的截止
  时间，会话是否显示只读「删除」键。
- `MatrixConversationCapability.clearLocalHistory(...)` 成为「清空聊天记录」的唯一
  公共入口，只写清空键；`MatrixRoomLease.clearLocalHistory(...)` 供 `RoomPage` 调用。
- `MatrixConversationMutation.delete`（删除该聊天）语义不变，继续写 `cleared-through`。

**升级兼容**：`cleared-through` 在本次改动前也被「清空聊天记录」写入过，历史数据按原有
含义保留（删除信号），不做迁移，避免把用户已删除的会话重新显示出来。受影响的既有会话
仍会在收到新消息后自动恢复。

**未读行为**：清空后未读仍清零（`historyCleared` 而非 `locallyDeleted` 驱动），避免出现
「没有消息却带未读角标」。

## 3. 任务分解（TDD）

| # | 任务 | 失败用例 | 状态 |
| --- | --- | --- | --- |
| 1 | 清空不得隐藏会话 | `local_history_clear_test.dart`「清空聊天记录只清本机历史，会话仍留在消息列表」 | 完成 |
| 2 | 截止时间覆盖未逐条标记的历史 | 同上文件「清空截止时间同时隐藏未在本机逐条标记的历史消息」 | 完成 |
| 3 | 新消息后会话与新消息恢复可见 | 同上文件「清空聊天记录后收到新消息，会话与新消息都正常显示」 | 完成 |
| 4 | 删除该聊天仍隐藏会话（回归护栏） | 既有 `local_conversation_delete_test.dart` | 完成 |
| 5 | 「聊天信息」页「清空聊天记录」文字居中 | `direct_chat_info_test.dart` / `group_chat_info_test.dart` 居中用例 | 完成 |

## 4. 验收

- 每项失败用例先观察失败再实现（含两次变异探针，证明测试能捕获回归）。
- `flutter test test/features/matrix`、`flutter analyze`、Flutter 全量门禁。
- 证据记录见 `docs/verification/2026-09-16-clear-chat-history-room-visibility.md`。

## 5. 不在本计划范围

- 不修改业务 API、Matrix 服务端行为、`m.direct` 或规范房间目录。
- 不改变「删除该聊天」「不显示该聊天」的既有语义。
- 不构建 APK/IPA，不做生产发布，不迁移生产数据。
