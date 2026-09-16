# 验证记录：「清空聊天记录」误删会话 + 文字居中

日期：2026-09-16（Asia/Hong_Kong）
关联计划：[2026-09-16-clear-chat-history-room-visibility](../../superpowers/plans/2026-09-16-clear-chat-history-room-visibility.md)
关联任务：[2026-09-16-clear-chat-history-room-visibility](../workflow/tasks/2026-09-16-clear-chat-history-room-visibility.md)

## 1. 根因

「清空聊天记录」与「删除该聊天」共用同一个 `cleared-through` 截止时间键：

1. `RoomPage._clearLocalHistory` 调 `LocalClearedHistory.clearThrough` 写
   `changliao.hidden-events.v1.<scope>.cleared-through`。
2. `MatrixConversationCapability._snapshotRoom` 把「有 cutoff 且最后一条事件不晚于
   cutoff」判为 `locallyDeleted`。
3. `locallyDeleted` 把偏好投影为 `hidden: true`。
4. `MatrixHomePage.build` 过滤 `preference.hidden` 的会话。

房间从未 `leave`/`forget`，`m.direct` 与规范房间目录未被清理；这是纯本机投影，新入站
消息到达后自愈。

## 2. 改动

| 文件 | SHA256(前16) | 改动 |
| --- | --- | --- |
| `apps/mobile_flutter/lib/features/matrix/local_hidden_events.dart` | `01D01E5335181D11` | 新增 `LocalHistoryClearance` 接口与 `history-cleared-through` 键；`lastHistoryCutoff` 合并两个截止时间 |
| `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart` | `1ECA3AAA33DA3030` | 新增 `clearLocalHistory`；`_snapshotRoom` 拆出 `locallyDeleted` / `historyCleared` |
| `apps/mobile_flutter/lib/features/matrix/room_page.dart` | `47B8F011522F4B26` | `_clearLocalHistory` 改走新的清空契约 |
| `apps/mobile_flutter/lib/features/matrix/direct_chat_info_page.dart` | `9FC2233F0CF36ACD` | 「清空聊天记录」文字改 `Center` 包裹 |
| `apps/mobile_flutter/lib/features/matrix/group_chat_info_page.dart` | `FC6D925A67CF1A41` | 同上（群聊「聊天信息(N)」页） |

新增测试：`apps/mobile_flutter/test/features/matrix/local_history_clear_test.dart`。
修改测试：`direct_chat_info_test.dart`、`group_chat_info_test.dart`（各加一条居中用例）。

## 3. TDD 证据

| 用例 | RED 观察 | GREEN |
| --- | --- | --- |
| 清空聊天记录只清本机历史，会话仍留在消息列表 | `Expected: false / Actual: <true>`（`preference.hidden`） | 通过 |
| 清空截止时间同时隐藏未在本机逐条标记的历史消息 | 变异探针：让 `lastHistoryCutoff` 忽略清空键 → `Expected: null / Actual: <Instance of 'MatrixEventSnapshot'>` | 通过 |
| 清空聊天记录后收到新消息，会话与新消息都正常显示 | （新契约行为） | 通过 |
| 「删除该聊天」仍隐藏会话 | 既有用例，未改动 | 通过 |
| 聊天信息页「清空聊天记录」文字居中（私聊） | `Expected: a value less than <1.0> / Actual: <134.22999954223633>` | 通过 |
| 聊天信息页「清空聊天记录」文字居中（群聊） | 变异探针：去除 `Center` → `Actual: <130.72999954223633>` | 通过 |

两次变异探针均已还原；当前工作树不含探针代码。

## 4. 测试结果

| 命令 | 退出码 | 结果 | 日志 |
| --- | --- | --- | --- |
| `flutter test test/features/matrix` | 0 | 1312 通过 / 0 失败 | 终端输出 |
| `flutter test`（全量，冻结版本） | 0 | 2680 通过 / 0 失败 | `artifacts/2026-09-16/flutter-full.txt` |
| `flutter analyze` | 0 | `No issues found!` | 终端输出 |

环境：Flutter 3.44.9 stable（revision 6b182d2c75）、Dart 3.12.2、Windows 10 Pro 19045。
基线 commit `8ef5cbac4c80b49a9ad43f54f84a01bedf8dc9c8`。

## 5. 未执行项与限制

- 未构建 APK / IPA，未做真机验证。A1–A3、A5 需在包含本改动的 Debug 包上由用户验收。
- 未部署生产，未迁移数据库，未改动 `scripts/verify.ps1` 覆盖的服务端门禁。
- **升级兼容**：本次改动前，「清空聊天记录」已经把 `cleared-through` 写进了老设备。
  该键保持原有含义（删除信号），不做迁移，因此这些历史会话仍会保持隐藏，直到收到
  新消息后自动恢复。若需在真机上验证这一点，应使用干净安装或先用「删除该聊天」以外的
  路径产生新的入站消息。
- 群聊「聊天信息(N)」页做同样居中处理，属用户要求之外的一致性延伸；如不需要可单独回退
  该文件。

## 6. 未改动的既有语义

- 「删除该聊天」`MatrixConversationMutation.delete` 完全未改。
- 业务 API、Matrix 服务端、`m.direct`、规范房间目录、E2EE 均未触碰。
