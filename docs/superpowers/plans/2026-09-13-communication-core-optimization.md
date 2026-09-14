# 通讯核心能力优化方案：缓存 / 同步 / 推送

- 状态：待评审（Approved 前不执行任何代码改动）
- 日期：2026-09-13
- 来源：《ChatFlow 与 Telegram 核心通讯机制差异分析》（同日会话审计，含 file:line 证据）
- 范围排除：厂商推送通道（小米/华为/荣耀/OPPO/vivo）与 FCM/APNs 内容推送。原因：官方平台审核周期不可控，本期明确不做。替代方案见 P0-C（到达率补偿机制）。注意 iOS VoIP 来电推送走 `ios-call-gateway` 独立 APNs 路径，不在本排除范围、也不在本方案范围。

## 0. 总览与实施顺序

| 编号 | 工作流 | 优先级 | 依赖 | 预估（1 人） |
|---|---|---|---|---|
| P0-B | getui-bridge 加固（Redis 状态 / 多实例 / 指标 / 批量 spike） | P0 | 无 | 4-6 天 |
| P0-A | 公告推送消费者与批量 fan-out | P0 | P0-B（Redis、指标就绪） | 3-5 天 |
| P0-C | 到达率补偿机制（客户端自愈） | P0 | 无（可与 P0-A/B 并行） | 2-3 天 |
| P1-A1 | 同步调优 Phase 1（timeline.limit + 观测） | P1 | 无 | 2-3 天 |
| P1-B | SQLite 调优 + SDK 迁移链修复 | P1 | 无 | 4-6 天 |
| P1-C1 | 视频转码 faststart | P1 | 无 | 1 天 |
| P1-C2 | 自动下载矩阵设置 | P1 | 无 | 2-3 天 |
| P1-C3 | 本地解密流式代理（边下边播） | P1 | P1-C1 | 5-8 天 |
| P1-C4 | 存储管理 UI + TTL 清扫 | P1 | 无 | 3-4 天 |
| P1-A2 | sliding sync（MSC3575）spike → go/no-go | P1 | P1-A1 观测数据 | 3-5 天（spike） |
| P1-D | 内存治理（测量 → 裁剪 → 增量投影） | P1 | 无 | 4-7 天 |
| P2 | 限流复核 / 落盘加密（可选）/ 本地搜索（defer） | P2 | — | 1-3 天 |

里程碑：
- **M1（第 1-2 周）**：P0-B → P0-A → P0-C。公告能真正推到离线用户；bridge 双实例 + 可观测。
- **M2（第 3-4 周）**：P1-A1、P1-B、P1-C1、P1-C2。
- **M3（第 5-6 周）**：P1-C3、P1-C4。
- **M4（第 7-8 周）**：P1-D、P1-A2 决策、P2。

## 1. 全局约束（对所有工作流生效）

1. **E2EE 边界**：推送出网内容永远只有 CID、通用文案、随机 notify_id、TTL、transmission 类型指令。任何改动不得把 room_id / event_id / 消息内容 / 公告标题内容送出网（`push.include_content: false` 与 `event_id_only` 语义保持）。
2. **跨模块边界**：禁止直写其他模块的表。Synapse `pushers` 表只允许 bridge（Matrix 域基础设施）**只读**访问，且必须使用专用只读 DB 用户；business-worker 不得直连 Synapse DB。
3. **迁移纪律**：业务库新表走 expand-only；客户端 DB（SQLCipher）不执行破坏性变更；schema 变更需可回滚说明。
4. **测试先行**：每个工作流先写失败测试（服务端 pytest / 客户端 flutter test），红→绿；可执行代码改动后跑 `pwsh -NoProfile -File scripts/verify.ps1`（先预检环境）。
5. **部署**：服务端改动先在本机 compose staging 验证，生产部署按 `docs/runbooks/admin-production-workflow.md`（jumper 路径）。
6. **任务记录**：每个工作流开工时按 `docs/workflow/task-template.md` 建独立任务记录；验证证据写入 `docs/verification/artifacts/<YYYY-MM-DD>/`。
7. **Shell**：pwsh 7 + UTF-8 编码约定（见 AGENTS.md）。

---

## 2. P0-B：getui-bridge 加固

### 2.1 现状与问题（证据）
- 单实例、状态全内存：GeTui token 缓存与限流窗口在进程内（`services/getui-bridge/app/getui_client.py:104-167`、`app/rate_limit.py:16-62`）；重启丢状态、无法水平扩展。
- 逐 CID 单次调用 `push/single/cid`，并发上限 4（`app/main.py:29`），未用厂商批量接口。
- 可靠性完全依赖"503 → Synapse pusher 重试"，无队列/DLQ/指标；仅 `/healthz`。
- 永久失效 CID（10009、20101-20105）→ 返回 rejected → Synapse 删 pusher，客户端下次登录重注册（`app/main.py:80-135`）。
- 无测试目录（`services/getui-bridge/` 仅 Dockerfile/app/requirements.txt）。
- nginx 上游单实例（`infra/nginx/nginx.conf.template:33-38, 99-105`）。

### 2.2 方案
保留"503 → Synapse 重试"作为最终一致性生命线（该模型本身成立），做四件事：

**(1) 状态外置到 Redis，bridge 变无状态多实例**
- compose 新增 `bridge-redis`（`redis:7.4.2-alpine` 或更新，钉 digest；`--appendonly yes`），与 matrix-redis（复制用途、无持久化）分离。
- `app/state.py`（新）：
  - token：`GET/SET gt:token`（值含过期时间戳），双实例并发刷新用 `SET NX EX 55` 抢锁 + 双检。
  - 限流窗口：`SET gt:rl:{cid}:{kind} 1 NX EX 1.5`（message）/ `EX 0.5`（call）。用 Redis TTL 替代本地时钟；失败回滚 = `DEL` 该 key（替代现 `release()` 的内存回滚，语义一致且跨实例正确）。
  - 广播去重（P0-A 用）：`SET gt:bc:{broadcast_id}:{cid} 1 NX EX 86400`。
- **Redis 不可用时的降级**：返回 503（Synapse 兜底重试）+ 指标 + WARNING 日志。不做内存降级路径，避免两套语义。

**(2) 多实例部署**
- `docker-compose.yml`：getui-bridge `deploy.replicas: 2`（或写两个 service 条目，视 compose 版本能力）；`MAX_CONCURRENT_PUSHES` 提到 8（单实例 4 → 双实例总 16，配合限流窗口不产生风暴）。
- nginx：`upstream getui_bridge { least_conn; server getui-bridge-1:8088; server getui-bridge-2:8088; }`，`/_matrix/push/v1/notify` 指向上游组。
- Dockerfile CMD 保持单 uvicorn worker（进程内 asyncio 已够），扩容靠实例数。

**(3) GeTui 批量接口 spike（1-2 天，可并行）**
- 调研确认 GeTui REST v2 `/push/batch/cid`（多 CID 单次调用）的配额与限制（厂商文档 + staging 实测单批上限、QPS 限制），记录到 `docs/runbooks/`（新建 push 运维 runbook 或并入现有 PUSH_SETUP.md）。
- 若可行：`getui_client.py` 增加 `push_batch(cids, body)` 分支，`GETUI_BATCH_ENABLED` 配置开关，批大小默认 500、可配置；失败回退逐 CID 路径并按单 CID 结果归类 rejected/transient。
- 若厂商限制苛刻则记录结论、关闭该分支，fan-out 靠并发提升 + 广播接口内部限速。

**(4) 指标**
- `app/metrics.py`（新，`prometheus-client`）：`notify_total{kind}`、`push_result_total{kind,result=ok|rejected|transient}`、`getui_code_total{code}`、`rate_limit_suppressed_total{kind}`、`push_latency_seconds`（histogram）、`batch_size`（summary）。`/metrics` 只绑内部端口，nginx 显式 deny 外部路径。
- Synapse 侧：`homeserver.yaml.template` 开 `enable_metrics: true` 并加内部 metrics listener（仅内网；worker 模板不动）。
- 新增 `infra/prometheus/`（prometheus.yml + alert 规则）+ compose 服务 `prometheus`（钉版本 digest）。最小告警规则三条：bridge transient 率 >10%（5min 窗口）、bridge 实例 down、Synapse pusher 数量骤降（>20%/10min，对应 rejected 风暴）。Grafana 本期不做，规则触发走现有运维通知渠道。

### 2.3 改动文件清单
- `services/getui-bridge/app/state.py`（新）、`app/metrics.py`（新）
- `services/getui-bridge/app/config.py`、`app/main.py`、`app/getui_client.py`、`app/rate_limit.py`（改写为 Redis 后端，保留接口）
- `services/getui-bridge/requirements.txt`、`Dockerfile`
- `services/getui-bridge/tests/`（新：notify 合同、限流窗口语义、token 抢锁、broadcast 端点——为 P0-A 预置）
- `docker-compose.yml`、`infra/nginx/nginx.conf.template`、`infra/synapse/homeserver.yaml.template`、`infra/prometheus/*`（新）
- `docs/PUSH_SETUP.md` / 新 runbook：批量接口结论、指标清单、双实例部署与回滚（缩容为 1 实例 + 摘除上游）

### 2.4 实施步骤（红→绿）
1. 搭 `tests/` 骨架，先写现网行为的回归测试（sanitize 白名单、503 语义、rejected 集合）→ 确认现有实现通过（锁定行为基线）。
2. 红：限流窗口"跨进程"测试（两个 state 实例共享 Redis 时第二个请求被抑制）。实现 Redis state → 绿。
3. 红：token 双实例并发刷新只产生一次 auth 调用。实现 NX 抢锁 → 绿。
4. 接入 metrics，测试断言关键计数器递增。
5. compose/nginx 双实例 + staging 验证：kill 一个实例，推送不中断；Redis 停机 → 503 + Synapse 重试收敛。
6. 批量接口 spike，按结论实现或记录不采用。
7. Prometheus 部署 + 三条告警规则在 staging 触发演练。

### 2.5 验收标准
- 双实例下连续推送 1 万次（staging 脚本）：零丢失（Synapse 重试收敛后），rejected/transient 分类与单实例一致。
- 杀单实例 / 重启 bridge：客户端无感（Synapse 重试期间无永久失败）。
- `/metrics` 可抓取且外网不可达；三条告警规则演练触发。
- Redis 故障演练：bridge 503、恢复后自动收敛、无状态错乱。

### 2.6 风险与回滚
- 风险：Redis 引入新故障点 → 降级语义（503）已定义且与现网失败路径相同；Redis 与 matrix-redis 分离避免互相拖累。
- 回滚：nginx 上游摘回到单实例、`GETUI_BATCH_ENABLED=false`、Redis 停用开关（config 回退内存实现保留一个发布周期后删除）。

---

## 3. P0-A：公告推送消费者与批量 fan-out

### 3.1 现状与问题（证据）
- `create_notice`/`update_notice`/`retract_notice` 入队 `topic="notification"`，`aggregate_id=notice_id`，payload `{"audience","status"}`（`services/business-api/app/modules/admin/service.py:110-155`）。
- worker `handled_topics` 只含 identity/wallet 主题（`services/business-worker/app/worker.py:84`），notification 事件无人认领 → 10 分钟宽限后进 DEAD（`worker.py:137-146` reap 逻辑）。**当前全网公告永远到不了离线用户。**
- 公告本体是拉取式（客户端查公告中心），`NoticeReceipt` 记录已读。
- 用户设备 CID 的权威存储在 Synapse `pushers` 表（客户端注册 `app_id=com.liuhetong.mobile.getui`，`apps/mobile_flutter/lib/features/push/matrix_pusher_service.dart:51-58`）。

### 3.2 方案（两段式，全部通用文案，E2EE 语义不变）
**Tier 1 — 公告房间消息**：消费者把公告标题/正文投递到指定公告房间（走既有 matrix-bot `POST /internal/matrix/publish`，`services/matrix-bot/app/api.py:37-74`，已具备幂等 sqlite + 房间白名单，当前无调用方）。在房间内的在线/离线用户由 Synapse 常规 pusher 链路自然收到推送，且消息本体进 Matrix 域、可搜索可留痕。
**Tier 2 — 离线唤醒广播**：对不在公告房间或需要强触达的用户，调用 bridge 新增内部端点做全员设备唤醒推送（通用文案"您有一条系统公告"，transmission `{"type":"notice"}`），用户点开后进公告中心拉取内容（现有拉取通道不变）。

数据流：
```
admin API 写公告 + outbox(notification)
  → business-worker handler(notice.publish.requested)
      ├─ Tier1: POST matrix-bot /internal/matrix/publish（幂等键=notice_id）
      └─ Tier2: POST bridge /internal/push/broadcast {broadcast_id=notice_id, kind="notice"}
            → bridge 只读 Synapse pushers 表（专用只读用户，app_id 过滤、enabled 过滤）
            → Redis 去重(gt:bc:{id}:{cid}) → 分批(500) + QPS 限速 → GeTui
            → 每批完成回写 worker 侧进度表（断点续推）
  → notice.retracted: 仅 Tier1（若已投递房间）发撤回提示，Tier2 不做撤回推送（TTL 短自然过期）
```

**(1) worker 侧**
- `services/business-worker/app/handlers/notification.py`（新）：注册 topic `notification`，处理 `notice.publish.requested` / `notice.retracted`。从业务库读 `OfficialNotice` 行（同域读取，合法），audience 语义沿用 admin 模块定义（实施第一步先确认 audience 取值域并在 handler 内做同样校验）。
- 新表 `notice_push_progress`（expand-only 迁移）：`notice_id PK, tier1_status, tier2_total, tier2_done, tier2_failed, last_batch_cursor, status, updated_at`。幂等键 = notice_id；handler 重入时按 cursor 续推。
- `worker.py`：注册 handler 后 `handled_topics` 自然纳入 notification，DEAD 误伤即消除；`reap_undeliverable` 不再收割该 topic。

**(2) bridge 侧**
- `POST /internal/push/broadcast`（新，`app/main.py`）：共享密钥头认证（复用 matrix-bot `X-Matrix-Webhook-Key` 模式）。入参仅 `{broadcast_id, kind}`——**不含任何内容**；CID 解析在 bridge 内完成（只读 Synapse `pushers` 表：`SELECT pusher.user_id, pusher.pushkey FROM pushers WHERE app_id=:app AND enabled`， Postgres 同实例跨库只读用户 `synapse_readonly`）。
- 分批 + `broadcast_qps` 限速（默认保守 100/s，配置化）+ 每批 Redis 去重键；单批完成即返回进度给 worker。
- 通用文案模板加 `notice` 类（与 message/call 并列，限流窗口沿用 message 的 1.5s 或按 notice 独立配置）。

**(3) 客户端（可选小改，独立提交）**
- transmission `{"type":"notice"}` 唤醒后冷启动直达公告中心页（`apps/mobile_flutter/lib/.../push` 解析路由，现有 GeTui 点击处理处）。无此改动也不影响功能。

### 3.3 实施步骤（红→绿）
1. 红：worker 测试——notification 事件不进 DEAD 且被 handler 消费（假 bridge HTTP 服务）。实现 handler + 注册 → 绿。
2. 红：bridge 测试——broadcast 端点鉴权失败 403；重复 broadcast_id 的 CID 去重（Redis 键）；进度分批返回。实现端点 → 绿。
3. 红：handler 断点续推测试（第二批前崩溃 → 重跑不重复第一批）。实现 cursor → 绿。
4. `synapse_readonly` 只读用户 + bridge 只读查询，测试 mock pushers 表断言 app_id/enabled 过滤。
5. staging 全链路演练：发布公告 → matrix-bot 房间消息 + 离线设备收到通用唤醒 → 公告中心可读；retract 演练。
6. 证据：broadcast 1 万设备压测（staging）耗时、失败率、进度表一致性。

### 3.4 验收标准
- 公告发布后：房间成员收到真实消息推送；非成员离线设备 ≤ N 分钟（QPS 折算）内收到通用唤醒；客户端可见公告内容。
- worker 重启 / handler 失败重试：不重复推送（Redis 去重 + cursor 双保险）。
- DEAD 队列不再出现 notification 主题事件；进度表与 GeTui 受理数对账一致。
- 出网载荷审计：抓包确认仅 CID/通用文案/notify_id/TTL/type。

### 3.5 风险与回滚
- 风险：全量 pushers 大表查询压力 → 只读用户 + 分页查询（keyset by user_id）；bridge 只读账号权限最小化。
- 风险：GeTui 全量广播触发厂商限流 → QPS 配置保守起步，压测后再调；429/限流码按 transient 处理走 Synapse/worker 重试。
- 回滚：`GETUI_BROADCAST_ENABLED=false`（bridge）+ worker handler 配置关闭（事件留在 PENDING 不误伤）；表为纯新增可整体退役。

---

## 4. P0-C：到达率补偿机制（替代厂商通道）

### 4.1 现状与问题
厂商通道出局后，Android 离线到达依赖 GeTui 自通道 + dataSync 前台服务（Android 14+ 每日配额限制）。同步链路历史上会挂死（自研 watchdog 即证据）。需要不依赖厂商通道的补偿闭环。

### 4.2 方案（纯客户端 + 少量服务端观测）
1. **推送注册自愈**：应用启动、联网恢复（`ConnectivityPlusTransportMonitor` 已有）、前台切换三个时机强制校验 pusher 注册状态，缺失立即补注册（现有 10s/30s/2m/10m 退避保留，新增"事件驱动立即触发"入口）。文件：`lib/features/push/matrix_pusher_service.dart`。
2. **周期对账同步**：Android WorkManager 周期任务（15min 下限，网络约束 `NetworkType.CONNECTED`）：one-shot sync + 公告中心拉取 + 未读徽标修正。与前台服务（dataSync）配额互补：前台服务在线时 WorkManager 任务跳过。文件：`lib/features/background/`（新）+ `pubspec` 依赖 workmanager（钉版本）。
3. **watchdog 诊断增强**：软停顿触发时落盘最近 60s sync 状态栈与网络快照（本地文件，隐私：不含消息内容），用于定位挂死根因（NAT 超时 / doze / 代理）。文件：`lib/features/matrix/matrix_sync_watchdog.dart`。
4. **漏斗观测（服务端，复用 P0-B 指标）**：Synapse notify 数 → bridge ok 数 → GeTui 受理数的三段比值看板/告警，作为"到达率"代理指标（无厂商回执下的最优近似）。

### 4.3 实施步骤（红→绿）
1. 红：pusher 自愈测试——mock client 无 pusher 时启动钩子触发注册；恢复联网触发。实现 → 绿。
2. 红：WorkManager 对账测试——前台服务活跃时任务跳过；执行时调用 one-shot sync 与公告拉取各一次。实现 → 绿。
3. watchdog 诊断落盘（单元测试断言文件内容脱敏）。
4. 真机验收脚本：杀进程 → GeTui 唤醒 → 通知可达；飞行模式 10 分钟 → 恢复后 ≤15min 未读/公告补齐（计入 docs/verification 证据）。

### 4.4 验收标准
- 杀进程 + 锁屏 8 小时后，通用唤醒仍可点亮（GeTui 自通道在线场景）。
- 断网恢复 ≤15 分钟内未读数与公告中心一致。
- 前台服务被系统回收后，WorkManager 路径仍完成对账。
- dataSync 前台服务用量审计结论写入 runbook（Android 14 配额内的预期行为）。

### 4.5 风险
- WorkManager 15min 下限意味着最坏 15min 延迟——这是无厂商通道下的物理上限，明确写入文档管理预期；厂商通道未来解禁时此机制仍作为兜底保留。

---

## 5. P1-A：同步调优与 sliding sync 决策

### 5.1 现状与问题（证据）
- vendored SDK **无 sliding sync、无 websocket**（`apps/mobile_flutter/third_party/matrix/lib/src/` 无相关文件）——同步升级是 SDK 移植级工程，不是配置开关。
- 默认 sync filter 未设 `timeline.limit`（`third_party/matrix/lib/src/client.dart:238-242`），吃服务端默认 ~10 条；`limited` 同步直接清空内存时间线（`timeline.dart:263-286`）。
- 仅归档加载设置了 limit（`client.dart:1127`）。
- 客户端 filter id 缓存后不随 filter 定义变化重传（`client.dart:2187-2194` 仅在无 id 时 define）——改 filter 必须处理失效。
- watchdog 存在本身即协议层不足的信号。

### 5.2 Phase 1（P1-A1，先做）
1. **显式 timeline.limit**：`matrix_client_factory.dart` 构造 Client 时传 `syncFilter: Filter(room: RoomFilter(state: StateFilter(lazyLoadMembers: true), timeline: StateFilter(limit: 20)))`（20 起步，配合观测调参）。**注意**：filter 定义变更需使缓存 filter id 失效——vendored SDK 小补丁：`_checkSyncFilter` 改为按 filter JSON 的稳定 hash 比对（id 命名空间加 hash 后缀），变化即重新 defineFilter 并更新 DB。补丁记入 `CHATFLOW_PATCH.md`。
2. **观测埋点（本地，不上传内容）**：limited 同步次数、初始 sync 耗时、房间数、watchdog 软/硬触发次数、oneShotSync 耗时，输出到现有本地诊断日志（`NotificationDiagnostics` 同级）。
3. 观测期 ≥1 周，产出数据支撑 Phase 2 决策。

验收：升级后首次同步一次性带 ≥20 条/房间；filter id 平滑切换（老版本升级路径不 clearCache）；limited 率与 watchdog 触发率有基线数据。

### 5.3 Phase 2（P1-A2，spike 后 go/no-go）
- **前置事实核查（spike 第一步）**：Synapse 自 v1.111 起原生支持 MSC3575（`experimental_features.msc3575_enabled: true`）；pinned `v1.132.0` 上在 staging 开启并验证 `/sync/sliding` 端点行为与稳定性。
- **spike 内容**：在 vendored SDK 中原型 sliding sync 客户端层（房间列表窗口 + timeline 订阅），跑通 3 房间收发。评估点：与现有 `MatrixSdkDatabase` 的 fragment 兼容、E2EE 解密路径、发送队列整合。
- **go/no-go 标准**：Phase 1 观测显示 limited 率 / watchdog 硬触发率仍显著（如日均 >1 次硬触发，或 500+ 房间用户首次同步 >30s）→ 立项完整移植（另立计划，估 2-4 周）；否则记录 spike 结论，维持长轮询 + watchdog，把资源让给 P1-C。

---

## 6. P1-B：SQLite 调优 + SDK 迁移链修复

### 6.1 现状与问题（证据）
- 全库无任何性能 pragma（仅 `PRAGMA cipher_version`/`KEY`，`third_party/matrix/lib/src/database/sqflite_encryption_helper/io.dart:154-171`）。
- 迁移策略：除 v8→9 外任何版本变更 `clearCache()` 清空全部历史（`matrix_sdk_database.dart:307-335`）——SDK 升级一次用户本地历史全没。

### 6.2 方案
**(1) pragma 调优**（`apps/mobile_flutter/lib/features/matrix/matrix_client_factory.dart` 的 `_openPersistentClient`，onConfigure/open 后）：
- `PRAGMA journal_mode=WAL`（SQLCipher 支持；先在 Windows/Android/iOS 三平台验证 + 加密库行为）
- `PRAGMA synchronous=NORMAL`、`PRAGMA busy_timeout=3000`、`PRAGMA cache_size=-8000`
- 预期收益诚实标注：sqflite 为单连接，主要收益在 checkpoint/fsync 减少与写放大降低，而非读并发。用现有测试 + 一段 500 事件批量写入基准（新增 benchmark 测试）前后对比留证。
**(2) 迁移链修复**（vendored SDK 补丁）：
- `_migrateFromVersion` 改为显式迁移链 `Map<int, Future<void> Function()>`（vN→vN+1 逐级执行），只有**未注册的跳跃**才 fallback clearCache，且 fallback 前打 ERROR 日志。
- CI 守卫测试：断言 `version` 常量每次 +1 必须存在对应迁移项（否则测试红）。
- app 侧防误伤：版本升级前后加集成测试（v9 库 fixture → 打开 → 历史仍在）。
- 补丁与升级流程写入 `CHATFLOW_PATCH.md`；今后 SDK 升库版本必须同步迁移项（流程约束写入 runbook）。

### 6.3 验收
- `PRAGMA journal_mode` 返回 `wal`（三平台冒烟）。
- 写入基准：批量 1000 事件写入耗时下降或持平（不劣化），数据前后对比入 `docs/verification/artifacts/`。
- v9→v10（人造迁移项）fixture 测试：历史保留、v8→v9 老路径不回归。

---

## 7. P1-C：媒体体验

### 7.1 P1-C1 视频转码 faststart（1 天）
- `apps/mobile_flutter/third_party/video_compress` 两遍转码的封装步骤加 `-movflags +faststart`（moov 前置）。
- 红→绿：单元测试生成样例视频，解析 mp4 atom 顺序断言 `moov` 位于 `mdat` 前。
- 收益：为 P1-C3 渐进播放铺路；即使不做流式，弱网下载中也可边下边播起头。

### 7.2 P1-C2 自动下载矩阵设置（2-3 天）
- 设置页新增"自动下载"：图片/视频/文件 × Wi-Fi/蜂窝，持久化 SharedPreferences（`core/cache/cache_repository.dart` 同层）。
- 门控点：`media_load_scheduler.dart` 入队处按媒体类型 + 当前网络（connectivity_plus 已有）拦截；画廊"查看原图"永远 interactive 放行；GIF 既有 `mediaDownloadAllowed` 旗标接入同一设置。
- 默认值 = 现状（全部按需），不改变现有用户感知；后续可运营调整默认。
- 验收：设置矩阵全组合的门控行为测试；蜂窝下视频默认不自动下载。

### 7.3 P1-C3 本地解密流式代理（5-8 天）——本方案最重的客户端单项
**原理**：聊天媒体是 AES-256-CTR 加密（ADR-0060）。CTR 模式天然可按字节偏移定位计数器块 → 本地 HTTP 代理可对任意 Range 精确解密，实现真正的拖动进度条 + 边下边播。
- 新组件 `lib/core/media/media_stream_proxy.dart`：shelf HTTP 服务，`127.0.0.1` 绑定 + 随机端口 + 每会话 Bearer token + 单会话生命周期（页面销毁即关）；实现 Range 请求解析与 `Accept-Ranges`。
- 数据源两级：盘缓存命中直接流式解密读盘；未命中走**分块下载器**（新，替代整文件 `downloadAndDecryptAttachment` 用于播放场景）：按 256KB 块拉取 → CTR 解密 → 同时喂代理与落盘缓存（复用现有 `MediaCache` 原子写与完整性校验）。
- **前置未知（实施第一步探测）**：Synapse media `/download` 是否支持 HTTP Range。curl `-H "Range: bytes=1000-2000"` 实测 pinned v1.132.0。支持 → 代理真 seek；不支持 → 代理顺序渐进模式（从头吐流，seek 仅限已缓冲区间），结论写入计划附录。
- 接入：`encrypted_media_view.dart` 视频路径与 `voice_playback_controller.dart` 音频路径改走代理 URL；保留现有"完整下载后播放"作为降级开关（`MEDIA_STREAMING_ENABLED`）。
- 安全红线：代理仅回环、带 token、会话结束即关；密钥不落盘不日志；下载块解密直接入盘缓存（沿用明文缓存现状，见 P2 可选项）。
- 验收：20MB 视频在 2Mbps 限速模拟下 3 秒内起播、拖动到未缓冲区平滑续播（Range 支持时）；音频同理；降级开关回归旧路径测试全绿。

### 7.4 P1-C4 存储管理 UI + TTL 清扫（3-4 天）
- `media_cache.dart` 增加 `stats()`（按类型字节统计：视频/图片/文件，对象后缀已可区分）与 `sweepExpired(ttl)`：mtime 早于 TTL 的对象删除（默认关闭，设置项 30/90/180 天）；孤儿 `.ref` GC（引用对象缺失即删 ref；对象无 ref 且超期即删——保留跨房间去重语义需注意：对象可能被多 ref 共享，GC 按"无任何 ref 指向 + 超期"判定，ref 索引启动时重建）。
- 设置页"存储空间"：分类占用展示 + 分类型清理 + 全部清理；清理动作复用 `clearAccount` 的原子与在飞写 fencing 逻辑但保留账号数据。
- 验收：1GB 模拟缓存的统计准确性（与 du 对账 ±5%）；TTL 清扫后最近文件完好；清理后消息列表缩略图按需重新下载无崩溃。

### 7.5 上传续传——明确 defer（记录理由）
Matrix 内容库为单次 PUT，无断点续传协议；绕开 Matrix 自建媒体服务违反域边界。缓解已存在（content-addressed envelope 可复用重试），本期补：上传进度条 + 取消 + 断网自动重试（`attachment_upload_controller.dart`）。大文件续传与 MSC 相关提案联动，延后评估。

---

## 8. P1-D：内存治理

1. **测量先行（1-2 天）**：DevTools 内存 profile：单房间连续翻页 500/1000/2000 事件的堆曲线（SDK `TimelineChunk.events` 无界增长验证）、会话列表 500 房间冷启动内存。证据入 `docs/verification/artifacts/`。
2. **chunk 裁剪（3-5 天，测量证实超标后执行）**：vendored SDK `TimelineChunk` 加窗口化——保留当前 anchor ±N（N=300），越界事件从内存移除但 fragment 元数据完整保留（requestHistory 的 prev_batch 链不依赖被裁剪的事件本体）；app 层 flag 控制 + 回归：翻页→跳转→回到底部全路径测试。**若测量显示内存在可接受范围（如 1000 事件 <60MB），此项关闭并记录。**
3. **房间投影增量（3-5 天）**：`matrix_e2ee_client.dart` 会话快照从"每次全量遍历 `client.rooms`"改为事件驱动的脏房间增量更新（`_roomProjectionCache` 签名比对机制已有，扩展为订阅 Room.update 只重算受影响房间）；`totalUnreadCount` 同理增量维护。
   验收：500 房间压测下单次 sync 事件处理耗时与 CPU 占用前后对比。

---

## 9. P2 项

1. **限流复核（1 天）**：`rc_invites.per_room` burst 1200 → 200（先核查客户端批量建群/邀请单批上限，确保不回归）；`rc_message` 等显式写注释性配置（保持默认值）避免"隐性默认"；admin/机器人专用账号评估 `ratelimiting` 豁免（走 Synapse module，不动全局）。
2. **媒体缓存落盘加密（可选，2-3 天，依赖 P1-C3）**：CTR 密钥体系已在 ADR-0060 存在，缓存文件按块 CTR 加密与流式代理同一套密钥机制天然协同；收益是消除"明文缓存 vs 加密消息库"姿态不一致；代价是读路径 CPU。spike 后按设备性能数据决定。
3. **本地消息搜索（defer）**：KV JSON 无索引，需引入 FTS 层，代价大收益待产品确认；等 sliding sync 决策一并评估（若 SDK 大改，同期考虑存储层升级）。

## 10. 交付门禁（Definition of Done 映射）

- 每工作流独立任务记录（`docs/workflow/task-template.md`）+ 红→绿证据。
- 服务端改动：pytest 全绿 + compose staging 演练记录（扩缩容/故障注入/回滚各一次）。
- 客户端改动：flutter test 全绿 + 三平台冒烟 + `scripts/verify.ps1`。
- E2EE 边界专项断言：P0-A/P0-B 出网载荷审计（抓包）留证。
- 文档同步：PUSH_SETUP.md（或新 push runbook）、`CHATFLOW_PATCH.md`、相关 OpenAPI（broadcast 内部端点如需合同化则入 internal OpenAPI）。
- 验证证据目录：`docs/verification/artifacts/2026-09-13/` 起，按工作流分子目录。
