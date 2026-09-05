# ChatFlow 审计修复结果（27 项逐项）

**日期：** 2026-09-05　**执行范围：** `docs/ChatFlow_Codex_审计修复Prompt.md` 全部 27 项
**工作区：** 提交 `e7bd02e` 之上的本地改动（未 pull/reset/push/部署）
**验证环境：** pytest（.venv，Python 3.12）+ 隔离 PostgreSQL 18（initdb 临时集群 `127.0.0.1:55432`，绝不指向生产）；Flutter 3.44.9（analyze + test）；Android Gradle（compileStandardDebugKotlin）

## 实际执行的验证命令与结果

| 命令 | 结果 |
|---|---|
| `PYTHONPATH="services/business-api;services/business-worker/app" .venv/Scripts/python.exe -m pytest tests/business_api tests/business_worker -q` | **311 passed, 19 skipped**（迁移 head 断言与 OpenAPI 契约随新增迁移/路由同步后通过） |
| `PYTHONPATH="services/getui-bridge" .venv/Scripts/python.exe -m pytest tests/getui_bridge -q` | **28 passed** |
| `RUN_POSTGRES_TESTS=1 PYTHONPATH=... .venv/Scripts/python.exe -m pytest tests/business_api/audit_pg -q`（隔离 PostgreSQL 18） | **18 passed**（F01/F02/F03/F04/F05/F07 真实事务与并发） |
| `flutter analyze --no-pub` | **No issues found** |
| `flutter test --no-pub`（全量，含本轮全部新增用例） | **848 passed / 0 failed** |
| `gradlew.bat :app:compileStandardDebugKotlin`（env: FLUTTER_STORAGE_BASE_URL 无引号） | **BUILD SUCCESSFUL** |

> 19 skipped = 仓库原有 `RUN_POSTGRES_TESTS` 门控用例（本次另以隔离 PG 跑了新增 audit_pg 18 例）。
> 新增测试文件：`tests/business_api/audit_pg/`（2 文件 18 例）、`tests/business_api/wallet/test_wallet_api_audit.py`（6 例）、`tests/business_worker/test_worker_contract.py`（6 例）、`tests/getui_bridge/test_error_semantics.py` 追加（5 例）、`test/core/cache_repository_test.dart`（改造）、`test/features/matrix/media_audit_test.dart`（6 例）、`test/features/matrix/video_viewer_cache_test.dart` 追加（3 例）、`test/features/push/matrix_pusher_service_test.dart` 追加（2 例）、`test/core/notification/sync_keepalive_service_test.dart` 追加（3 例）、`test/features/matrix/voice_playback_controller_test.dart` 追加（2 例）、`test/features/wallet/wallet_page_audit_test.dart`（3 例）、`test/core/business_api_session_audit_test.dart`（2 例）。

---

## 一、资金和账号隔离（F01–F06、A04、U04）

### F01 · 红包/转账创建及退款缺少统一事务 —— 已修复并验证
- **根因：** `_create` 先独立提交账本再另开事务写业务单据；转账 `_refund` 本金/手续费两笔独立记账且各自提交（与状态变更不同事务）。
- **修复：** `redpacket/service.py _create/_refund`、`transfer/service.py create/decline/expire/_refund` —— 幂等检查、`ledger.post(session=…)`、业务单据/终态全部同一 `session_factory.begin()` 事务；退款合并为单条平衡分录 `{escrow:-本金, PLATFORM_FEE:-手续费, sender:+本金+手续费}`。
- **验证（隔离 PG）：** ①`before_flush` 事件在"记账后、单据插入前"抛异常 → 余额/单据/分录整体回滚；②转账拒收在状态 UPDATE 前注入崩溃 → 退款分录回滚、状态保持 PENDING；③4 线程并发同业务键 → 仅 1 单据 + 1 组分录，重试返回同一 ID；④拒收后 sender 余额精确 +5.03（本金+手续费一次分录）。
- **剩余风险：** 旧实现理论上的"半程退款"遗留（本金已退、手续费未退）：当前部署为沙箱/预生产无真实数据；上线前用只读检查 `select * from ledger_transactions where scope='chat_transfer.refund'` 核对分录数与手续费退款是否存在，不做自动改写。

### F02 · 已审批调账单可重复执行 —— 已修复并验证
- **根因：** `execute` 用调用方 HTTP 幂等键记账、状态标记另开事务，无审批单级执行幂等。
- **修复：** `ledger/adjustments.py execute` —— 执行键服务端派生 `adjustment-execute:{request_id}`；审批单行 `FOR UPDATE` 锁定串行化；账本与 EXECUTED 同一事务。`LedgerService.adjust` 增加 `session` 透传。
- **验证（隔离 PG）：** 同审批单两个不同 HTTP 键并发执行 → 仅 1 笔账本交易；任意键重试返回同一 `ledger_transaction_id`；模拟"账本已记、状态未标"半程后重试 → 账本幂等返回原交易并补齐终态，不重复记账。

### F03 · 充值事件去重阻断补记账 —— 已修复并验证
- **根因：** Deposit 先独立提交再记账再改状态；重复 event_id 直接返回；PENDING 不更新确认数；txid 唯一约束挡住新事件同 txid。
- **修复：** `wallet/service.py handle_deposit_webhook` —— 事件接收记录（WalletWebhookEvent）与充值实体分离；按链上稳定身份 **txid** 聚合（USDT-TRC20 单转账单 txid，作为链上唯一键）；确认数/状态单向推进；入账（键 `deposit:{txid}`）与 CREDITED 同一事务；同事件重放继续完成未入账流程。
- **验证（隔离 PG）：** ①低确认→PENDING 不入账，同 txid 新事件确认数达标 → CREDITED 只入账一次（1 实体/1 分录）；②事件重放恢复"CONFIRMED 未入账"半程；③乱序（先 20 确认后 2 确认）不回退不重复。

### F04 · 提现订单号唯一范围不一致 —— 已修复并验证
- **根因：** 客户端键 `(user_id, client_order_id)` 唯一，但账本执行键 `withdraw:{client_order_id}` 全局 scope（跨用户冲突）；回调按 client_order_id 全表查。
- **修复：** 托管订单号与账本执行键统一为 **全局唯一 `Withdrawal.id`**（`withdraw:{id}`）；客户端键仅做该用户请求去重且重复键核验规范化载荷（金额/地址不同 → `WALLET_ORDER_CONFLICT` 409）；回调先按 ID 定位，legacy 客户端键仅在唯一命中时兼容、跨用户歧义拒绝；`WalletLedger.post` 重复键核验分录内容。
- **验证（隔离 PG + 路由）：** ①两用户同客户端键 → 各自唯一订单/独立扣款（2 笔执行分录）；②同用户同键不同金额/地址 → 冲突（路由 409）；③回调按 ID 更新正确订单，legacy 歧义（两用户同键）→ 拒绝且 u2 订单不受影响。

### F05 · 提现失败缺补偿闭环 —— 已修复并验证
- **根因：** FAILED 仅改状态，无退款分录；UNKNOWN 直接查询后也无裁决闭环。
- **修复：** 状态机 `REQUESTED→(FINANCE|ADMIN)_APPROVED→PROVIDER_SUBMITTED→CHAIN_CONFIRMED|FAILED_COMPENSATED`（终态集合 `WITHDRAWAL_TERMINAL`）；可证实失败以 `withdraw-compensate:{id}` 补偿键与状态变更同事务；`resolve_unknown_withdrawal` 查询托管后裁决（UNKNOWN 抛错不退款）；重复/乱序事件有确定结果。
- **验证（隔离 PG）：** ①FAILED → 余额恢复一次；②重复失败回调（新 event_id）+ 乱序"成功"回调 → 终态不变、仅 1 笔补偿分录；③托管 UNKNOWN → 拒绝且不退款；④resolve 幂等（再次对账不重复补偿）。
- **剩余限制：** 响应丢失但托管实际成功 → 依赖 resolve 查询裁决（不会误退款）；真实托管商多地址/部分提现语义在真实 provider 接入时复核（见 A04）。

### F06 · 群红包缺房间成员授权 —— 已修复并验证
- **根因：** 群红包 detail/claim 只验证登录身份，不验证房间成员关系。
- **修复：** 新增 `redpacket/membership.py`（`MatrixRoomMembershipAuthority`：users 表解析 Matrix ID + Synapse admin 房间 join 成员——仅成员元数据，E2EE 边界不受影响）；`matrix_admin.py` 增加 `get_room_members`；服务/路由接线（`create_redpacket_router(matrix_gateway=…)`）；退群/被踢（非 join 成员）不可见不可领；权威不可达 fail closed；仅发起人本人可见可领。
- **验证：** 成员可领、非成员/退群成员 403（路由级真实请求）、发起人本人放行、专属红包 recipient 判定保持、授权拒绝零副作用（无领取记录/无分录）；无权威时 fail closed。
- **剩余风险：** 成员查询走 Synapse admin API（每 claim 一次远程调用）——高频领取场景建议后续加短 TTL 缓存（未做，避免本轮扩大改动）。

### A04 · 钱包固定沙箱/缺生产门禁 —— 已修复并验证
- **根因：** API 与 worker 直接构造 `SandboxCustodyProvider`；`wallet_webhook_secret` 不在生产必填清单。
- **修复：** 新增 `integrations/custody/factory.py`（统一工厂 + 真实 provider 接入契约清单）；`config.py` 增加 `wallet_custody_provider`（sandbox/production）与生产密钥校验；生产未接真实托管 → 资金入口 503 `WALLET_CUSTODY_NOT_CONFIGURED`（余额/历史/config 只读照常）；worker 同工厂注入，未配置时钱包维护明确跳过并告警。
- **验证：** 生产 + 沙箱 → deposit/withdraw/submit/webhook 503、balances/config 200 且 `funding_enabled=false`；生产 + production provider + 占位密钥 → Settings 校验拒绝。
- **如实声明：** **沙箱成功不等于真实充值/提现已打通**。真实 provider 尚未接入（未自行选择厂商）；接入契约（持久化外部订单状态、幂等回调、对账接口、密钥轮换、隔离端到端验收）已列于 factory 模块文档。

### U04 · 朋友圈缓存未按账号隔离 —— 已修复并验证
- **根因：** 固定键 `cache.moments.feed.latest` 进程单例，退出不清除。
- **修复：** 键改为 `cache.moments.feed.latest.<matrix:userId>` 命名空间（`CacheRepository.momentsFor`）；页面加载/写回前校验账号未变（迟到刷新不写他账号键、不更新他账号 UI）；`SessionBootstrapController.logout` 只清**当前账号**的快照（不触碰 Matrix 聊天历史）。
- **验证：** A/B 命名空间互不可见、登出只清当前账号（B 保留）、键名隔离断言；旧固定键数据自然成为孤儿键（不读取，无泄漏面；如需清理由后续运维决定）。

## 二、推送和后台任务（P01–P03、C02–C05）

### P01 · 临时失败返回 200 —— 已修复并验证
- **根因：** `transient_failures` 只计数不参与响应判断。
- **修复：** `getui-bridge/app/main.py` —— 存在临时失败 → **503**（Synapse 按协议重试）；仅永久 CID 失效进 rejected；**限频资格回滚**（`CidRateLimiter.release`：失败回滚窗口标记，修复"重试被限频静默吞掉"的次生问题）；成功设备保留窗口 → 协议重试不重复提醒。
- **验证：** 网络超时/5xx/限流码 → 503 且 rejected 为空；永久码 → 200 + rejected（既有语义保持）。

### P02 · 401 令牌刷新分支不可达 —— 已修复并验证
- **根因：** 非 200 先抛业务错，`code==10001` 刷新重试在 200 分支不可达。
- **修复：** `getui_client.py push_cid` 统一解析 HTTP 状态+业务码；10001（含 401 载体）清缓存**仅刷新重试一次**、请求身份（request_id/body）复用；`_invalidate_token` 只清仍是当前值的令牌；`_current_token` 锁内双检合并并发刷新；鉴权码绝不判 CID 永久失效。
- **验证：** ①401/10001 → 刷新一次后成功（push 恰 2 次）；②刷新后仍 401 → 503 不循环不进 rejected；③`is_permanent(10001)==False`。

### P03 · event_id_only 无法保证 call 分类 —— 当前代码已满足并有证据
- **证据：** 桥接 `sanitize_notification`：type 缺省 → `kind=message` **唤醒照发**（既有测试 `test_missing_type_defaults_to_message`、`test_call_type_still_detected`——分类仅决定通用文案与限频窗口，不决定来电链路）。来电链路为：推送唤醒（任意 kind）→ 设备 Matrix 同步 → 客户端解密识别 `m.call.invite` → CallController/原生 CallManager 呈现——**不伪造 callId、不自动接听**：`native_call_coordinator_test.dart` 12 例（来电未操作 accept=0；明确接听恰好一次；过期/取消不串扰）+ `call_ui_manager_test.dart` 7 例（陈旧/取消/重复事件处理）。陈旧来电：Matrix 同步带回 hangup → controller ended（`matrix_call_adapter` 既有逻辑）；重复通知：CallManager `onIncoming` 幂等 + PushEventDispatcher 重复推送忽略（上一轮修复，本轮回归通过）。
- **不承诺：** 不向推送厂商发送明文/type 修补（E2EE 红线保持）；锁屏强制全屏等 OS 限制见真机清单。

### C02 · Outbox 主题/消费者不匹配 —— 已修复并验证
- **根因：** worker 仅注册 identity.*，`claim_batch` 不筛主题；ledger/admin/moments/notification/friendship.events 无 handler → 固定延迟无限重试。
- **修复：** `OutboxConsumer.claim_batch(topics=…)` 只领取已注册主题；`reap_undeliverable`（宽限窗口后把无消费者主题移入 **DEAD** 死信，附 `no registered consumer for topic X` 错误，人工重放=重置 PENDING）；`mark_dead` 超最大尝试次数（默认 10）死信 + **有界指数退避**（30s 起步封顶 1h）；Worker 以 `handled_topics` 作为消费者契约。
- **验证：** 主题过滤领取；死信宽限/收割/重放；**全部 9 个生产主题枚举**——identity.* 被 PUBLISHED、其余进 DEAD（可审计+可重放，不静默丢失）；退避死信在 3 次尝试后终止。
- **生产者→主题→消费者契约表（当前）：** `identity.email/matrix/profile` → worker handlers；`ledger、admin、moments、moments.events、notification、friendship.events` → **暂无消费者**（历史既有状态）→ 死信收割兜底并告警，待各域消费者补齐后从死信重放。

### C03 · 维护任务异常中断整个 worker —— 已修复并验证
- **根因：** 维护任务在 `run_once` 的消息处理 try/except 之外。
- **修复：** `worker.py` —— 每个维护任务独立异常边界 + 独立调度周期（默认 30s，不再每批次全量执行）+ `MaintenanceHealth`（`maintenance_status()` 区分"进程活着"与"任务持续失败"：consecutive_failures/last_error/last_success）；失败告警日志保留。
- **验证：** 钱包维护抛错 → 红包维护与消息处理继续；失败→恢复后计数清零；周期内不重复执行。

### C04 · 推送注册/注销异步竞态 —— 已修复并验证
- **根因：** `unregister` 不等待在途 `gateway.create`；迟到 create 完成写回 `_registeredToken`。
- **修复：** `matrix_pusher_service.dart` —— 会话代数 `_generation`：unregister/dispose 递增使在途注册失效；unregister **等待在途注册收敛**；迟到 create 完成发现代数失效 → 立即**补偿删除**；迟到失败回调不再排队重试。
- **验证：** create 已发出后注销 → 净效果无旧账号 pusher（create 后必有删除）；dispose 后无新注册尝试。

### C05 · 前台服务失败仍申请唤醒锁 —— 已修复并验证
- **根因：** `ensureStarted` start 失败仍 `hooks.acquire`；`stop` 以 `!_running` 提前返回（不取消看门狗不释放锁）。
- **修复：** `sync_keepalive_service.dart` —— 服务/锁/看门狗分别跟踪（`_serviceRunning/_locksAcquired`）；启动代数使在途启动失效（迟到完成回滚 `backend.stop`）；stop 无条件取消看门狗并释放已持锁；从未启动不触达后端（兼容契约）。原生 `MainActivity.acquireWakeLocks` 持锁加 **20 分钟超时**（泄漏自释放；看门狗 10 分钟重申）。
- **验证：** start 失败 → stop 释放锁 + 取消看门狗；3 轮 start/stop 交错（含失败注入）后无残留持有；从未启动零触达。

## 三、现有功能闭环（A01–A03、U01–U03）

### A01 · 充值地址接口缺失 —— 已修复并验证
- **修复：** `GET /wallet/deposit-address`（认证）：`DepositAddress` 持久化归属（迁移 0037，`(user_id, asset)` 唯一）；首次分配/复用/跨用户隔离；生产未接托管 503。
- **验证（路由级）：** 首次 200 带地址、重复获取同地址、u2 与 u1 不同地址；生产门禁 503。

### A02 · 提现回调未接公开路由 —— 已修复并验证
- **修复：** `/wallet/webhooks/custody` 按事件类型白名单分发（DEPOSIT_CONFIRMED / WITHDRAWAL_STATUS → 各自处理器统一验签）；未知类型 400 `CUSTODY_EVENT_UNSUPPORTED`；生产未配置 503。
- **验证（路由级）：** 有效提现失败事件 → 状态推进 `FAILED_COMPENSATED`；未知类型 400；伪造签名 401。

### A03 · 鉴权刷新与重试缺超时边界 —— 已修复并验证
- **修复：** `business_api_client.dart` —— 刷新 `_client.post(...).timeout(8s)`；整次授权操作总预算 20s（初次+刷新+重试各段独立超时，预算耗尽 `TimeoutException`）；登出请求 8s 超时 + finally 必清本地会话；会话代数使在途刷新迟到结果失效（`AUTH_SESSION_ENDED`，不恢复已注销会话）。
- **验证：** 登出后迟到刷新响应 → 会话保持清除；登出请求悬挂 → 8s 内完成清理（实测）；取消语义=代数失效。**限制：** 8s/20s 为实时常量，未逐段做挂起注入计时单测（会引入 8–20s 真实等待；结构上每段 `.timeout` 均已覆盖代码路径）。

### U01 · 提现按钮无提交互斥 —— 已修复并验证
- **修复：** `wallet_page.dart` —— `_submitting` 互斥 + 按钮 `loading` 禁用（`wallet-withdraw-submit`）；订单键一次意图生成并持久化（SharedPreferences），失败/超时重试复用同键（服务端 F04 幂等返回原单），成功后清除（下次点击=新意图新键）。
- **验证（真实客户端路径）：** 慢响应期间双击 → 仅 1 次 `/wallet/withdrawals` 请求。

### U02 · 提现页轮询/异步无生命周期保护 —— 已修复并验证
- **修复：** `WithdrawalOrderPoller` —— 固定订单 ID、串行轮询（上一轮完成再调度）、异常转可恢复状态文案、终态自动停、`stop()` 全量取消；所有 UI 更新 mounted 守卫。
- **验证：** 提交在途整页销毁无异常；轮询串行且终态展示后停止。

### U03 · 确认数文案与后端不一致 —— 已修复并验证
- **修复：** 新增 `GET /wallet/config`（网络/确认阈值/最小金额/funding_enabled，阈值来自 `settings.wallet_confirmation_threshold` 默认 12）；客户端 `walletConfig()` + 页面按服务端值渲染（取不到时退通用文案，不再硬编码 20）。
- **验证：** 路由返回阈值 12；客户端接线（`_loadWalletConfig`）与文案渲染改造。

## 四、容量和媒体可靠性（C01、F07、M01–M04）

### C01 · 异步入口执行同步阻塞 —— 已修复并验证（负载数据受限）
- **修复：** `identity.py login` —— 限频/DB 查询/Argon2 校验/令牌签发整段 `anyio.to_thread.run_sync` 卸载（哈希强度不变）；`getui-bridge` —— 同步 httpx 推送经线程池 + `asyncio.Semaphore(4)` 有界并发（不按 CID 串行阻塞事件循环）。
- **验证：** 登录路径既有测试全过（行为不变）；桥接 4 CID × 0.2s 慢供应商实测总耗 < 串行 75%。**限制：** p95/p99、事件循环延迟、RSS 等负载数据未采集（本环境无压测负载工具；结构修复已验证，容量数字留给用户压测环境）。

### F07 · 钱包历史全量查询 —— 已修复并验证
- **修复：** `history(limit≤100, cursor)` —— DB 侧 `(created_at, id)` 稳定游标分页（deposit/withdrawal 各自有界检索后归并取页），`next_cursor` 真实返回；路由 `limit` 1–100 校验 + 游标 400；迁移 0037 增 `(user_id, created_at DESC, id DESC)` 组合索引。
- **验证（隔离 PG）：** 120 条历史 → 分页无重复无遗漏（页长 ≤25、确实翻页）；用户隔离。

### M01 · 普通文件发送全量读内存 —— 已修复并验证
- **修复：** `media_message_service.dart` —— `ensureWithinSendLimit`（默认 100MB）在 `readAsBytes` **之前**做存在/大小预检（`MediaTooLargeException` 明确文案）；`_BoundedSendSlots(3)` 附件发送并发预算（文件与语音入口统一）。
- **验证：** 超限文件预检拒绝（不读内容）；缺失文件明确错误。**SDK 限制（如实记录）：** matrix dart SDK `sendFileEvent` 接收完整字节，无流式加密上传/真正取消接口——不伪造流式接口；取消语义以并发预算+超时为界。

### M02 · 语音下载完成不校验当前任务 —— 已修复并验证
- **修复：** `voice_playback_controller.dart` —— `_generation` 每次播放意图递增；每个 await 后校验（disposed/代数）；stopAll/dispose 使在途任务失效；play 返回后发现归属变更立即停播。
- **验证：** A 慢 B 快 → 只播 B（A 迟到加载不触发 play）；stopAll/dispose 后完成 → 不 play、不 notifyListeners。

### M03 · 媒体缓存直写最终文件 —— 已修复并验证
- **修复：** `media_cache.dart MediaCache.store` —— 同目录唯一临时文件写完 → `.len` 长度元数据先行 → 原子 rename；`cached()` 长度不符/元数据损坏 → 删除数据+元数据按未命中（重下载闭环）；无元数据旧条目按有效接受（不制造假未命中）；同键并发写共享一次落盘。
- **验证：** 截断（500→120 字节）判损坏→删除→重下修复（仅再解密一次）；0 字节空文件判损坏；并发写合并。

### M04 · 缓存按条数而非字节 —— 已修复并验证
- **修复：** `MediaMemoryCache` 字节加权 LRU（默认 64MB；视频缓存 6 条/256MB）+ 条目上限双约束，失败加载不占预算；`MediaCache` 磁盘软/硬配额（384/512MB）——超硬按 LRU（mtime）回收**可再下载副本**至软配额以下（chat-media 只存按事件 ID 可重取的解密副本，不触碰用户唯一文件；相册原件不在该目录）；`totalCachedBytes()` 供设置页展示。
- **验证：** 3×1000B 装入 1000B 预算 → totalBytes ≤1000、最旧先回收；失败后重试成功。**限制：** 大视频连续切换的真机 RSS 稳定性留真机清单；磁盘配额回收为每次写入时触发（数百文件规模可接受，超大规模可改异步节流）。

---

## 数据库/配置变更与回退

| 变更 | 内容 | 兼容/回退 |
|---|---|---|
| 迁移 `0037_wallet_deposit_address`（expand-only） | 新表 `wallet_deposit_addresses` + 3 个索引（地址、历史分页 ×2） | `downgrade()` 删表删索引；旧客户端不受影响（纯新增）；已发布迁移未改写 |
| 配置新增 | `BUSINESS_WALLET_CUSTODY_PROVIDER`（默认 sandbox）、`BUSINESS_WALLET_CONFIRMATION_THRESHOLD`（默认 12）；生产启用钱包 provider 时 `BUSINESS_WALLET_WEBHOOK_SECRET` 必填非占位 | 不设置任何新变量 → 行为与之前一致（沙箱/开发）；生产部署须先配密钥再切 provider |
| OpenAPI | `packages/api-contracts/openapi/liuhetong-v1.yaml` 重新导出（新增 /wallet/deposit-address、/wallet/config；webhooks/withdrawals 契约更新） | `scripts/export_openapi.py` 生成，与实现同步（契约测试通过） |

## 只读检查（上线前执行，不做自动修复）
1. 旧转账半程退款：`SELECT * FROM ledger_transactions WHERE scope='chat_transfer.refund';`（每笔应有本金+手续费合并或均为旧式两笔，无单笔残缺）。
2. 旧充值半程：`SELECT d.* FROM wallet_deposits d LEFT JOIN wallet_ledger_transactions t ON t.idempotency_key='deposit:'||d.txid WHERE d.status<>'CREDITED' AND d.confirmations>=12;`（存在则重放事件即可补记账——新代码支持）。
3. Outbox 死信（部署后）：`SELECT topic, count(*) FROM outbox_events WHERE status='DEAD' GROUP BY topic;`（identity.* 外的主题属预期死信，待消费者补齐后重放）。

## 未完成/外部阻塞/真机项
- **外部阻塞：** 真实托管 provider 未接入（A04 契约已列，不自行选厂商）；个推控制台厂商通道配置证据缺失（P03 离线链路限制，同上一轮报告）。
- **验证受限（代码已修复）：** A03 各段超时的挂起注入计时（8–20s 实时常量）；C01 的 p95/p99/事件循环延迟/RSS 负载数据。
- **真机清单：** 见 `docs/testing/chatflow-manual-acceptance.md`。
