# 按服务实际运行路径验证续期协议镜像门禁 Implementation Plan

状态（截至 2026-09-28 17:41 UTC）：**门禁 ADR 已获用户批准；本地实现、聚焦验证及生产安装完成。独立恢复 r2 的候选/回退 API 与 Worker 镜像逐角色验证通过，r2 API-only 已上线；管理台 A1–A5 候选的最终镜像与生产发布仍待验证。** 本计划补充已批准的[管理台入口计划](2026-09-28-admin-entry-merge.md)，只处理其生产发布所需的续期协议镜像门禁问题。批准记录见[角色化门禁 ADR](../../adr/2026-09-28-role-aware-refresh-image-gate.md)，早期本地测试见[历史 v3 发布包验证记录](../../verification/artifacts/2026-09-28/admin-entry-release/package/v3/guard-proposal-verification.md)，r2 实施证据见[独立恢复验证](../../verification/2026-09-28-restore-identity-moments.md)。

## Task 1：证据与失败测试

- [x] 已记录原 guard/probe SHA、候选 API 与回退 API 各 9/9、Worker 原门禁单独退出码 `1`（`RELEASE_PROTOCOL_GATE_FAILED`）；Worker Dockerfile 将 API 源码复制到 `/opt/business-api` 并另装业务包，实际 `WORKDIR=/opt/business-worker/app`、`CMD=["python","main.py"]`。旧副本 `/opt/business-api/app/main.py` SHA `e22e46a441907dbf40a56c40319867197b07125e4fad939488f4f73fa4d01c8a`，实际 Worker 入口 SHA `03b74f5ec9283464b8a1596dad142dd1a01bdc2e0fdb9211c248f84c67e3c4c1`，site-packages `app/main.py` SHA `4170323c047e628af842e26b897930f3c4287e5ccc601b738b3d9807cdc5b6dd`；当前新门禁按运行路径 8/8 通过。
- [x] 在 `tests/infra/test_refresh_release_guards.py` 写先失败的角色缺失/错配、Worker 实际导入路径、探针失败阻断切换、候选与回退双角色覆盖测试。验证失败原因是旧门禁只有无角色的 API ASGI 探针。

## Task 2：最小门禁修复

- [x] 修改 `scripts/business_release_guard.py`，在 `check`、`freeze`、`deploy`、`rollback` 中绑定不可变镜像和服务角色；保持当前 API 9 项探针及容器隔离参数。新增 Worker 实际运行路径探针，验证 8 项运行能力与 T2 链源超时策略；告警投递沿用现有 Worker 专项。失败证明不包含凭据、令牌、PII 或完整异常数据。
- [x] 修订 `docs/runbooks/refresh-release-guards.md`：API 最终镜像运行原 9 项 ASGI 续期检查；Worker 最终镜像运行 8 项实际 Worker 能力检查；两者均在切换和回退前强制通过。早期管理台 v3 发布器清单已绑定探针与门禁 SHA，本地测试覆盖 SHA 漂移拒绝；后续 A1–A5 包另行冻结。
- [x] 聚焦红绿、`tests/infra/test_refresh_release_guards.py` 34/34、早期 v3 发布器 22/22、Python 语法、Ruff 及 `git diff --check` 已通过，脚本已完成独立规格/领域和质量/安全审查。`tests/infra` 全量不是本项已完成证据。

## Task 3：受控生产预备与发布

- [x] 已在服务器 0700 目录备份旧 guard/probe 及权限/SHA，安装并核对新版本；当前不可变 API 与 Worker 镜像实测 9/9、8/8。备份：`/opt/starchat/releases/role-aware-guard-20260928-d0_vhuqs`。
- [x] 独立恢复 r2 的不可变候选及回退 API、Worker 镜像逐角色运行新门禁并通过；r2 API-only 切换与 verify 通过，证据见[恢复验证](../../verification/2026-09-28-restore-identity-moments.md)。门禁安装继续保留。
- [x] 用新的独立发布 ID 在本地冻结仅 A1–A5 的 API/静态清单并归档：`tokens.css` 使用当前生产原件加 58 个登录变量的专用覆盖件，移除仅换行不同的 `admin-staff-activation.js`；早期 v3 为历史失败包，恢复后 v6 及后续 v8 的 39 项业务 payload SHA 相同，候选清单见[管理台验证记录](../../verification/2026-09-28-admin-entry-merge.md)。
- [ ] A1–A5 上传与切换前重新核对生产 SHA、Compose/schema、其他容器并建立新的 0700 私有快照；必须使用恢复 r2 后的基线，不能沿用旧 v3。
- [ ] 在禁网隔离 PostgreSQL 恢复克隆中运行四项账号并发竞争；核对最终 API/Worker 镜像、Compose、schema、静态 SHA 与续期门禁证明。通过后按已批准的管理台计划切换 API 与静态，随后做服务器及工作站 HTTPS/TLS 验收和可回退性检查。
- [ ] 更新 A1–A5 验收台账、验证记录与阶段耗时；保留真实账号邮件/短信、实际资金操作的验证缺口。已确认的资料与朋友圈回归按[独立恢复计划](2026-09-28-restore-published-identity-moments.md)完成 r2 API-only 恢复，A1–A5 已以恢复后基线重冻候选，仍待最终发布验证。
