# 任务记录：重复会话去重（2026-09-19）

## 恢复入口

- 目标、用户授权来源及边界：修复「iOS/Android 消息列表偶现两个相同聊天会话」。用户授权四项重点（single-flight 核查、cached_direct_room_directory 核查、ConversationIdentityResolver、sync merge 核查）+ 四项测试；已确认 D1=展示去重+m.direct 收敛（不 leave）、D2=LEGACY 保留+加强守卫。
- 关联计划/ADR：`docs/superpowers/plans/2026-09-19-duplicate-conversation-dedup-plan.md`
- 当前状态：验证通过，待真机
- 负责人、工作树、文件所有权、源码commit：ZCode；本任务拥有 `apps/mobile_flutter/lib/features/matrix/{conversation_identity_resolver,direct_room_directory_convergence}.dart`、`matrix_e2ee_client.dart`、`matrix_home_page.dart` 及 test/features/matrix 下 5 个新测试；基线 commit `b308598d4711349f02bcc3873b01b8a47c0cd3a3`
- 最后更新时间（含时区）：2026-09-19 15:00 +0800
- 下一条具体操作、必要输入、阻断的验收ID：真机复验四场景（连点/弱网/重启/前后台），需 Mi 6 + iOS 设备反馈；阻断 A1–A5 真机列

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | 连续点击好友"发消息"10次 → 只有一个 room | 既有三层 single-flight 保持 | direct_room_creation_single_flight_test 3 用例绿（闸门合并/控制器并发/原始并发均 createOnce ≤1） | — | 待真机 |
| A2 | 弱网创建聊天 → 不产生两个 room | 既有协调网关只复用不新建 | 同上 2 用例绿（目录超时重试/结果不确定重放均不二次 create） | — | 待真机 |
| A3 | 同一好友双房间 → 列表唯一（重启恢复） | ConversationIdentityResolver + snapshot() 接入 | conversation_identity_resolver_test 9 用例 + conversation_list_restart_recovery_test 2 用例绿 | — | 待真机 |
| A4 | iOS/Android 生命周期切换 → 列表唯一 | Resolver 兜底 | conversation_list_lifecycle_test 绿（paused→resumed + 3 轮 sync 风暴） | — | 待真机 |
| A5 | m.direct 同 peer 多 roomId → 收敛单条目，不 leave | direct_room_directory_convergence + 挂载 | direct_room_directory_convergence_test 6 用例绿；守卫测试 22 用例绿 | — | 待真机 |
| B1 | canonical room 存在 → 列表选中 canonical（规则一） | Resolver primaryRoomIdOf + DuplicateRoomRegistry | resolver 测试 + convergence 登记 2 用例 + forward_destination_dedup 2 用例绿 | — | 待真机 |
| B2 | 旧 room 消息更多 → 选消息多的 room（规则二） | localMessageCountOf（解密缓存代理） | resolver 测试 2 用例绿 | — | 待真机 |
| B3 | 转发/分享/群发目标同好友唯一入口 | forwardingDestinations 接入 resolveIdentityRepresentatives | forward_destination_dedup_test 2 用例绿；架构守卫 `.rooms` 允许清单 | — | 待真机 |
| B4 | 生产代码禁止直接展示 client.rooms | conversation_identity_architecture_guard_test | 2 用例绿（清单完备 + 出口接线断言） | — | — |
| B5 | 落选房间未读并入主行（方案 A） | detailed resolution + duplicateUnreadCount + 消息页累加 | duplicate_unread_merge_test 3 用例 + resolver 详细分组用例绿 | — | 待真机 |

门禁（2026-09-19，混合工作树）：`flutter analyze` 0 issue（exit 0）；`flutter test test/features/matrix --timeout 120s` 1696 通过（exit 0）；`flutter test --timeout 120s` 3469 通过（exit 0）；`pwsh -NoProfile -File scripts/verify.ps1` → `Verification: PASS`（exit 0）。证据：`docs/verification/2026-09-19-duplicate-conversation-dedup.md`。

第二轮（B 组）门禁：`flutter analyze` 0 issue（exit 0）；`flutter test test/features/matrix --timeout 120s` 1710 通过（exit 0）；全量与 verify.ps1 见验证证据文档（第二轮追加记录）。

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| —（纯客户端代码修复，未构建） | — | b308598d+ | — | — | — |

测试记录：命令与真实退出码见 `docs/verification/2026-09-19-duplicate-conversation-dedup.md`（收口时写入）。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 调查 | 2026-09-19 13:40 +0800 | 2026-09-19 14:00 +0800 | 工具（3 个探索代理并行 + 主线程复核） | 是 | 会话记录 | 实现 |
| 实现 | 2026-09-19 14:01 +0800 | 2026-09-19 14:20 +0800 | 主动（TDD 红绿 5 轮） | 否 | 会话记录 | 门禁 |
| 门禁与证据 | 2026-09-19 14:20 +0800 | 2026-09-19 15:00 +0800 | 工具（analyze/定向/全量/verify.ps1；含契约修正返工 1 次：hidden 快照契约） | verify.ps1 与证据撰写并行 | 会话记录 + 退出码 | 待真机 |

## 交接与回退

- 已确认根因：列表逐行展示 joined 房间、无按对端身份去重；同一好友 m.direct 挂多个 joined 房间时出现两条（计划文档一节有完整 file:line 证据）。
- 已排除假设：sync 简单 append（实际 roomId upsert）；cached_direct_room_directory 多映射（实际单值覆盖）；生产主路径并发建房竞态（三层 single-flight + 服务端授权已闭合）。
- 待办及验收失败项：自动化测试全部闭环；仅剩 A1–A5 真机复验待用户反馈。
- 已发布与仅候选的区别：本轮全部为候选代码，未构建未发布。
- 生产备份位置、恢复操作：不适用（无生产变更）；回退 = 还原本轮涉及文件。
- 运行中CI/命令：无。
- 下次恢复先检查的事实：`git status` 中本任务文件是否完整；测试是否红→绿已闭环。
