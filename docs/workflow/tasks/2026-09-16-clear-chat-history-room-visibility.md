# 任务记录：「清空聊天记录」误删会话 + 文字居中

## 恢复入口

- 目标、用户授权来源及边界：用户 2026-09-16 在本会话中指定方案「新增
  clearedOnly / historyClearedThrough 键，`_snapshotRoom` 的 `locallyDeleted` 只读
  『删除该聊天』写的那一个键」，并要求「聊天信息」页「清空聊天记录」文字改为居中
  对齐。边界：不改业务 API、不改 Matrix 服务端行为、不改「删除该聊天」既有语义、
  不构建 APK/IPA、不做生产发布。
- 关联计划/ADR：[计划](../../superpowers/plans/2026-09-16-clear-chat-history-room-visibility.md)（无需 ADR：未触碰受保护变更）
- 当前状态：实现与本地验证完成；未构建、未发布
- 负责人、工作树、文件所有权、源码commit：主工作树（非 worktree）；基线
  `8ef5cbac4c80b49a9ad43f54f84a01bedf8dc9c8`；拥有
  `local_hidden_events.dart`、`matrix_e2ee_client.dart`、`room_page.dart`、
  `direct_chat_info_page.dart`、`group_chat_info_page.dart` 及对应测试
- 最后更新时间（含时区）：2026-09-16 22:0x（Asia/Hong_Kong）
- 下一条具体操作、必要输入、阻断的验收ID：用户真机验收「清空后会话仍在消息列表」；
  需构建 Debug 包含此改动的 APK 才能真机确认

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | 私聊「清空聊天记录」后，会话仍留在消息列表 | `clearLocalHistory` 只写 `history-cleared-through`；`_snapshotRoom` 的 `locallyDeleted` 只读 `cleared-through` | `local_history_clear_test.dart`「清空聊天记录只清本机历史，会话仍留在消息列表」（先 RED，`Expected: false / Actual: true`） | 未发布 | 待真机 |
| A2 | 清空后未加载到本机的历史同样不可见 | `lastHistoryCutoff` 合并两个截止时间 | 同上「清空截止时间同时隐藏未在本机逐条标记的历史消息」；变异探针证明可捕获回归 | 未发布 | 待真机 |
| A3 | 清空后收到新消息，会话与新消息正常显示 | 新事件时间戳晚于截止时间 → `historyCleared`/`locallyDeleted` 均为 false | 同上「清空聊天记录后收到新消息，会话与新消息都正常显示」 | 未发布 | 待真机 |
| A4 | 「删除该聊天」仍把会话移出消息列表（回归护栏） | `MatrixConversationMutation.delete` 语义不变 | 既有 `local_conversation_delete_test.dart` 两用例通过 | 未发布 | — |
| A5 | 「聊天信息」页「清空聊天记录」文字居中 | `WeChatListTile.title` 改为 `Center(child: Text(...))` | `direct_chat_info_test.dart`、`group_chat_info_test.dart` 居中用例；两者均经变异探针验证（偏移 134.2 / 130.7 px） | 未发布 | 待真机 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Android Debug（仅 Mi 6 真机） | 0.3.92-debug/2122 | `8ef5cbac` + 本次工作树改动 | `com.liuhetong.mobile`，固定身份 `75b31c66…ba61fff` | `artifacts/2026-09-16/android-0.3.92-debug-2122/ChatFlow-0.3.92-debug-2122-arm64-rebuilt.apk`，SHA256 `5153073e…fcf519d` | 2026-09-16 22:18:11 +08 覆盖安装成功，firstInstallTime 未变；**未做正式发布** |
| iOS | 未构建 | 同上 | — | — | 未发布 |
| 服务端 | 未改动 | — | — | — | 未部署 |

测试记录：

- 命令 `flutter test test/features/matrix` → 退出码 0，1312 通过 / 0 失败。
- 命令 `flutter analyze` → 退出码 0，`No issues found!`。
- 命令 `flutter test`（全量）→ 证据见
  `docs/verification/artifacts/2026-09-16/flutter-full.txt`。
- 工具版本 Flutter 3.44.9 stable / Dart 3.12.2；OS Windows 10 Pro 19045。
- 未执行项：未构建 APK/IPA，未做真机验证，未部署生产。`scripts/verify.ps1` 未运行
  （本任务无 `.env` 依赖变更，且全量 Flutter 门禁已单独执行）。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 根因定位 | 2026-09-16 21:4x +08 | 21:5x | 主动 | — | CodeGraph + 源码追踪 | — |
| RED/GREEN | 21:5x | 22:0x | 主动 | — | 见上表 | — |
| 回归与门禁 | 22:0x | 进行中 | 工具 | — | flutter test / analyze | 补齐证据 |

总墙钟：以完整起止区间计，精确值未知（未逐段计时）。

## 交接与回退

- 已确认根因/已排除假设：根因是「清空聊天记录」与「删除该聊天」共用
  `cleared-through` 截止时间键，被 `_snapshotRoom` 统一投影为 `hidden: true`。
  已排除：房间被 `leave`/`forget`、`m.direct` 被清理、会话偏好被持久化隐藏
  （该投影只在快照期计算，未写回偏好存储）。
- 待办及验收失败项：A1–A3、A5 待真机验收；需要构建包含本改动的 Debug 包。
- 已发布与仅候选的区别：本次无任何发布，全部仅为本地工作树改动。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不适用（未触碰生产）。
- 运行中CI/命令/自己创建的隧道（无凭据）：曾运行本地 `flutter test` 全量；无隧道。
- 下次恢复先检查的事实：工作树是否仍基于 `8ef5cbac`；`history-cleared-through`
  键与 `LocalHistoryClearance` 接口是否仍存在；`local_history_clear_test.dart` 是否通过。
