# 任务记录：重复会话去重（2026-09-19）

## 恢复入口

- 目标、用户授权来源及边界：修复「iOS/Android 消息列表偶现两个相同聊天会话」。用户授权四项重点（single-flight 核查、cached_direct_room_directory 核查、ConversationIdentityResolver、sync merge 核查）+ 四项测试；已确认 D1=展示去重+m.direct 收敛（不 leave）、D2=LEGACY 保留+加强守卫。
- 关联计划/ADR：`docs/superpowers/plans/2026-09-19-duplicate-conversation-dedup-plan.md`
- 当前状态：**实现继续/开放项在案**（用户纠正：不使用「仅待真机」）。已完成：项1 canonical ID 转换修复、项2 收敛后旧房间身份重关联、项3 搜索逻辑会话归并+readOnly 贯通、项4 摘要取组内最新+逐房间已读回执、项5-3 网络恢复自动继续、项6 真实 SDK 组合测试。**开放项**：项5-1 换设备招呼重发（需发送前历史核查）、项5-2 授权预约卡死（需服务端 ADR 决策）、OpenAPI 契约漂移（并行任务修复后重跑 verify.ps1）、真机四场景复验。
- 负责人、工作树、文件所有权、源码commit：ZCode；本任务拥有 `apps/mobile_flutter/lib/features/matrix/{conversation_identity_resolver,direct_room_directory_convergence,duplicate_room_registry}.dart`、`matrix_e2ee_client.dart`、`matrix_home_page.dart`、`room_navigation_coordinator.dart`、`room_page.dart`、`lib/main.dart` 及 test/features/{matrix,search} 下本任务测试；基线 commit `b308598d`，阶段提交 `ac01f7cf`、`37357c66`
- 最后更新时间（含时区）：2026-09-19 21:30 +0800
- 下一条具体操作、必要输入、阻断的验收ID：项5-2 需服务端 ADR 决策（授权接管/二次授权契约）；真机复验需 Mi 6 + iOS 设备反馈

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

## 第四轮追加台账（2026-09-19 晚，用户纠正后）

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| C1 | canonical 查询用业务 userId（matrixId 转换） | convergeDirectDirectory.businessUserIdOf + 消息页好友目录转换 | direct_room_identity_integration_test 项1 两用例绿 | — | 待真机 |
| C2 | 收敛后旧房间不以普通房间重现 | snapshot 经 registry.entryForRoom 重关联身份 | 组合测试项2 用例绿（前置断言 isDirectChat 已丢失） | — | 待真机 |
| C3 | 搜索按逻辑会话归并，保留 sourceRoomId+eventId | aggregateConversationHits.primaryRoomIdOf + 控制器/页面接线 | logical_conversation_search_test 4 用例绿 | — | 待真机 |
| C4 | 孤儿房间经搜索/通知只读定位，不可独立发送 | RoomOpenRequest.readOnly + normalizeDuplicateRoomOpen + RoomPage 输入区门控 | 归一化纯函数用例绿；RoomPage 门控待 widget 用例补强 | — | 待真机 |
| C5 | 列表摘要取身份组内最新事件 | _mergeDuplicateConversationState | 合并测试（含未读）绿；摘要专项断言待补 | — | 待真机 |
| C6 | 首次建房网络恢复自动继续 | PendingConversationPage._onNetworkChanged 恢复沿重试 | pending_conversation_outbox_test 项5-3 绿 | — | 待真机 |
| C7 | 真实 SDK 身份链路组合证明 | direct_room_identity_integration_test（无 isDirectChat 替身） | 4 用例绿（含打开时间线） | — | — |

### 开放项（不得标"仅待真机"）
1. **项5-1 残余**：换设备/重装后招呼可能重发一次——需"发送前查房间历史同 txid/request_id"纵深防御（客户端可做，未排入本轮）。
2. **项5-2 阻塞**：建房授权预约永不过期是服务端有意设计；卡死恢复需服务端契约变更（ADR 决策点：owner 二次授权/带校验接管）。客户端擅动会重新打开重复建房窗口。
3. **OpenAPI 契约漂移**：并行批次服务端在途改动所致；须其修复后重跑 verify.ps1 验证 PASS。
4. **真机复验**：连点/弱网/重启/前后台 + 搜索定位只读打开 + 通知点击路由。
