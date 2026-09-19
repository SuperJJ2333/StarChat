# 验证证据：重复会话去重（2026-09-19）

任务：`docs/workflow/tasks/2026-09-19-duplicate-conversation-dedup.md`
计划：`docs/superpowers/plans/2026-09-19-duplicate-conversation-dedup-plan.md`
基线 commit：`b308598d4711349f02bcc3873b01b8a47c0cd3a3`

## 环境与工具

| 项 | 值 |
| --- | --- |
| OS | Windows 10 (10.0.19045) x64，MINGW64/Git Bash + pwsh |
| Flutter | 3.44.9 stable，framework 6b182d2c75（2026-08-05） |
| Dart | 3.12.2 (stable) windows_x64 |
| 时区 | +0800 |

## 改动文件（SHA256，验证时点 2026-09-19 14:35 +0800）

| 文件 | SHA256 |
| --- | --- |
| lib/features/matrix/conversation_identity_resolver.dart（新增） | 094A34A0520DBABDD8929E45FA53AA018485DE94AF9BA9977A679289281EC5DC |
| lib/features/matrix/direct_room_directory_convergence.dart（新增） | EA186F8370688B642EBE7B9F2476308BA7B081A86A3593551F3B2F577E2E4007 |
| lib/features/matrix/matrix_e2ee_client.dart | DDCE6B60F22136F8A6C6BBCE87BEFEC9AC0DFCDB8F7E3BB948872D10E122FE7F |
| lib/features/matrix/matrix_home_page.dart | FA284AC90D12B8E388A3CAD11601591FEBC1853870704CA2115051A718498188 |
| test/features/matrix/room_opening_policy_test.dart | DFFD5F753544D992227F44EF6C3197F9AB5D1C8EFA25FF48632FC7C3F179899C |

新增测试文件：`conversation_identity_resolver_test.dart`、`conversation_list_restart_recovery_test.dart`、`direct_room_directory_convergence_test.dart`、`direct_room_creation_single_flight_test.dart`、`conversation_list_lifecycle_test.dart`。

## 门禁记录（命令 + 真实退出码）

| 门禁 | 命令 | 退出码 | 结果 |
| --- | --- | --- | --- |
| Analyze | `flutter analyze`（apps/mobile_flutter） | 0 | No issues found! |
| 定向套件 | `flutter test test/features/matrix --timeout 120s` | 0 | 1696 通过，0 失败 |
| 全量套件 | `flutter test --timeout 120s` | 0 | 3469 通过，0 失败 |
| 仓库门禁 | `pwsh -NoProfile -File scripts/verify.ps1` | 0 | 输出 `Verification: PASS`（含 alembic 迁移 PASS、OpenAPI contract PASS、Docker Compose render PASS） |

注：本工作树同时承载 0917 缺陷批次任务的在途改动（app_home/room_page/wechat_call_bubble 等，
均非本任务文件所有权）；上述全量门禁在混合工作树上通过。

## TDD 红绿证据（关键步骤）

1. `conversation_identity_resolver_test.dart` 首跑：模块不存在，编译失败（红）→ 实现 → 8/8 绿。
2. `conversation_list_restart_recovery_test.dart` 首跑：快照返回 3 行（含同 peer 重复）→
   2 失败（红）→ snapshot() 接入 Resolver → 绿。
3. 契约修正：首轮 matrix 定向套件暴露 `local_conversation_delete_test` 失败（`rooms.single`
   No element）——Resolver 曾把 hidden 房间整体丢弃，违反"隐藏会话仍在快照中"的既有契约。
   修正为"可见房间优先当选代表，隐藏房间仍保留为其身份 key 的代表"；新增契约用例
   （快照契约：单独被隐藏的会话仍保留在快照中）后全绿。
4. `direct_room_directory_convergence_test.dart` 首跑：模块不存在（红）→ 实现 → 6/6 绿。
5. `direct_room_creation_single_flight_test.dart`：原始并发用例首跑因 fake 轮询零延迟耗尽
   而抛 DirectRoomPendingException（测试时序问题，非产品缺陷）→ fake wait 改 2ms 真实节拍
   → 5/5 绿。

## 测试与用户四项场景的映射

| 用户场景 | 自动化测试 | 结论 |
| --- | --- | --- |
| 测试1：连点好友发消息 10 次 → 只有一个 room | `direct_room_creation_single_flight_test`（闸门合并 / 控制器并发 / 原始并发三档） | createOnce ≤1，全部调用方同一房间 |
| 测试2：弱网创建聊天 → 不产生两个 room | 同上（目录超时重试 / 建房结果不确定重放） | 断网只复用不新建；重放同一 attemptId 绝不二次 create |
| 测试3：App 重启恢复 → 不会重复 | `conversation_list_restart_recovery_test` | 二次冷启动恢复快照唯一 |
| 测试4：iOS/Android 生命周期模拟 → 列表唯一 | `conversation_list_lifecycle_test`（paused→resumed + 3 轮 sync 风暴） | 列表始终唯一（两端共用代码路径） |
| 数据收敛 | `direct_room_directory_convergence_test` | m.direct 同 peer 多 joined 房间收敛单条目，零 leave |

## 未执行项与复用依据

- 服务端测试套件未单独重跑（本任务零服务端改动）；`scripts/verify.ps1` 内含 business-api
  套件作为收口覆盖。
- 真机复验（连点/弱网/重启/前后台）未执行：需 Mi 6 + iOS 设备，记入任务记录验收台账，
  等待用户反馈。
- 未构建 APK/IPA：本任务为候选代码修复，构建发布按 defect-batch 流程另行出包。

## 第二轮扩展记录（2026-09-19 下午，同日用户细化需求）

新增改动：Primary room 四级规则（canonical→本地消息数→活跃→roomId）、
`DuplicateRoomRegistry`（孤儿房间台账，只记录不删除）、
`MatrixRoomLease.forwardingDestinations()` 身份去重（转发/分享/群发共用数据源）、
架构守卫测试（`.rooms` 允许清单 + 出口接线断言）、`MatrixSdkE2eeClient`
新增 `duplicateRooms` 注入点（`lib/main.dart` 生产接线）。

新增测试（红→绿）：
- `duplicate_room_registry_test.dart` 5 用例（登记/账号隔离/持久化重启/多重复/上限淘汰）
- `conversation_identity_resolver_test.dart` +4 用例（canonical 优先/消息数优先/打平回退/幂等保留）
- `direct_room_directory_convergence_test.dart` +2 用例（canonical 裁决登记/不可达不登记）
- `forward_destination_dedup_test.dart` 2 用例（字典序兜底/登记簿 primary 覆盖）
- `conversation_identity_architecture_guard_test.dart` 2 用例（`.rooms` 允许清单/出口接线）

第二轮门禁（真实退出码）：

| 门禁 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（exit 0） |
| `flutter test test/features/matrix --timeout 120s` | 1710 通过，0 失败（exit 0） |
| `flutter test --timeout 120s`（全量） | 首轮跑出 1 失败 = 并行 0917 批次在途文件 `test/ui/message_action_sheet_test.dart`（BUG-32，非本任务文件；复跑时该任务已修复）→ 复跑 **3484 通过，0 失败（exit 0）** |
| `pwsh -NoProfile -File scripts/verify.ps1` | `Verification: PASS`（exit 0） |

提交方式说明：工作树同时承载 0917 批次的在途改动，本提交对 `matrix_e2ee_client.dart`
与 `matrix_home_page.dart` 两个共享文件做了**逐 hunk 分离**（暂存内容 = HEAD + 本任务
改动，已断言不含 BUG-11/15/20/23/32 等并行任务行），其余文件为整文件暂存。

## 第三轮记录（方案 A：落选房间未读并入主行，用户批准后实施）

改动：`resolveConversationIdentitiesDetailed`/`resolveIdentityResolution`（代表+落选分组）、
`MatrixConversationRoomSnapshot.duplicateUnreadCount`（默认 0）、snapshot() 合并落选未读
（读态公式与消息页一致，逐快照独立计算）、消息页 `_conversationUnread` 末尾累加
（在 BUG-11 黑名单早退之后，屏蔽语义不被穿透）。

TDD：resolver 详细分组用例 + `duplicate_unread_merge_test.dart`（合并 5/不叠加/无落选 0）
先红后绿。

第三轮门禁（真实退出码）：

| 门禁 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（exit 0） |
| `flutter test test/features/matrix --timeout 120s` | 1722 通过，0 失败（exit 0） |
| `flutter test --timeout 120s`（全量） | **3496 通过，0 失败（exit 0）**（首轮跑出并行批次在途文件的 loading 失败，复跑时该任务已自修） |
| `pwsh -NoProfile -File scripts/verify.ps1` | **未过，基线在案**：唯一失败 `test_openapi_contract`（已提交 OpenAPI 与生成文档漂移），源于并行批次任务对 `services/business-api/app/api/identity.py`、`app/modules/identity/registration.py` 的在途改动（本任务零服务端文件，暂存清单可证；同日早些时候同套件 PASS）。该套件其余 **2077 通过，58 跳过** |

选择性提交说明：`matrix_e2ee_client.dart` 暂存内容额外剔除并行任务新写入的
BUG-23 `markRoomRead`、withdrawInvite（含重复 `@override`）等在途行；`matrix_home_page.dart`
同前剔除 BUG-11/draft 等。

## 第四轮记录（用户纠正后继续执行完整规格，2026-09-19 晚）

用户纠正：37357c66 仅是"未读投影合并"阶段件；**整体状态不得标为"仅待真机"**；
"最多 10 秒""OpenAPI 自然消除"等结论超出证据。以下为按七项要求继续执行的结果。

### 项1（修复）：canonical 查询的 ID 转换
m.direct 键是 matrixId，canonical 目录以业务 userId 为键——原实现拿 matrixId
误查目录（生产上 canonical 永远查不中、登记簿永不填充）。修复：
`convergeDirectDirectory` 新增 `businessUserIdOf` 转换器；消息页钩子经好友
目录（`contactsByMatrixId[matrixPeer]?.userId`）转换；转换缺失时跳过查询、
只用本地规则，绝不误查。测试：`direct_room_identity_integration_test.dart`
（转换器被调用、业务身份缺失时跳过查询）。

### 项2（修复）：收敛后旧房间身份丢失、以普通房间重现
收敛把旧房间移出 m.direct 后，真实 SDK 计算的 `isDirectChat` 丢失，旧房间
会以普通房间行重现。修复：snapshot 投影阶段经 `DuplicateRoomRegistry
.entryForRoom` 反查（duplicateRoomId→peerId）恢复私聊身份后再归并；纯展示
投影，不改任何 Matrix 状态。测试：组合测试第 3 例（先断言 loser.isDirectChat
== false 前置成立，再断言列表仍只有一行且 directPeerId 正确）。

### 项3+4：逻辑会话统一入口 / 搜索定位 / 摘要与回执
- `aggregateConversationHits` 新增 `primaryRoomIdOf`：孤儿房间命中归并到
  主会话分组；每条命中保留自身 roomId（sourceRoomId）+ eventId 供定位。
- 控制器/页面接线（`primaryRoomIdOf`）；映射按本轮命中逐房间解析。
- `RoomOpenRequest.readOnly` + `normalizeDuplicateRoomOpen`：搜索/通知命中
  登记在案的孤儿房间时强制只读打开（保留 roomId+anchor 定位，隐藏输入区，
  不得作为独立可发送会话出现）；归一化收敛在 `_openManagedRoomRequest`
  单一咽喉点，覆盖全部入口。
- `RoomPage.readOnly`：隐藏输入区与面板，显示"该消息来自历史会话，仅可查看"。
- 列表摘要：`_mergeDuplicateConversationState` 在未读合并外，取身份组内
  最新事件作为预览/排序锚点——落选房间的新消息不因隐藏而在摘要中消失。
- 已读回执：保持逐房间真实阅读位置（每个房间独立 read marker/manual
  unread；合并徽标 = 各房间按同一读态公式求和，各房间被实际阅读后各自清零）。
  测试：`logical_conversation_search_test.dart` 4 例。

### 项5：三个审计问题的继续处理
- **pending 交接重复发送**：核查结论 = 同设备重复已由 BUG-3 修复（持久化
  打招呼账本 + 确定性 txid + 6 项编排测试）。**残余**（在案开放）：换设备/
  重装后本地账本为空可能重发一次（原审计
  `docs/verification/2026-09-19-friend-acceptance-greeting-idempotency.md`
  已列为未实施纵深防御：发送前查房间历史同 txid/request_id）。本轮未实施。
- **建房授权响应丢失无法恢复**：核查结论 = 服务端预约行**有意**永不过期
  （`direct_room_coordinator.py` docstring、runbook
  `docs/runbooks/direct-room-coordination.md:16-20`、协调测试
  `test_pending_blocks_legacy_and_does_not_expire` 明确断言不过期）。
  客户端无法区分"对端正在建"与"预约永久卡死"（两者 claim 响应相同），
  客户端侧自动重建会重新打开重复建房窗口。**需要服务端契约决策（ADR）**
  （如 owner 持匹配 attempt 的"确认未建"二次授权，或带校验的接管端点）。
  开放项，不在客户端擅动。
- **首次建房网络恢复不自动继续**：已修复。`PendingConversationPage
  ._onNetworkChanged` 在 offline/weak → online/recovering 沿且上次尝试
  失败时自动重跑 `_start()`（`_opening/_settled` 守卫防风暴；initState
  记录网络基线）。测试：`pending_conversation_outbox_test.dart` 项5-3 用例。

### 项6：真实 SDK 组合测试
`direct_room_identity_integration_test.dart`：真实 `Room`（身份字段全部由
SDK 从 m.direct 计算，**无固定替身**；仅覆写非身份的 encrypted/timeline
载体）→ 收敛（含 ID 转换、登记）→ snapshot 唯一 → `openRoomLease` +
`openRoomTimeline` + `roomInfo.isDirect` 断言。4 用例。

### 项7：结论更正（在案）
- 「canonical 等待最多 10 秒」仅适用于 claim 已有结论后的轮询窗口
  （20×500ms）；**授权响应丢失/预约卡死不受此界**，可持续存在——两项结论
  不可混用。
- 整体状态改为「实现继续/开放项在案」，不使用「仅待真机」。
- verify.ps1 的 OpenAPI 契约漂移 = 并行批次服务端在途改动；**须在该任务
  修复后重新运行 verify.ps1 验证 PASS 才可关闭**，不得预设自然消除。

### 第四轮门禁（真实退出码）

| 门禁 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（exit 0） |
| `flutter test test/features/matrix test/features/search --timeout 120s` | 1791 通过，0 失败（exit 0） |
| `flutter test --timeout 120s`（全量） | **3515 通过，0 失败（exit 0）** |

第四轮阶段提交：`fe9f178b`（前序：`ac01f7cf` 身份解析与收敛、`37357c66` 未读投影合并）。
选择性提交同前：四个共享文件（e2ee/home/app_home/room_page）均为 HEAD+本任务改动
（逐 hunk 分离，已断言不含并行任务 BUG-11/14/15/16/20/23/32 与 ignore-list 等在途行）。
