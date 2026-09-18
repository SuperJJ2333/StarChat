# 2026-09-18 Media Engine Production Readiness Validation（生产候选验证）

## 恢复入口

- 目标、用户授权来源及边界：用户直接指令（本会话）。**验证 ChatFlow Media Engine 是否达到生产候选标准**
  （正确性 / 安全性 / 一致性 / 性能风险 / Migration 安全）。**默认禁止修改代码**；
  仅在发现明确安全漏洞 / 数据损坏风险 / 生命周期错误 / 权限绕过时允许修复。
  禁止增功能、改 ADR、改 Media Object 模型、改 Matrix 协议、改 E2EE、改 Moments API、改 Avatar。
- 关联计划/ADR：[Phase 3.1 冻结](../architecture/media-engine-phase3-freeze.md)（ADR-001…006）、
  [Phase 3 设计](../architecture/media-engine-phase3-server-design.md)、
  [Phase 4 实施报告](../verification/media-engine-phase4-implementation.md)、
  **本阶段产物** [`media-engine-production-readiness-report.md`](../verification/media-engine-production-readiness-report.md)。
- 当前状态：**验证完成并已发布上线**。结论 `Media Engine Production Candidate: PASS`（附 1 条治理条件：ADR 修订）。
  用户随后指示“4 个验证提交推送 + 把修复部署到服务器”，已于 2026-09-18 完成：
  `origin/main` 已含 `c2c41bf1`、`f0e41306`、`5f65dd2b`、`27a09910`；生产 `business-api` 已切换到
  `starchat-business-api:media-engine-20260918`（`source_commit=27a09910`），
  部署记录见 [`artifacts/2026-09-18/media-engine-phase4/deployment-evidence.md`](../verification/artifacts/2026-09-18/media-engine-phase4/deployment-evidence.md)，
  复验结论见报告 §12。
- 负责人、工作树、文件所有权、源码commit：本地工作树 `D:\pythonProject\outsource\StarChat`，分支 `main`，
  起点 `61b29917`。本阶段新增：验证套件 `tests/business_api/media_platform_readiness/**`（7 个文件、62 条用例）、
  修复 `app/modules/media/{audience,reconcile,service,lifecycle,domain,metrics,repository,references,grants,moments_bridge}.py`
  + `app/main.py` + `app/api/media_platform.py`、
  更新 `tests/business_api/media_platform/test_media_authorization.py`（2 条用例按收紧规则更新）、
  重导出 `packages/api-contracts/openapi/liuhetong-v1.yaml`、新增本报告、发布载荷与部署记录。
- 最后更新时间（含时区）：2026-09-18（Asia/Hong_Kong）。
- 下一条具体操作、必要输入、阻断的验收ID：上线后仅剩治理/运维项 ——（1）以 ADR 修订记录 audience 收紧（R1）；
  （2）把 `reconcile`（dry_run）纳入巡检、`metrics` 接入监控并监控 3 个竞态计数器；
  （3）多 uvicorn worker + 真实负载压测。当前**无阻断验收项**。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| P-ADR | ADR-001…006 全部符合 | 无（验证） | `test_adr_compliance.py`（24 条）全通过；4 条 ADR 行为+结构双断言 | — | — |
| P-SEC-001 | A 不能访问 B 私有媒体 | 无（验证） | `test_security_readiness.py`：403/404、不回显 id、转发 URL 404、跨用户签发 403 | — | — |
| P-SEC-002 | 篡改 subject/expire/signature 必须失败 | 无（验证） | 四类字段篡改 + 合法签名换 subject + 改签名尾 全部失败；`expires_in` 入参 422 | — | — |
| P-SEC-003 | 过期 token 统一失败 | 无（验证） | 404 `MEDIA_SIGNED_URL_INVALID`，不含存在性/过期线索 | — | — |
| P-SEC-004 | Grant 撤销后失效 | 无（验证） | URL 404 + 直读 403 + `grant_version` 递增 | — | — |
| P-SEC-005 | 受众成员可读、非成员不可 | **修复 High-1** | `audience.py` 新增；签发门槛 + 交付实时复核；5 条用例（成员/非成员/匿名/失去成员资格/不可校验受众） | — | — |
| P-DATA-001 | 引用释放顺序与计数重算 | 无（验证） | `test_data_consistency.py`：释放其一保留、其二 ORPHAN、可复活、计数从 99 重算回 3 | — | — |
| P-DATA-002 | GC 不删 active/pinned/uploading/processing | **修复 High-2** | 五类对象矩阵用例；`processing` 变体守卫新增 | — | — |
| P-DATA-003 | 崩溃双向恢复 | **修复（新增 reconcile）** | 孤文件重建（按隔离段决定摘要种类）/ 缺文件失效 / 旧命名空间不动；维护端点为 enforce 入口 | — | — |
| P-GC | GC 可运行、dry-run、审计、恢复 | 无（验证） | 13 条一致性/并发用例 + 2,000 孤儿规模回收 | — | — |
| P-CONC | 并发四场景 | 无（验证） | 密文单 blob / 引用幂等 / GC 与读并行 / 删除与引用竞争最终一致 | — | — |
| P-MIG | 旧媒体可读、新媒体走平台、新旧并存 | 无（验证） | `mxc://` 与旧能力 URL 零平台行；桥接端到端经未修改的 Moments 接口读写 | — | — |
| P-PERF | 性能基准（真实测量，未测标注 NOT MEASURED） | 无（验证） | 4 个基准 + 3 个规模模拟，数字见报告 §7 | — | 多 worker/PG **NOT MEASURED** |
| P-API | OpenAPI 一致 | 重导出合同 | `export_openapi.py --check` PASS；媒体平台 15 条路由在册 | — | — |
| P-GATE | 自动化门禁 | 无 | flutter analyze/test（3143，`--concurrency=2`）、pytest tests/mobile（70）、npm（209）、verify.ps1 PASS | — | — |
| P-DEP-COMPAT | 生产旧版本模块兼容 + 备份 backend 兼容 | **修复 High-6 / High-7** | `compat-probe.sh` → `===PROBE_OK===`；`test_deployment_compatibility.py`（7 条）；`moments_bridge` getattr 兜底、`MediaReconciler` root/exists 兜底 | 已上线 | — |
| P-DEP-REH | 真实 PostgreSQL 排练（恢复生产 dump 的一次性库） | **修复 High-3 / High-4 / High-5** | `0068 → 0069` 迁移演练 + `concurrency_probe.py`：4 线程并发同密文/引用/grant 零异常且收敛为 1；GC 有引用不回收；明文不跨用户共享 → `===REHEARSE_OK===` | 已上线 | 多 uvicorn worker 未测 |
| P-DEP-MIG | 生产 expand-only 迁移 | 无（数据层扩展） | `===MIGRATION_OK===`：head `0069_media_platform`、7 张表、4 个部分唯一索引；旧代码仍 health 200 | 已上线 | — |
| P-DEP-SWITCH | 仅替换 business-api 容器 | 无（部署） | `===SWITCH_OK===`：镜像/摘要/env=63/端口/挂载不变；22 个载荷文件逐文件哈希一致；`restarts=0`、`health=healthy`、0 Traceback；worker 未重启 | 已上线 | — |
| P-DEP-ENDPOINT | 端点与鉴权边界 | 无（部署验证） | `objects/resolve` 未认证 401、`metrics`/`gc` 无 token 403、带 token 200、`reconcile(dry_run)` 200、`moments/feed` 401 | 已上线 | — |
| P-DEP-SECRET | 生产密钥配置 | 服务器侧 overlay | `release/api-secrets.json`（`chmod 600`，值不入仓库）；实测独立签名密钥与维护令牌均生效 | 已上线 | — |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| 验证环境 | CPython 3.12 / SQLite in-memory / 本地磁盘 / Windows 工作站 / 单进程 | `61b29917` + 本阶段改动 | 无（验证） | 报告：`docs/verification/media-engine-production-readiness-report.md` | 无 |
| 生产 `business-api`（已发布） | 镜像 `starchat-business-api:media-engine-20260918`，运行 ID `sha256:b3908bacebf0a6c17d5b4026ef63ea40df8381922fd3586e244420d060ef1901` | `27a09910`（载荷 22 文件，manifest 逐文件 SHA256） | 容器 `starchat-business-api-1`，端口 `127.0.0.1:8082` | `docs/verification/artifacts/2026-09-18/media-engine-phase4/`（`payload-manifest.json`、`live-hashes.txt`、`deployment-evidence.md`）；服务器 `/opt/starchat/releases/media-engine-20260918/` | 2026-09-18T12:55:34Z 切换，`health=healthy`、`restarts=0` |
| 生产备份/回退 | 旧镜像 `starchat-business-api:redpacket-fee-20260917`（`sha256:48948fb7…`）；DB dump `backup/20260918T120535Z/business-db.sql.gz`（sha256 `6f5dd822…`） | — | — | 服务器 `/opt/starchat/releases/media-engine-20260918/backup/`、`release/rollback-api.sh` | — |

- 命令与退出码：
  - `py -3.12 -m pytest tests/business_api/media_platform_readiness -q` → **62 passed**（collected 62；含部署兼容 7 + 竞态复现 3）
  - `py -3.12 -m pytest tests/business_api/media_platform -q` → **72 passed**（collected 72）
  - `py -3.12 -m pytest tests/business_api/media_platform_readiness tests/business_api/media_platform tests/business_api/media -q` → **141 passed**
  - `py -3.12 -m pytest tests/business_api/moments tests/business_api/media -q` → **106 passed**（未改其中任何文件）
  - `flutter analyze` → No issues found；`flutter test --timeout 120s --concurrency=2` → **3143 passed / 0 failed**
  - `py -3.12 -m pytest tests/mobile -q` → **70 passed**
  - `npm test`（frontend）→ **209 passed / 0 failed**
  - `py -3.12 scripts/export_openapi.py --check` → **PASS**
  - `pwsh -NoProfile -File scripts/verify.ps1` → **`Verification: PASS`（退出码 0）**
  - 部署三闸：`compat-probe.sh` → `===PROBE_OK===`；`rehearse.sh` → `===REHEARSE_OK===`；
    `migrate-production.sh` → `===MIGRATION_OK===`；`switch-and-verify.sh` → `===SWITCH_OK===`
- 未执行项：真机、APK/IPA 构建、多 uvicorn worker 压测、CDN/对象存储。
- 复用依据：Phase 4 的门禁结论在本次代码变更后**不再复用**，全部重跑（本次变更触及服务端代码与合同）。

## 阶段计时

| 阶段 | 开始 | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 读取冻结/设计/实施文档并核对代码 | 2026-09-18 | 2026-09-18 | 主动 | — | ADR 对照表（报告 §2） | 写套件 |
| ADR 一致性套件（含结构断言） | 2026-09-18 | 2026-09-18 | 主动 + 3 次自我纠正（测试断言写错，非产品缺陷） | — | 24 passed | 安全套件 |
| 安全套件（Security-001…005） | 2026-09-18 | 2026-09-18 | 主动 | — | 8 passed（修复后） | 修复 High-1 |
| **修复 High-1**：audience 签发门槛 + 交付实时复核 | 2026-09-18 | 2026-09-18 | 主动 | — | 新增 `audience.py`；更新 2 条既有用例 | 一致性 |
| 一致性/并发套件 + **修复 High-2**（processing 变体 GC 守卫）与 Bug-1（指标注册） | 2026-09-18 | 2026-09-18 | 主动（1 次返工：PowerShell 转义把换行写成字面 `\`n`，导致 3 个文件语法错误，已逐一修复） | — | 13 passed | 基准 |
| 基准 001–004（真实测量） | 2026-09-18 | 2026-09-18 | 主动（1 次返工：benchmark 003 造数缺 360p，期望值与实现不符；改按 allow-list 语义断言） | — | 4 passed | 规模 |
| 规模模拟 001–003 | 2026-09-18 | 2026-09-18 | 工具等待（1,000,000 引用写入 28.1s） | — | 3 passed | 门禁 |
| 合同重导出 + 自动化门禁 | 2026-09-18 | 2026-09-18 | 工具等待（Flutter 两次抖动 + 一次干净复跑；pytest 9.7 min；verify.ps1 长跑） | 文档撰写与门禁并行 | 见报告 §9 | 交付 |
| 推送 4 个验证提交 | 2026-09-18 | 2026-09-18 | 外部等待（`git push` 两次 `schannel` TLS 握手失败，第 3 次成功） | — | `origin/main` = `3b9e0f56` | 部署 |
| 部署：冻结前态 + DB dump + 候选镜像 | 2026-09-18 | 2026-09-18 | 主动（1 次返工：`compat-probe` 命中 Moments 旧版本 `ImportError`，修复并重打包） | — | 备份 14,529,289 bytes；候选镜像构建 OK | 兼容探测 |
| 部署：兼容探测 + 真实 PG 排练（含 3 个 P0/P1 修复） | 2026-09-18 | 2026-09-18 | 主动 + 返工（`compat-probe` 命中 `root`/`exists`；排练依次命中外键顺序、digest 竞态、引用/grant 竞态、探针自身 3 处缺陷） | — | `PROBE_OK` / `REHEARSE_OK`（四段并发全零异常） | 生产迁移 |
| 部署：生产迁移 + 切换 + 验证 + 密钥 | 2026-09-18 | 2026-09-18 | 工具等待（容器重建 + health） | — | `MIGRATION_OK` / `SWITCH_OK`；22 文件哈希一致、`restarts=0` | 证据与文档 |

总墙钟：同一工作日内完成。返工：12 次（3 次测试断言自我纠正、1 次 PowerShell 转义事故、1 次造数缺档、
1 次 Flutter 抖动复跑、1 次 `Set-Content -NoNewline` 压平测试文件行尾后从 git 恢复、
1 次发布脚本 CRLF、1 次排练等待竞态——`pg_isready` 在 bootstrap 阶段即返回导致提前连接、
3 次部署期产品缺陷修复、1 次探针自身清洗顺序修正），均记录在报告与本节。

## 交接与回退

- 已确认根因/已排除假设：
  - 已确认（High-1）：Phase 4 按"受众内可转发"实现为"签发即可读"，交付时不复核成员资格 ⇒ 非成员/匿名可读。
    已修复为"可校验才签发 + 每次交付实时复核"。
  - 已确认（High-2）：GC 只检查上传会话，不检查 `pending/processing` 变体 ⇒ 可回收正在产出变体的对象。已加守卫。
  - 已确认：ADR-001/002/004/005 无违反（结构 + 行为双证）；无 global plaintext dedup（策略层抛错）。
  - 已排除：Matrix 媒体迁移/重加密（代码级扫描 + 零对象断言）。
  - 已排除：客户端可查摘要（OpenAPI 参数扫描 + 响应体摘要值扫描）。
- 待办及验收失败项：无失败项。上线后治理/运维项见报告 §11 与 §12.5（ADR 修订、巡检告警、多 worker 压测）。
- 已发布与仅候选的区别：**已发布**（生产 `business-api` 容器已切换，迁移已应用，密钥已配置）。
  旧用户路径未变 ⇒ 新路径可随时停用（strangler）；回退只需 `rollback-api.sh`（迁移 expand-only，保留扩展表）。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：备份 `backup/20260918T120535Z/business-db.sql.gz`（仅灾难恢复）；
  回退 `release/rollback-api.sh` + 旧镜像 `redpacket-fee-20260917`；
  漂移检查 = `payload-manifest.json` vs 容器内 `/opt/business-api` 逐文件 SHA256（本次差异为空）。
- 运行中CI/命令/自己创建的隧道（无凭据）：无（SSH 经既有跳板；媒体密钥仅存服务器 `release/api-secrets.json`，`chmod 600`）。
- 下次恢复先检查的事实：① audience 收紧是否已写入 ADR（R1）；② `POST /media/platform/reconcile` 是否纳入巡检、
  3 个竞态计数器是否长期为 0；③ 生产是否仍配置 `BUSINESS_MEDIA_URL_SIGNING_SECRET` 与 `BUSINESS_MEDIA_MAINTENANCE_TOKEN`；
  ④ 若需回退：`sh /opt/starchat/releases/media-engine-20260918/release/rollback-api.sh`。
