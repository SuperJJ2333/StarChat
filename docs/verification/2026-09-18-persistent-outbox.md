# 持久化出站消息层（Persistent Outbox）验证记录 — 2026-09-18

任务：`feat(message): add persistent outbox reliable messaging layer`
范围：用户「可靠外发消息」15 条规格中第 1–10 条（持久化队列、txid 幂等、先落盘后发送、
网络策略、调度器、启动恢复、pending conversation 落盘、状态词表、测试）。

不重设计会话入口：`RoomOpeningPolicy`、`RoomNavigationCoordinator`、Session Gateway、
`PendingConversationPage` 整体设计、Matrix SDK/Olm/Megolm/加密、建房协议均未改动。
未新增任何 pubspec 依赖（复用 `sqflite_common_ffi` + `path_provider` + `uuid`，与
`MomentsPageStore` / `SqliteProfileStore` 同一持久化通道）。

---

## 1. 修改文件列表

新增（`lib/core/**`，本线独占）：

| 文件 | 作用 |
| --- | --- |
| `apps/mobile_flutter/lib/core/outbox/outbox_message.dart` | `OutboxMessage` 模型 + `OutboxStatus` 状态机 + 文案 + `textsWithoutOutboxRows` 抵扣纯函数 |
| `apps/mobile_flutter/lib/core/outbox/outbox_store.dart` | `OutboxStore` 接口、`SqliteOutboxStore`（`chatflow_outbox_v1.db` / `outbox_messages`）、`InMemoryOutboxStore` |
| `apps/mobile_flutter/lib/core/outbox/persistent_outbox_manager.dart` | `PersistentOutboxManager`（save/queryPending/updateStatus/claim/removeOrArchive/recoverOnStartup/bindRoomForReceiver）+ `OutboxJournal` 注入接缝 |
| `apps/mobile_flutter/lib/core/outbox/message_send_scheduler.dart` | `MessageSendScheduler` + `OutboxSender`/`OutboxLease`/`OutboxLeaseFactory` |
| `apps/mobile_flutter/lib/core/outbox/outbox_room_sender_registry.dart` | 已打开房间的发送句柄注册表 |
| `apps/mobile_flutter/lib/core/outbox/outbox_recovery_service.dart` | `OutboxRecoveryService` + `OutboxRecoveryReport` |

修改（均为本线拥有的文件）：

| 文件 | 改动 |
| --- | --- |
| `apps/mobile_flutter/lib/features/matrix/room_timeline_controller.dart` | 构造器新增 `outboxJournal`；`sendText` 返回 `Future<String?>`；派发顺序改为「创建乐观行 → 先持久化 → 原子认领 → 派发 → 落定状态」；新增 `restoreOutboxMessage`；新增 `RoomDeliveryState ↔ OutboxStatus` 唯一映射；重试/网络恢复/手动重试沿用同一 txid |
| `apps/mobile_flutter/lib/features/matrix/room_page.dart` | 新增 `outbox` 参数、房间级 `OutboxJournal`、`_RoomOutboxSender`（注册到 registry）、`_flushInitialOutbox` 改为「绑定未绑定行 → 持久化行优先 + 原文按多重集抵扣兜底 → failed 只恢复展示」、`dispose` 注销句柄 |
| `apps/mobile_flutter/lib/features/matrix/pending_conversation_page.dart` | 新增 `outbox`/`recovery` 参数；输入即写持久化 outbox（乐观展示 + 同一 localId/txid 落盘）；列表渲染 outbox 行与状态文案；房间就绪后后台绑定 roomId；`PendingConversationResult` 新增 `outboxLocalIds`（`queued` 语义保留为降级兜底原文） |
| `apps/mobile_flutter/lib/app_home.dart` | **仅接线**：`_bindOutbox`（账号级 shared manager + scheduler + 启动恢复）、`_openOutboxLease`/`_MatrixOutboxLease`（只发送、不导航的临时租约）、`_disposeOutbox`、把 `outbox`/`recovery` 注入 `PendingConversationPage` 与 `RoomPage` |

新增测试：`test/core/outbox/persistent_outbox_manager_test.dart`、
`test/core/outbox/message_send_scheduler_test.dart`、
`test/features/matrix/outbox_send_flow_test.dart`、
`test/features/matrix/pending_conversation_outbox_test.dart`。

## 2. 新增数据库结构

文件：应用支持目录下 `chatflow_outbox_v1.db`（与 `chatflow_profile_v1.db` / `chatflow_moments_audience_v2.db` 同目录，账号无关的库，行内带账号命名空间）。
建表语句集中定义在 `SqliteOutboxStore.createTableStatements`（测试直接断言该结构）：

```sql
CREATE TABLE outbox_messages (
  local_id     TEXT    NOT NULL PRIMARY KEY,   -- 本地主键（UUID，创建时生成一次）
  txid         TEXT    NOT NULL,               -- Matrix 事务 ID / 幂等键
  room_id      TEXT,                           -- 目标房间；会话未建立时为 NULL
  receiver_id  TEXT    NOT NULL,               -- 单聊=对端 Matrix 用户 ID，群聊=房间 ID
  account_id   TEXT    NOT NULL DEFAULT '',    -- 账号命名空间（matrix.userId）
  content      TEXT    NOT NULL,               -- 正文（仅文本消息进入本层）
  status       TEXT    NOT NULL,               -- queued|sending|waitingNetwork|failed|sent
  retry_count  INTEGER NOT NULL DEFAULT 0,
  created_at   INTEGER NOT NULL,               -- 毫秒时间戳
  updated_at   INTEGER NOT NULL,
  last_error   TEXT
);
CREATE UNIQUE INDEX outbox_messages_txid    ON outbox_messages (txid);
CREATE INDEX        outbox_messages_pending ON outbox_messages (account_id, status, created_at);
CREATE INDEX        outbox_messages_room    ON outbox_messages (room_id, status, created_at);
```

键与语义：
- `PRIMARY KEY(local_id)`：一行一条消息；
- **`UNIQUE(txid)`：数据库层面的幂等保证** —— 同一事务 ID 永远只有一行，重复插入被
  `ConflictAlgorithm.ignore` 吞掉并由 `byTxid` 返回既有行；
- `outbox_messages_pending`：调度器扫描 `queued/waitingNetwork`；
- `outbox_messages_room`：进入房间后的恢复扫描；
- 送达（`sent`）后行会被删除（`removeOrArchive`）：已确认送达的正文留在本地没有恢复
  价值，只会扩大明文暴露面。

## 3. 消息状态机

持久化状态（`OutboxStatus`）与内存投递状态（`RoomDeliveryState`）唯一映射
（`outboxStatusOf` / `roomDeliveryStateOf`，见 `room_timeline_controller.dart`）：

| OutboxStatus | 文案 | RoomDeliveryState | 进入条件 | 出口 |
| --- | --- | --- | --- | --- |
| `queued` | 等待发送 | `local` | 创建并落盘后、尚未派发（含离线/无网络时的初始状态） | 派发前 `claim` → `sending`；房间未建立时保持 |
| `sending` | 发送中 | `sending` | 原子认领成功，已交给传输层 | `sent`（确认）/`waitingNetwork`（网络失败）/`failed`（服务端拒绝） |
| `waitingNetwork` | 等待网络 | `waitingNetwork` | 网络类失败（分类器：Socket/Timeout/Http/ClientException/5xx）、离线期间不尝试、临时租约不可用、进程重启复位 | 网络恢复信号 → `claim` → `sending` |
| `failed` | 发送失败 | `failed` | **只有服务端明确拒绝**（权限 M_FORBIDDEN、内容非法、房间不存在、互动门禁） | 仅用户手动重试（`claim(from: failed)`） |
| `sent` | 正常 | `sent` | 服务端返回 event id | 立即从表中移除 |

不变式：
1. **网络问题绝不落 `failed`**：`failed` 只由非网络类异常产生（测试断言覆盖 5xx、
   SocketException、临时租约不可用三种路径都停在 `waitingNetwork`）；
2. **txid 创建时生成一次**：`localId`/`txid` 只在 `save`（或 `sendText` 新建）时生成，
   重试、网络恢复自动重发、跨进程恢复、`restoreOutboxMessage` 后手动重试全部复用同一
   txid（测试逐条断言）；
3. **派发前必须落盘**：`RoomTimelineController` 在调用传输层之前先 `persist` + `claim`；
   持久化层故障不会阻断发送（可用性优先），但会记录在 `outboxError`（可见、不静默）；
4. **非文本消息不进本层**：图片/视频/语音/红包/转账带带外载荷，无法用正文重放，
   继续走原有内存乐观路径（测试断言 `kind: image` 不产生 outbox 行）。

## 4. 发送流程图

```
用户点击发送 / pending 页输入
        │
        ├─ 会话内（RoomPage）: RoomTimelineController.sendText(text)
        │        │
        │        │ ① 生成 txid（新消息）或复用 outboxRow.txid（恢复/重试）
        │        │ ② 创建本地乐观行（同步可见 sending，仍只发一次通知）
        │        ▼
        └─ pending 页: PersistentOutboxManager.save(receiverId, content, roomId=null)
                 │   立即落盘，status=queued，UI 显示「等待发送」
                 ▼
        ┌─────────────────────── 持久化 outbox（唯一真相源） ───────────────────────┐
        │  outbox_messages(local_id PK, txid UNIQUE, room_id, status, ...)          │
        └──────────────────────────────────────────────────────────────────────────┘
                 │
        ③ 原子认领 claim(local_id): status → sending（条件 UPDATE，失败=别人已认领/已送达，禁止再发）
                 │
        ④ 派发（两条路径，按优先级）
             a) 房间已打开：RoomPage 注册的 OutboxSender → controller.sendText(text, outboxRow)
                → 时间线本地气泡 + 实时状态
             b) 房间未打开：OutboxRecoveryService/MessageSendScheduler 用注入的
                OutboxLeaseFactory 临时取租约 → timeline.sendTextWithTransaction(text, txid)
                → 立即 release()（成功/失败/取消三路都释放，不导航、不 push 页面）
                 │
        ⑤ 结果落定
             成功 → status=sent → removeOrArchive（行删除）；controller 侧乐观行= sent
             网络失败/5xx/租约不可用 → status=waitingNetwork + reportFailure(网络状态机)
             服务端拒绝 → status=failed（保留，等待用户手动重试）

网络状态：NetworkStateManager.state 变化 → online/recovering → scheduler.drain()
         （只监听、不建定时器；offline 时不尝试，直接把行标为 waitingNetwork）
进程重启：OutboxRecoveryService.recoverOnStartup()
         → unsent() 全部 status != sent
         → sending（上次死在派发中）复位为 queued（仍复用原 txid）
         → pruneSent() 清理已送达残留
         → scheduler.drain()：room_id 已知的行走 a/b 路径；room_id 为 NULL 的行留给
           pending conversation 的 resumeRoom(receiverId, roomId) 绑定后再发
```

## 5. 测试结果（真实命令与计数）

| 命令 | 结果 |
| --- | --- |
| `cd apps/mobile_flutter && C:/src/flutter/bin/flutter.bat analyze lib test` | `No issues found! (ran in 4.9s)` |
| `C:/src/flutter/bin/flutter.bat test test/features/matrix test/core` | `01:43 +2021: All tests passed!` |
| `C:/src/flutter/bin/flutter.bat test --timeout 120s` | `02:43 +3294: All tests passed!` |

新增/相关用例计数：
- `test/core/outbox/persistent_outbox_manager_test.dart`：**13 条**（状态机词表、save 先落盘、
  txid 唯一、claim 原子、failed 不自动重发、removeOrArchive、recoverOnStartup 复位、
  bindRoomForReceiver 绑定与隔离、账号命名空间、SQLite 表结构/唯一索引断言、
  跨连接重启复用 txid）；
- `test/core/outbox/message_send_scheduler_test.dart`：**19 条**（离线→waitingNetwork、
  网络恢复自动发送、无句柄保留、待绑定行保留、两个调度器并发只发一次、dispose 后不派发、
  服务端拒绝→failed、5xx→waitingNetwork 自动续发、临时租约路径成功/不双发/接管/
  租约不可用保 waitingNetwork/失败路径释放/取消路径释放/未注入工厂时保持旧行为、
  注册表租约失效）；
- `test/features/matrix/outbox_send_flow_test.dart`：**11 条**（发送中已持久化、离线落
  waitingNetwork、服务端拒绝落 failed、网络恢复同 txid 重发、手动重试同 txid 不新增行、
  媒体不进 outbox、重启恢复复用 txid、同一行两次尝试只发一次、failed 只恢复展示、
  原文抵扣去重）；
- `test/features/matrix/pending_conversation_outbox_test.dart`：**3 条**（输入即落盘 + 页面销毁
  后同一存储的新 manager 仍能读到、房间建立后绑定所有未绑定行、建立失败不丢消息且
  重试后绑定成功）。

红→绿证据：临时把 `RoomTimelineController._tracksOutbox` 短路为 `false` 后运行
`outbox_send_flow_test.dart` → `+4 -7: Some tests failed`（8 条中 7 条因缺少落盘/状态
失败）；恢复实现 → `00:00 +11: All tests passed!`。临时移除
`PendingConversationPage._send` 的 `_outbox.save(...)` 后运行
`pending_conversation_outbox_test.dart` → `+0 -3: Some tests failed`；恢复 → 3 条全绿。

全量结果：`C:/src/flutter/bin/flutter.bat test --timeout 120s` →
`02:43 +3294: All tests passed!`（退出码 0）。

`scripts/verify.ps1` 仍在**既有的、与本改动无关**的
`tests/mobile/test_android_ci_workflow.py`（对 commit `bd28dbff` 的断言）处停止；本记录
不改动该测试，按其既有说明处理。

## 6. 剩余风险

1. **明文落盘**：outbox 行的正文保存在应用私有目录的 SQLite 中（与 profile 快照同级的
   信任边界），而房间草稿目前走 `flutter_secure_storage`。缓解：只保留未送达行
   （送达即删除）、账号命名空间隔离、只覆盖文本消息、不写附件字节；退出登录不会删除
   未送达行（避免丢消息）。后续建议：迁移到 SQLCipher（`sqlcipher_flutter_libs` 已在
   依赖中，但需要新增 per-install 密钥管理，属独立变更）。
2. **跨进程 txid 幂等的上界**：重启后复用同一 txid 重发，依赖 Matrix 服务端对
   transaction ID 的去重窗口；超出窗口时理论上可能出现一条重复消息（不会丢消息）。
   这是用户规格明确选择的方案（txid 不变换重复消息），仍建议在服务端确认去重窗口
   语义；若窗口过短，可改为「重启后超过 N 分钟的 sending 行进入待人工确认」。
3. **后台临时租约的成本**：房间未打开时的后台发送需要 `openRoomLease` + `getTimeline`，
   比"等用户进房间"多一次 SDK 时间线初始化；调度器已做串行化（同一时刻最多一个租约）
   与立即释放。若 SDK 租约语义在某些生命周期阶段拒绝（未登录/切换账号），行会停在
   `waitingNetwork` 并在下一次网络恢复时重试，不会误判为失败。
4. **进程死亡瞬间的 sending 行**：复位为 `queued` 并重发，可能与"其实已送达但本地未
   收到确认"重叠，靠 txid 幂等兜底（见第 2 点）。
5. **`initialOutbox` 与新路径并存**：降级路径（无持久层）仍按原文发送；持久化路径按
   内容多重集抵扣。抵扣是内容级的（同一房间同一接收方），若用户在同一 pending 会话里
   连续输入完全相同的文本，抵扣按出现次数逐个进行，不会少发或多发（有专门用例）。
6. **全量门禁的并发环境**：本次改动与其他代理（UI/contacts/moments）在同一工作树并行，
   全量结果反映的是合并后的树；本线文件未触碰他人所有权范围。

## 7. 验收场景映射

| 场景 | 行为 | 证据 |
| --- | --- | --- |
| **场景 1：无网络输入 hello → 等待发送 → 杀进程 → 重开仍在** | 输入即 `save`（`status=queued`）落盘；UI 显示「等待发送」；页面销毁/进程被杀后行仍在同一 SQLite 表里；重开后若仍在 pending 页，行从 `outbox_messages` 重新加载显示；房间建立（或本地已有房间）时由 RoomPage 的 flush 绑定并派发 | `pending_conversation_outbox_test.dart`「输入即落盘：页面销毁后消息仍在（同一存储的新 manager 也能读到）」；`persistent_outbox_manager_test.dart`「新进程（新 manager/新连接）仍能读到未送达行并复用 txid」；`room_page.dart::_flushInitialOutbox` 第 1–2 步 |
| **场景 2：弱网 → 等待发送 → 恢复自动成功** | 弱网（`NetworkState.weak`）仍然尝试派发；失败后按分类器判为网络失败 → `waitingNetwork` + `reportFailure`；`NetworkStateManager` 回到 online/recovering → 调度器（或会话内的既有恢复监听）自动重发，复用同一 txid | `message_send_scheduler_test.dart`「网络恢复：自动派发等待网络的行（复用同一 txid）」；`outbox_send_flow_test.dart`「网络恢复自动重发：同一 txid、outbox 里始终只有一行」；既有 `offline_send_state_test.dart` 气泡断言（不是红色感叹号） |
| **场景 3：服务器暂时不可用 → 不丢失 → 恢复自动继续** | 5xx 被 `defaultNetworkFailureClassifier` 判为网络失败 → `waitingNetwork`（不落 failed、不丢消息）；恢复信号到达后自动继续；服务端**业务拒绝**才落 `failed`（红色重试） | `message_send_scheduler_test.dart`「5xx（服务器暂时不可用）按网络失败处理 → waitingNetwork 并自动续发」「服务端拒绝：行落 failed…」「租约不可用 → 行保持 waitingNetwork（绝不 failed）」 |
