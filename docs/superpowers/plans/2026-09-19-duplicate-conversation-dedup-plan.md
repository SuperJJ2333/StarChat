# 修复：iOS/Android 消息列表偶现重复会话（同一好友两条）

> 依据：用户报告「iOS 和 Android 消息列表偶现两个相同聊天会话」+ 四项重点核查要求。
> 核实方法：全部结论以 file:line 证据为准（见下文），已逐文件复核。
> 用户决策（2026-09-19）：
> - D1 孤儿房间处置 = **展示去重 + m.direct 收敛**（不 leave 任何房间）；
> - D2 LEGACY 无仲裁建房路径 = **保留 + 加强架构守卫测试**。
> 状态：**已批准，实施中**。

## 一、根因（file:line 证据）

**直接原因：会话列表逐行展示 joined Matrix 房间，无按对端身份去重。** 同一好友在 `m.direct`
账号数据中挂了多个已加入房间时，每个房间 `isDirectChat==true` 且 `directPeerId` 相同 →
渲染两条"相同会话"。

- 数据源：`MatrixConversationCapability.snapshot()`（`lib/features/matrix/matrix_e2ee_client.dart:727-751`）
  遍历 `client.rooms` 投影；`isDirect/directPeerId` 直读 m.direct（`matrix_e2ee_client.dart:997-998`）。
- 列表：`lib/features/matrix/matrix_home_page.dart:1044-1067` visibleRooms →
  `orderConversations`（`conversation_preferences.dart:180-201`，仅排序无去重）→ ListView。
- m.direct 多房间来源：SDK `addToDirectChat`
  （`third_party/matrix/lib/src/room.dart:1320-1336`）**只追加不清除**；
  `getDirectChatFromUserId`（`third_party/matrix/lib/src/client.dart:452-470`）只取最近一个，
  但列表全展示。
- 多房间产生路径：
  1. 历史房间（协调机制上线前/旧版 App 创建）一直 joined 且登记在 m.direct；canonical
     目录只管新建、不回收旧房。
  2. `createEncryptedDirectRoom(avoidRoomId)`
     （`lib/features/matrix/matrix_direct_chat_adapter.dart:220-237`）旧房不健康时显式新建第二个房。
  3. LEGACY 无仲裁路径仍在 `lib/`（`direct_chat_service.dart:24-70`、
     `direct_chat_controller.dart:128-183`、`matrix_e2ee_client.dart:6413-6417`），仅架构守卫
     测试拦截（`test/features/matrix/room_opening_policy_test.dart:437-466`），非编译期。

### 四项重点核查结论

1. **DM 创建流程已有三层 single-flight，同一 userPair 同时只有一个创建任务已成立**：
   `DirectMessageOpenGate`（`direct_chat_entry.dart:149-179`，per 业务 userId）→
   `DirectChatController._openings`（`direct_chat_controller.dart:191-217`，per matrixUserId，
   同一好友两种 key 经 1:1 映射等价于 pair key）→ 服务端 claim/publish 一次性建房授权 +
   `direct_room_reservations` 唯一对约束（`services/business-api/app/modules/friendship/service.py:238-260`、
   `direct_room_coordinator.py:12-34`）。断网/失败路径一律只复用不新建
   （`coordinated_direct_chat.dart:74-111`）。本次补测试证明，不重复造机制。
2. **`cached_direct_room_directory.dart` 天然保证唯一映射，无需合并策略**：per-peer 只存一个
   roomId 字符串（覆盖式写入 `:25/:60`），带 per-peer 刷新单飞 + registerRoom 版本号失效
   （`:16-31/:52-64`）。该类未接入生产（生产用 `ApiDirectRoomCoordinator` +
   `PreferencesDirectRoomIntentStore`），**保持不接线**。多 roomId 映射实际存在于 m.direct →
   收敛在那里做。
3. **消息列表直接展示 Matrix rooms（确认）** → 新增 `ConversationIdentityResolver`。
4. **Matrix sync 不是简单 append**：内存 `_updateRoomsByRoomUpdate`
   （`third_party/matrix/lib/src/client.dart:2750-2855`）与 SQLite `storeRoomUpdate`
   （`third_party/matrix/lib/src/database/matrix_sdk_database.dart:1226`）均按 roomId upsert；
   冷启动 `getRoomList` 按 roomId 去重（`client.dart:2052-2056`）。roomId 维度已 merge，缺的是
   **对端身份维度** → 由 Resolver 补齐并补回归测试锁死。

## 二、修改方案

### A. 新增 `lib/features/matrix/conversation_identity_resolver.dart`（纯函数）
- 输入 `List<MatrixConversationRoomSnapshot>` + `selfUserId`；输出去重后列表。
- 身份 key：私聊 = `sorted([me, directPeerId]).join('|')`；群聊 = roomId。
- 同 key 胜者：`lastActivityAt` 最新 → roomId 字典序兜底（确定性、零网络，与 SDK
  `getDirectChatFromUserId` "最近活跃"口径一致）。落选房间仅从列表隐藏，不 leave、不改成员关系。
- preference 各房间独立保留，胜者的 preference 正常生效。

### B. `matrix_e2ee_client.dart` — snapshot() 出口应用 Resolver
- `snapshot()` 组装 rooms 处经 Resolver 去重。数据源层修复，消息 Tab 与 `main.dart`
  previewOnly 占位列表同时受益。UI 层零改动。

### C. 新增 `lib/features/matrix/direct_room_directory_convergence.dart`（m.direct 收敛）
- 扫描 `client.directChats`：某 peer 挂多个 joined 房间时，胜者 = 服务端 canonical roomId
  （经 `ApiDirectRoomCoordinator.canonicalRoomId`，可达时）；不可达则按最新活跃本地选定。
  `setAccountData('m.direct', …)` 重写该 peer 为单条目。**绝不 leave/forget 任何房间**。
- 挂载点：`MatrixConversationCapability.convergeDirectRoomDirectory()`；由
  `matrix_home_page.dart._processPendingDirectInvites()`（`:305-313`）调用——首 sync 后、
  列表展示前；失败静默、下次 sync 重试。
- 收敛后 Resolver 仍兜底：两层独立生效。

### D. LEGACY 处置（保留 + 加强守卫）
- 扩展 `test/features/matrix/room_opening_policy_test.dart` 架构守卫，断言 `lib/` 生产代码
  不出现 `createOrGetDirectChat(`、`openOrCreateViaGateway(`、`CanonicalDirectChatGateway(`。
- 不改 `cached_direct_room_directory.dart`。

### E. 边界（不改）
- SDK fork 不改（sync 合并语义已正确）；服务端不改（claim/publish + 唯一约束已足够）；
  不触碰 E2EE 边界；不 leave 房间。

## 三、测试（TDD 红→绿；手写 fake，不放共享夹具跨项复用）

| # | 文件（test/features/matrix/） | 场景 |
|---|---|---|
| 1+2 | `direct_room_creation_single_flight_test.dart` | 连点 10 次 → createOnce ≤1；弱网（canonical 超时 + claim 丢响应重放同 attemptId）→ 仍 ≤1 |
| — | `conversation_identity_resolver_test.dart` | 同 peer 双房间 → 一行；胜者规则；群聊不受影响；幂等；隐藏不复活 |
| — | `direct_room_directory_convergence_test.dart` | canonical 可达/不可达两分支收敛为单条目；单房间不动；断言未 leave |
| 3 | `conversation_list_restart_recovery_test.dart` | 恢复出双房间 → snapshot 一行；再次重建快照（模拟重启）→ 仍一行 |
| 4 | `conversation_list_lifecycle_test.dart` | background→foreground 刷新风暴下列表唯一（widget 测试，iOS/Android 共用代码路径） |

## 四、门禁与证据

1. `flutter analyze` 0 issue → `flutter test test/features/matrix` → 全量
   `flutter test --timeout 120s`（基线 3173+）→ `pwsh -NoProfile -File scripts/verify.ps1`。
2. 证据（命令/退出码/hash/日志）写 `docs/verification/`；任务记录
   `docs/workflow/tasks/2026-09-19-duplicate-conversation-dedup.md` 按 task-template 建档。
3. 真机复验（连点/弱网/重启/前后台四场景）记验收台账，待用户反馈。

## 五、涉及文件

| 操作 | 文件 |
|---|---|
| 新增 | `lib/features/matrix/conversation_identity_resolver.dart` |
| 新增 | `lib/features/matrix/direct_room_directory_convergence.dart` |
| 修改 | `lib/features/matrix/matrix_e2ee_client.dart` |
| 修改 | `lib/features/matrix/matrix_home_page.dart` |
| 修改 | `test/features/matrix/room_opening_policy_test.dart` |
| 新增测试 | 5 个新测试文件（见上表） |
| 文档 | 计划/任务记录/验证证据 |

## 六、第二轮扩展（2026-09-19 用户细化需求，实现中）

在第一轮（展示去重 + m.direct 收敛）基础上，按用户细化规格补齐：

### F. Primary room 选择规则（对话身份层的确定性裁决）

同一 conversationKey 多个房间时依次比较（`conversation_identity_resolver.dart`）：

| 优先级 | 规则 | 数据源 |
|---|---|---|
| 0 | 可见房间优先（产品护栏：被删除的重复房间不得压制可见房间） | preference.hidden |
| 1 | canonical roomId（服务端映射命中候选时优先） | DuplicateRoomRegistry（收敛服务仅在 canonical 裁决时登记） |
| 2 | 本地消息数量最多（避免进入空白新房间） | 本会话已解密缓存条数（保守代理，零 SDK 副作用） |
| 3 | lastActivityAt 最新 | 快照排序锚点 |
| 4 | roomId 字典序兜底 | 确定性 |

### G. DuplicateRoomRegistry（第十二节：历史孤儿房间台账）

`lib/features/matrix/duplicate_room_registry.dart`：记录
`{duplicateRoomId, primaryRoomId, peerId, detectedAt}`；按账号持久化
（SharedPreferences JSON，上限 500 条，超限淘汰最旧）；**只记录不删除**，
供 primary 规则、未来数据迁移/历史检索/问题排查使用。收敛服务仅在服务端
canonical 裁决时登记——本地规则选出的落选者不登记，避免弱证据覆盖权威映射。

### H. 全 APP 唯一 conversation（第八节：入口普查结论）

全 lib 扫描 `.rooms` 枚举（Explore 代理复核）：

| 入口 | 结论 |
|---|---|
| 消息列表 | ✅ snapshot 出口已接线 |
| 搜索聊天（群聊分节） | ✅ 经 `conversations.snapshot()` |
| 搜索聊天（聊天记录分节） | ⚠️ 按消息命中聚合（B 类），重复房间各成一行——剩余风险，见下 |
| 转发/分享/群发 | ✅ 本轮接入：`MatrixRoomLease.forwardingDestinations()` 经 `resolveIdentityRepresentatives`（三条入口共用此数据源） |
| 最近联系人 / 独立分享选择器 | 不存在独立入口（grep 证实），由转发目标覆盖 |
| 通讯录群聊页 | ✅ 经 snapshot（纯群聊按 roomId 本就唯一） |

### I. 架构守卫（第十三节）

新增 `test/features/matrix/conversation_identity_architecture_guard_test.dart`：
1. lib/ 内任何 `.rooms` 枚举必须登记在允许清单（附理由）——新增未登记点即测试失败，强制评审；
2. 两处展示出口（snapshot / forwardingDestinations）必须引用身份解析，且解析器暴露 primary/消息数注入点。

### J. 生产接线

`MatrixSdkE2eeClient` 新增可选 `duplicateRooms` 参数（测试不注入 → 用例封闭）；
`lib/main.dart` 生产构造点注入 `DuplicateRoomRegistry()`。

## 七、方案 A：落选房间未读并入主行（2026-09-19 第三轮，用户批准）

**背景**：身份解析隐藏落选房间后，对方（尤其旧版本 App）写进落选房间的消息
有系统通知、计入总未读角标，但列表无行——用户可感知为"丢消息"。

**设计**：
- `resolveConversationIdentitiesDetailed` / `resolveIdentityResolution`：
  返回 `ConversationIdentityResolution{representatives, duplicatesByRepresentativeId}`
  （代表 + 按代表 roomId 分组的落选者）；原列表出口保持不变。
- `MatrixConversationRoomSnapshot` 新增 `duplicateUnreadCount`（默认 0）。
- `snapshot()`：对每个落选者用与消息页一致的读态公式
  （`ConversationReadState.unreadCount`）计算未读并求和，生成带
  `duplicateUnreadCount` 的主行快照副本（纯函数，逐快照独立计算不叠加）。
- 消息页 `_conversationUnread`：末尾 `+ room.duplicateUnreadCount`
  （在 BUG-11 黑名单早退**之后**，屏蔽语义不被合并值穿透）。

**测试**：resolver 详细分组用例 + `duplicate_unread_merge_test.dart`
（合并 5 条/不叠加/无落选为 0）。
