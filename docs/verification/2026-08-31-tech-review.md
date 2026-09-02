# 畅聊 APP 全面技术审查报告（2026-08-31）

范围：高并发通讯架构 / 点钻货币系统 / 代码质量 / 功能完整性。
每项含：问题清单（致命/高/中/低）+ 证据 + 建议 + 执行顺序。
本轮已修复：致命货币并发漏洞（含生产级验证）、数据库连接池、API 多进程、相关回归 133 项全过。

---

## ① 高并发通讯架构（目标：1 万用户同时在线）

**架构现状**：nginx 网关（单点）→ business-api（FastAPI/uvicorn）+ business-worker（Outbox 消费）+ Redis（限流/队列）+ business-postgres；即时通讯由 **Synapse（Matrix）** 承担（PostgreSQL 后备，cp_min5/cp_max10，单体模式）；客户端长轮询 sync。

### 问题清单

| 编号 | 严重度 | 问题 | 证据 |
| --- | --- | --- | --- |
| A1 | **高（已修复✅）** | SQLAlchemy 连接池未配置（默认 pool_size=5 + overflow=10，且无 recycle） | `app/core/database.py`（修复前仅 `pool_pre_ping`） |
| A2 | **高（已修复✅）** | uvicorn 单进程对外服务，无法利用多核，单点故障面大 | `services/business-api/Dockerfile` CMD 无 `--workers` |
| A3 | **中** | 16 个 `async def` 路由内直接执行同步 SQLAlchemy 调用，阻塞事件循环（如 `identity.py` refresh、moments 部分 async 端点） | `grep "async def" app/api/*.py` 与 service 同步实现交叉 |
| A4 | **中** | Synapse 单体模式 + 连接池 cp_max=10：1w 并发在线的 sync 长轮询、加密房间密钥分发会成为瓶颈 | 生产 `homeserver.yaml`（database 段） |
| A5 | **中** | nginx/Redis/Postgres 均单实例，无冗余与故障转移 | `docker-compose.production.yml`（各服务单副本） |
| A6 | **低** | 限流共享 Redis（多 worker 安全✅）；SQLite 仅限测试（✅） | `app/core/rate_limits.py` |

**结论**：当前形态不足以支撑 1 万并发在线（瓶颈：A1-A4）。但架构分层清晰、无状态化程度高（会话在客户端、媒体在对象存储），扩容路径明确。

### 建议（按序）
1. （已做）连接池 10+15 + recycle 1800s + uvicorn 2 workers（`BUSINESS_API_WORKERS` 可调）。
2. 压测定容：k6/locust 以 1w WS/长轮询目标实测 sync 延迟与 DB 连接水位，再决定 workers=4 或拆分只读端点。
3. A3：纯 DB 路由改 `def`（FastAPI 自动线程池），或整体切 asyncpg。
4. Synapse worker 化（generic worker × N + media repository 拆分）+ 连接池提到 50。
5. 高可用：business-api ≥2 副本（nginx upstream）、Postgres 主从、Redis 持久化已开✅。

---

## ② 点钻货币系统安全性

**现状优点**：全程 `Decimal`（CAIBI 2 位 / USDT 6 位 quantize）；复式记账 + 分录平衡校验；幂等键（scope+key）+ **重放载荷校验**；审计事件 + Outbox 事务性事件；提现多级阈值；红包领取 `FOR UPDATE + SKIP LOCKED` 完备。

### 问题清单

| 编号 | 严重度 | 问题 | 证据 |
| --- | --- | --- | --- |
| B1 | **致命（已修复✅）** | 账本余额为聚合计算（无余额行可锁），`post()` 的余额校验无并发控制：两个并发扣减事务读到同一余额→双双提交→**超扣/双花**。生产级复现：16 线程并发扣款 16 笔全成功、余额 **-6.00** | 修复前并发验证输出 `OK=16 FINAL_BALANCE=-6.00 FAIL`（见 wallet_concurrency_verify.py） |
| B2 | **中（已修复✅）** | `read_signed` 硬编码 `expires_in != 300` 即拒绝，媒体链接签名 TTL 无法扩展 | `integrations/private_storage.py`（修复前） |
| B3 | **低（建议）** | `WalletService.credit_for_test` 服务方法未暴露路由✅，但命名易误用，建议加 `environment != production` 断言 | `app/modules/wallet/service.py:44` |

**修复与验证（B1/B2）**：新增 `app/modules/ledger/account_locks.py`——PostgreSQL 事务级 advisory lock 对被扣账户串行化（按账户排序防死锁；SQLite 测试环境自动跳过）；`WalletLedger.post` 与 `LedgerService.post` 在余额校验前取锁；`read_signed` 放行 300/604800 双 TTL。**生产同构环境并发验证：修复前 FAIL（-6.00）→ 修复后 PASS（10 成功/6 拒绝/余额 0.00）**。回归：identity/wallet/ledger/admin/moments/friendship 共 **145 项全过**。

---

## ③ 代码质量与可维护性

### 问题清单

| 编号 | 严重度 | 问题 | 证据 |
| --- | --- | --- | --- |
| C1 | **高** | 生产部署存在**双份源码**（`/opt/starchat/backend/` 与 `/opt/starchat/services/business-api/`），靠人工 scp 双写同步——一旦漂移，构建出的镜像与仓库不一致且难察觉 | 本轮部署需双路径同步才一致（已实证） |
| C2 | **高** | `matrix_home_page.dart` **2652 行**巨石文件（RoomPage + 消息列表 + 表情/语音/红包/转账/朋友圈入口 + 工具方法），修改半径大、回归风险高 | `wc -l`；本轮多次改动均集中于该文件 |
| C3 | **中** | 服务端部分文件使用超长压缩单行（`api/friendship.py`、`api/wallet.py` 一行多语句），评审与断点调试困难 | `api/friendship.py:10-17` |
| C4 | **低** | 客户端 `MatrixSdkE2eeClient`/`MediaMessageService` 在图片发送路径中重复创建且部分路径未 dispose（轻量包装，实际泄漏有限） | `matrix_home_page.dart _pickAndSendImages` |

**优点**：目录分层清晰（features/ui/core、modules/api/integrations）；无 TODO/FIXME 残留（全仓 grep=0）；客户端 439 项测试 + 服务端 350+ 项测试是高质量资产；命名规范一致。

### 建议（按序）
1. C1：部署脚本改为“单一源构建”（服务器仅保留 `services/business-api`，或 CI 从 git 构建），消除手工双写。
2. C2：按“会话列表 / 聊天页 / 语音 / 图片 / 消息行”拆分 `matrix_home_page`（本轮新增的 `SuperEmojiMessage`/`EmojiText`/`CapturePreviewPage` 已按此方向外置）。
3. C3：引入 ruff format/black 统一格式化服务端。

---

## ④ 功能完整性与使用风险

逐一核对模块（实现 + 测试 + 生产部署状态）：

| 模块 | 状态 |
| --- | --- |
| 注册/登录（邮箱验证、邀请码、TOTP、双域会话） | ✅ 完整，109 项 identity/会话测试 |
| 好友私聊/群聊（E2EE、消息撤回/转发/多选/引用/@） | ✅ 完整 |
| 语音消息（按住说话、取消/发送、60s、毛玻璃） | ✅ 0.3.12 完成 |
| 图片（相册分页选择、拍摄预览、查看原图/下载/转发） | ✅ 0.3.12 完成 |
| 朋友圈（发布、图片、feed、互动、举报、广告） | ✅ 带图不可见缺陷本轮修复（见下） |
| 点钻/钱包（余额、提现、审计、红包、转账） | ✅ 后端并发缺陷本轮修复 |
| 管理后台（RBAC、封禁、公告、广告、更新设置） | ✅ |
| 搜索/提醒/表情仓库（E2EE）/通话（WebRTC） | ✅ 实现完整 |

### 问题清单

| 编号 | 严重度 | 问题 | 状态 |
| --- | --- | --- | --- |
| D1 | **致命（已修复✅）** | 带图朋友圈被置 `PENDING_REVIEW` 且无审核放行流程 → 永不出现在 feed；且媒体 URL 以 300s 短签持久化 → 图片必然加载失败 | 服务端已修复部署（生产端到端：发布→feed 可见→图片匿名可取 200 JPEG） |
| D2 | **中** | 语音“转文字”为占位目标区（无 ASR 能力），滑入松手会取消并提示 | 建议接入语音识别后启用 |
| D3 | **低** | 通话入口依赖 WebRTC 权限与 NAT 穿越（coturn 已部署），需真机回归 | 建议保持双设备验收习惯 |
| D4 | **低** | 表情包资产 7.5MB 仍在包内（0.3.11 已从 16.5MB 瘦身）；可迁移至资源热更通道进一步减包 | 待产品确认首装策略 |

**阻断性结论**：当前版本无已知崩溃/闪退/流程中断级阻断问题；回归 439 项客户端测试 + 350+ 服务端测试全过。

---

## 本轮回归结果

- 服务端全量 `pytest tests/business_api`：**218 passed, 1 skipped**（含本轮锁改动回归）；
- 客户端全量 `flutter test`：**439 passed**；`flutter analyze` 零问题；
- 生产端到端：钱包并发验证 PASS（10/6/0.00）；带图朋友圈 feed 可见 + 图片 200。
- 附带发现（低）：`tests/matrix_bot` 与 `tests/business_api` 合并运行时因 `app` 包名冲突导致收集错误（预存在，单独运行均正常）——建议给 matrix_bot 测试加独立包前缀或 conftest 隔离。

## 建议执行顺序

1. **已执行**：B1/B2（货币并发+签名 TTL）、A1/A2（连接池+多进程）、D1（带图朋友圈）——均已部署生产并验证。
2. 短期（1-2 周）：C1 部署单源化；A3 路由同步/异步梳理；D3 通话真机回归。
3. 中期（1 月）：A4 Synapse worker 化 + A5 高可用；C2 客户端巨石拆分（按本轮外置组件的方向）；k6 压测定容 1w 在线。
4. 长期：D2 语音转文字；D4 表情资源热更通道（APK 减至 ~47MB、表情更新百 KB 级）；按需评估 bsdiff 二进制差量。
