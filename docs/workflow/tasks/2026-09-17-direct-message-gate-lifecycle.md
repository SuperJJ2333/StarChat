# 任务记录：DirectMessageOpenGate 生命周期边界修复（Room A 内再次「发消息」无反应）

## 恢复入口

- 目标、用户授权来源及边界：用户 2026-09-17 真机复现
  「通讯录 → 好友 → 好友资料 → 发消息 → Room A → 再进入好友资料 → 再点发消息 → 完全没反应」，
  定位为 `DirectMessageOpenGate` 的锁定范围覆盖了整个 `Navigator.push(RoomPage)` 生命周期，
  要求**只修这个生命周期边界问题**。用户明确边界：不改 `RoomNavigationCoordinator` 核心状态机语义、
  不改 `open()` 的「等待页面关闭后完成」语义，不改 `MatrixRoomLease` / `DirectChatController` /
  `CoordinatedDirectChatGateway` / canonical 仲裁 / E2EE / Matrix SDK adapter / 通话 / 群聊 /
  朋友圈 / 通知推送 / 登录切换 / Navigator 总体架构；不 pull、不真机测试、不构建 APK/IPA、不部署。
  要求新增集成级回归测试（穿过真实
  `_openMessage → DirectMessageOpenGate → resolveFriendContact → directChats.open → RoomNavigationCoordinator`）、
  Gate 释放断言、慢身份解析并发断言、retry 断言、两个变异探针，并按 15 节格式报告。
- 关联计划/ADR：无独立计划或 ADR（单点生命周期边界修复，未触碰受保护变更）。
  根因与验证：[2026-09-17-direct-message-gate-lifecycle](../../verification/2026-09-17-direct-message-gate-lifecycle.md)。
- 当前状态：实现与本地验证完成（analyze 0 问题、定向 162 通过、全量见下）；
  **未构建、未真机、未部署**（用户要求本次不做）。
- 负责人、工作树、文件所有权、源码 commit：主工作树 `D:\pythonProject\outsource\StarChat`
  （Flutter app `apps/mobile_flutter`）。拥有：
  `lib/app_home.dart`（仅 `_openMessage`/新增 `_resolveDirectMessageTarget`/闸门字段注释）、
  `lib/features/matrix/direct_chat_entry.dart`（`DirectMessageOpenGate` 重写 + 新增 `DirectMessageTarget`）、
  `test/features/matrix/direct_message_open_lifecycle_test.dart`（新增）、
  `test/features/matrix/direct_chat_entry_test.dart`（闸门用例改写）、
  `test/features/matrix/profile_message_route_wiring_test.dart`（接线断言更新）。
- 最后更新时间（含时区）：2026-09-17 12:4x +08（Asia/Hong_Kong）
- 下一条具体操作、必要输入、阻断的验收 ID：由用户在自己环境真机验收 A1–A3（无需构建输入，
  用户此前明确本次不构建）；无阻断项。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | 第一次「发消息」仍正常进入 Room（身份/房间各解析一次，只有 1 个 RoomPage+租约） | `_openMessage` 先 `gate.run(...)` 解析 `DirectMessageTarget`，再 `_openManagedRoom`（结构与参数未变） | 集成 Test 1：canonical 解析序列 `['@bob:test']`、1 RoomPage、`debugManagedResourceCount` +1、0 次 Matrix HTTP | 未构建 | 待用户 |
| A2 | RoomPage 打开后 Gate 已释放；Room A 内再次「发消息」不再无响应，第二次进入 `RoomNavigationCoordinator` 并 `popUntil` 原 Room，不产生第二个 RoomPage/租约 | 闸门锁定范围缩到 `_resolveDirectMessageTarget`（身份 + canonical roomId），`_openManagedRoom` 移到闸门之外；`run()` 改为 single-flight 返回同一个 Future | 集成 Test 2（第二次请求 future 完成、canonical 计数 1→2、资料页被 pop、RoomPage 1 个、租约 identical 且计数不变）、Test 3（页面未关闭时重新进入解析）；单元「房间页面仍打开时闸门已释放」 | 未构建 | 待用户 |
| A3 | stale Matrix ID / single-flight / retry 不回归 | 仍先 `resolveFriendContact` 取权威 `matrixUserId` 再 `directChats.open`；`run()` 成功与失败都释放 flight | 集成 Test 6（过期快照 `@bob:old` → 实查 `@bob:test`）、Test 4（慢身份解析并发：解析 1 次、房间查找 1 次、两个调用都完成）、Test 5（失败→弹窗→重试成功）；单元闸门 4 例（single-flight/页面仍开/失败释放/不同好友与空键） | 未构建 | 待用户 |
| A4 | `RoomNavigationCoordinator` 状态机不被破坏 | 未改动该文件（0 行） | `room_navigation_coordinator_test` 11 例全绿（active 优先 opening、opening single-flight、A→B→A popUntil、revoke 清理、push 失败清理、cancel 不阻塞其它 roomId、dispose/clear） | 未构建 | 待用户 |
| A5 | 其它「发消息」入口（消息列表/朋友圈/群聊成员/搜索）行为不变 | 这些入口传入的都是 `AppHome._openMessage`（唯一实现），只改了其内部边界 | `test/features/contacts`（含 `direct_message_identity_test` 透传用例）、`app_home_lifecycle_test`、`profile_message_route_wiring_test` 全绿 | 未构建 | 待用户 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Android | 本次**未构建**（用户要求不构建） | 工作树当前未提交 | — | — | — |
| iOS | 未构建 | — | — | — | — |
| 服务端 | 未改动 | — | — | — | — |

测试记录：

- 工具链：Flutter 3.44.9 stable（revision `6b182d2c75`）、Dart 3.12.2、Windows 10.0.19045。
  Flutter 以 SDK 内 `flutter_tools.snapshot` 直接调用（本会话沙箱曾限制 `git.exe`/`cmd.exe`）。
- `flutter analyze`（全量）→ 退出码 0，`No issues found!`（ran in 11.2s）。
- 定向：`test/features/matrix/{direct_chat_entry,direct_message_open_lifecycle,
  room_navigation_coordinator,profile_message_route_wiring,canonical_direct_chat,
  coordinated_direct_chat,direct_chat_controller}_test.dart`、`test/features/contacts`、
  `test/app_home_lifecycle_test.dart` → **162 通过 / 0 失败**。
- 红/绿：修复前新集成用例 Test 2/3/6 转红（`Expected: <2> Actual: <1>`，即第二次请求被闸门吞掉、
  资料页未被 pop）；修复后 6/6 通过。
- 变异探针（已复原，备份文件 `Compare-Object` 差异 0）：
  ① `_openManagedRoom` 放回闸门内 → Test 2/3/6 转红；
  ② 闸门遇到已有 flight 时返回永不完成的 Future（静默吞掉）→ 闸门 single-flight 单元用例与集成
  Test 4 转红。
- 全量：`flutter test` → 退出码 0，**2835 通过 / 0 失败**（本任务前 2826；+6 新增集成用例、
  +3 净增闸门单元用例），日志
  `docs/verification/artifacts/2026-09-17/flutter-full-direct-message-gate-lifecycle.txt`。
- 未执行项：未构建 APK/IPA、未安装真机、未部署服务端；
  未执行全量 `dart format`（本仓库格式化基线早于 Dart 3.12 tall-style，
  对未改动的 HEAD 文件同样报 `Changed`，执行会产生大面积无关 diff；详见验证记录第 6 节）。

全量门禁：`flutter test` → 2835 通过 / 0 失败（退出码 0）；`flutter analyze` → No issues found!。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 调用链通读（gate/coordinator/app_home/测试台） | 06:2x +08 | 06:4x | 主动 | — | 源码追踪 | — |
| 集成测试台搭建 + 红 | 06:4x | 12:2x | 主动（含沙箱受限返工：`git.exe`/`cmd.exe` 被拒、Flutter 缓存不可写） | — | 3 用例按预期转红 | — |
| 修复实现（gate + `_openMessage`） | 12:2x | 12:26 | 主动 | — | 定向 34 通过 | — |
| 变异探针 A/B 与复原 | 12:26 | 12:3x | 主动 | — | 2/2 按预期转红，复原差异 0 | — |
| analyze + 定向 + 全量 | 12:3x | 进行中 | 工具等待 | 全量后台运行 | analyze 0 问题；定向 162 通过 | — |
| 文档与索引 | 12:4x | 进行中 | 主动 | — | — | — |

总墙钟：约 6 小时（含沙箱受限的排查与返工，未逐段精确计时，不估成精确值）。

## 交接与回退

- 已确认根因：闸门锁定范围覆盖 `await Navigator.push(RoomPage)`（该 Future 只在页面关闭后完成），
  于是 Room A 打开期间同一好友的第二次「发消息」在 `claim()` 处被静默丢弃，无法到达
  `RoomNavigationCoordinator` 的 `popUntil`。已排除：coordinator 的 roomId 去重、
  `DirectChatController._openings`、canonical 房间仲裁、RoomLease 生命周期（均未参与该次丢失）。
- 行为变更（需知悉）：
  1. 闸门从「同一好友在途/已打开期间忽略重复点击」改为「同一好友在途期间复用同一个 Future」：
     并发第二次点击现在会拿到同一 `DirectMessageTarget` 并交给协调器（幂等回到原房间），
     不再静默丢弃。
  2. 闸门释放点从「RoomPage 关闭」提前到「canonical roomId 解析完成 / 解析失败」。
  3. `_openMessage` 在 `_openManagedRoom` 之前增加 `mounted` 守卫（页面已销毁时不再取租约再取消）。
- 待办及验收失败项：A1–A5 待用户真机验收；无已知失败项。
- 已发布与仅候选的区别：本次没有任何构建产物或发布，仅为本地源码修复 + 测试证据。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不适用（未触碰生产）。
- 运行中 CI/命令/自己创建的隧道（无凭据）：无。
- 下次恢复先检查的事实：`_openMessage` 的闸门闭包是否仍只有 `_resolveDirectMessageTarget`；
  `DirectMessageOpenGate.run` 是否仍是 single-flight 且成功/失败都释放；
  `RoomNavigationCoordinator` 是否仍未改动。
