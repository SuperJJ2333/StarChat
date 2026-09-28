# 2026-09-28 管理台入口合并：验证与发布记录

状态（截至 2026-09-29 01:50 +08:00）：**A1–A5 已由 v8 在生产技术发布并完成匿名验收。** 生产 API `sha256:0bdf751c05015454781c24b66a0c5066ca08ce23436c232ff8aecd1ba5042993`，Worker 保持 `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`，schema `0092_admin_session_entry_mode`，18 个后台静态目标切换，`download.html` 排除。2026-09-28 17:40:24 UTC 生产迁移完成，17:41:37 UTC 受控 deploy，17:41:54 UTC 内部 verify exit 0；服务器与工作站经跳板 strict TLS ready/401/18 静态 SHA 各两次 exit 0。[去敏生产结果](artifacts/2026-09-29/admin-entry-release-v8/production-result-evidence.json)记录完整镜像、SHA、容器、日志及 P3 观察限制。真实登录、客服开通/改密、目录、钱包只读与真实资金/邮件/短信操作仍待授权产品会话分别验收，匿名探针不证明这些业务操作。

## 范围与授权

按已批准的[设计](../superpowers/specs/2026-09-28-admin-entry-merge-design.md)、[ADR](../adr/2026-09-28-admin-entry-merge.md)及[计划](../superpowers/plans/2026-09-28-admin-entry-merge.md)实施 A1–A5：管理员/客服同页切换，首次客服选择邮箱或手机验证，共用密码的客服专属改密，墨夜银锋登录与图标加载态，钱包负责人只读免操作密码，以及仅管理员可查看的用户目录。用户另确认现有 1 条旧客服开通记录可在上线后**一次性重验**。

钱包 T2 的现行行为作为候选依赖保留：仅 `SOURCE_READ_BUDGET_EXPIRED` 记 `MANUAL_SOURCE_UNAVAILABLE`/T2、不自动暂停，其他事故及资金门槛不变。候选已合并 r2 恢复后的生产 API 源码与锁定 `regex==2026.2.28`，新增可空 `0092_admin_session_entry_mode`；旧管理会话在新版本上线后需重新登录。Worker 运行镜像保持上述原值，非本任务的 iOS 下载页不在静态发布清单。

## 红绿与专项

| 范围 | 先失败的证明 | 修复后证据 |
| --- | --- | --- |
| 管理员入口与客服身份 | 纯客服持有效图形验证码可通过管理员入口的 ASGI 用例先返回 200，预期 403 | `identity/test_staff_login.py` 聚焦 4 项通过；管理员入口签发前锁内要求 `SUPER_ADMIN` |
| 钱包嵌套修复弹窗 | 父弹窗关闭后，人工补录子弹窗仍留在 DOM，测试 `1 != 0` | `frontend/tests/admin-repair-entry.test.mjs` 8/8 通过，关闭父弹窗时清除子弹窗及敏感输入 |
| 目录搜索隐私 | 审计 `query_digest` 和分页游标均含可枚举的原始 SHA256；新增 2 项测试失败 | 审计只记 `query_present`、结果数量；游标使用域分离 HMAC-SHA256，目录专项 10/10 通过 |
| 钱包慢读撤权 | 先组装响应、再撤销 owner 时缺末次校验；新增守卫用例因接口缺失失败 | 路由初次校验后标记请求；成功响应首字节发送前重验管理会话与 owner；单元及真实 `/incidents` 撤权模拟通过 |
| 用户目录慢读撤权 | 查询后撤销管理员角色或审计后替换管理会话，新增两个 ASGI 用例均先返回 200，预期 403/401 | 查询完成后再核会话及 `SYSTEM_ADMIN`，成功响应首字节发送前再次复核；两项转绿，目录全文件 12/12、钱包边界 35/35，响应不含联系方式。追踪中间件顺序的回归用例先发现最终 403 被计为 200，修正后目录、追踪及错误响应合计 21/21 通过，最终响应带匹配的 `X-Trace-Id` |
| 旧客服摘要 | 旧 v1 摘要只有一个联系方式，不能证明第二渠道未变更 | v2 纳入双渠道；保守要求一次重验的测试通过，用户确认接受现有 1 条记录的影响 |
| STAFF 会话晋升 | 客服入口会话签发后晋升为管理员，旧实现可沿原会话取目录、续期和 step-up；入口模式缺迁移时测试先红 | `0092` 可空扩展和 STAFF/ADMIN 入口绑定后旧 NULL 会话失效；管理会话与迁移专项转绿，[红绿记录](artifacts/2026-09-28/admin-entry-rebase-r2/entry-mode-red-green.md) |
| 客服改密竞态 | 路由层核验后撤管理员角色，旧实现仍可改密 | User 锁内重核 STAFF 入口；`test_staff_password.py` 11 passed，[领域修复记录](artifacts/2026-09-28/admin-entry-rebase-r2/domain-review-fixes.md) |
| 目录游标边界 | 保留 HMAC、篡改时间戳或 ID，旧实现仍返回 200 并改变分页边界 | HMAC 同时签署规范化搜索词、时间戳和 ID；目录测试 13 passed；旧游标须从第一页重新获取 |
| 钱包事务入口竞态 | STAFF 入口令牌通过路由检查后晋升管理员，旧实现可创建 owner grant 并通过操作密码写入授权，两条测试先红 | `require_wallet_session` 在事务锁内初次及末次校验入口模式和当前角色；两条转绿，钱包/操作密码/客服改密 57 passed，相邻四组 71 passed |

前一候选的独立规格/领域审查通过，旧摘要一次重验为已披露兼容差异；独立质量/安全预审促成可枚举摘要、慢读撤权和 STAFF 入口绑定修复。r2 重基线后发现的客服改密、目录游标、钱包事务入口 P2 均完成红绿；v8 最终独立质量/安全技术发布复核 PASS，无未关闭 P0–P2。逐路由“查询同事务回调”与实际采用的统一响应前复核不同：统一守卫覆盖 21 条 GET，在慢查询之后且响应首字节之前复核；最后一次复核至网络发送间仍存在短窗口，生产实际撤权可阻断下一次读取。部分修复/转账 GET 另有事务内回调。目录审计的 `SUCCESS` 表示查询完成；若审计后会话被替换，响应守卫仍拦截敏感结果，不能将该审计解释为数据已送达。

## 本机门禁与已知基线差异

| 检查 | 当前结果 |
| --- | --- |
| 前端 Node 全量 | r2 重基线后 345 passed、exit 0；[日志](artifacts/2026-09-28/admin-entry-rebase-r2/frontend-full-final.log)。旧 344 passed 是 v3 阶段结果。 |
| 钱包 Python 全目录 | 1134 passed、20 条依赖专用环境的 skip；owner 21 条 GET 中 16 条 200、5 条业务数据不存在的 404 均越过 grant 门槛 |
| 账号凭据/身份专项 | 184 passed、6 条专用 PG skip；生产账号凭据合并专项 52 passed、Worker 事件 1 passed；客服相关最终 60 passed、1 条旧入口断言失败，现已改为 `/auth/staff-login` 并聚焦通过 |
| Business Worker 全量 | 首次 195 passed/4 failed，旧 handler/媒体装配夹具修正后 199 passed、exit 0；[重基线说明](artifacts/2026-09-28/admin-entry-rebase-r2/baseline-and-worker-gates.md)与[成功日志](artifacts/2026-09-28/admin-entry-rebase-r2/business-worker-full-pass-2.log)。 |
| 基础设施/平台 | r2 重基线后 infra 210 passed、exit 0；旧阶段 getui 28 passed（2 条既有 warning）、Matrix Bot 9 passed、mobile 238 passed/1 skipped；UI contract 32 components/433 screens PASS。未因文档更新重复未变输入。 |
| 静态与契约 | r2 重基线后 271 文件 AST 解析、Compose `.env.example` 渲染、Alembic 唯一 head **0092** 与离线 upgrade、`git diff --check` 通过；同步性能诊断生成件后 OpenAPI `--check` exit 0、契约测试 4/4。生产由 0091 非破坏迁至 0092， nullable `entry_mode` 与 STAFF/ADMIN 约束实核。 |
| 角色/追踪聚焦 | 双角色本地门禁 34/34；已发布 r2 的追踪/性能/钱包/目录文件补齐后 62/62，[重基线说明](artifacts/2026-09-28/admin-entry-rebase-r2/baseline-and-worker-gates.md)。 |
| `scripts/verify.ps1` | 已真实运行：Repository policy、Deployment policy、Template unit 均通过；在 Matrix `-RenderOnly` 因隔离工作树缺 `.env` 停止。尝试创建仅供渲染的临时 `.env` 被自动批准审核拒绝，未创建；其余不依赖该文件的门禁单独执行，不能称整脚本通过。原始输出见 `artifacts/2026-09-28/admin-entry-release/full-verify.log`。 |
| 业务全目录 | v3 的注册 5 fail、朋友圈 20 fail 是 r2 发布前现网回归历史，r2 已独立修复。管理台 r2 重基线第一次套件在 18% 主动中断以补齐追踪文件，后一次 3029 passed/83 skipped/3 项旧 0091/0088/枚举断言失败；修正三个旧测试文件后完整 Business API **3032 passed/83 skipped/1 项既有依赖弃用 warning，exit 0，2509.89 秒**，[最终日志](artifacts/2026-09-28/admin-entry-rebase-r2/business-api-full-pass-final.log)。候选 21 API 文件 SHA 在测试修正后未变。 |
| PostgreSQL 并发与 0092 | 本地无专用 PG 的 4 条 skip 由 v8 禁网真实 PostgreSQL 克隆补证：0091→0092、兼容回退 API TestClient ready 200/`database=ready`，`mail_reset_vs_staff_change`、`revoke_vs_staff_change`、`role_grant_vs_activation`、`staff_change_vs_otp_recovery` 四例全通过，随后精确移除克隆；[准备证据](artifacts/2026-09-29/admin-entry-release-v8/server-stage-evidence.json)。生产 0092 迁移 exit 0、旧管理会话 2 行与旧 NULL 2 行见[结果](artifacts/2026-09-29/admin-entry-release-v8/production-result-evidence.json)。 |
| v8 发布器与角色门禁 | v4 是本地历史草稿，v5 单/双 Compose 来源冲突、v6 探针多建财务表、v7 克隆就绪竞态均停于生产切换前且保留审计；v8 独立冻结 manifest SHA `dc168f6aea06991e3c203109d7a577f51f7f20bb281a0cb86309d98a899fb63b`、归档 SHA `815bb4cba3a8ae03b083548559b95559b930376fc533f429da222e67468b7245`，本地发布器 61/61 与 Ruff 通过；候选及兼容回退 API 各 9/9、原 Worker 8/8，生产切前及 deploy 重新逐角色证明。 |

v3 阶段原始测试日志保留于 `artifacts/2026-09-28/admin-entry-release/`：`business-suite.log`、`business-suite-excluding-live-drift.log`、`infra-suite.log`、`staff-suites-final.log` 等。注册文件当时 17 项通过、5 项失败；之后确认是 r2 发布前的现网回归，已由独立 r2 恢复。管理台重基线后的完整 Business API 套件最终 exit 0：3032 passed/83 skipped；旧失败仅作时间点审计，不是当前生产缺口。

第一次发布包及 v2 包在最终范围复核中被判无效：`tokens.css` 错取工作树全局 token，包含非 A1–A5 配色。v3 虽曾本地冻结并经独立审查，却基于 r2 发布前镜像，从未上传、构建或切换。v4 仅草稿；v5–v7 分别在 Compose 双来源、PG 探针表范围、克隆 TCP 就绪处 fail closed，均保留原样审计。v8 单独冻结并发布，只覆盖生产基线上的 21 API、0 Worker、18 静态；[范围及 SHA](artifacts/2026-09-29/admin-entry-release-v8/README.md)。

2026-09-28 r2 发布前，业务全量门禁揭示**当时的现网回归**：9 月 24 日已批准并发布的 ADR-0085 字素昵称、资料审计去原文及注册幂等语义退回旧实现，朋友圈互动通知隐私/分页也退回旧投影。独立恢复计划采用最小八文件 API overlay 和锁定的 `regex` wheel，保留 0091 视频海报及后续行为；r2 已于 2026-09-28 15:14:50 UTC API-only 切换，完整恢复套件 2837 passed/78 skipped，服务器及工作站严格 TLS 匿名探针通过。真实资料写入、旧完成请求重放和朋友圈互动仍待授权产品会话验收；匿名探针不证明这些操作。

## 生产发布与回退

角色化续期门禁的[ADR](../adr/2026-09-28-role-aware-refresh-image-gate.md)与[实施计划](../superpowers/plans/2026-09-28-role-aware-refresh-image-gate.md)已获用户批准。生产 guard/probe SHA 分别为 `78b2beb6c20484cea04fa8e77c1dd23b9a3e401af9d6fafd3e4b7d316d07beec`、`d77a83e89d848bfc8b6d7dad72b9abd01d60550a6e356d0a12b382674c37b678`。v8 候选 API `0bdf751c…` 与 0092 兼容回退 API `c5e1fe41…` 均 9/9，未切换 Worker `3c9e4bbf…` 为 8/8；部署前及 deploy 阶段证明 SHA 见[生产结果](artifacts/2026-09-29/admin-entry-release-v8/production-result-evidence.json)。

用户先按[独立恢复计划](../superpowers/plans/2026-09-28-restore-published-identity-moments.md)完成 r2，再按获批管理台 ADR/计划执行 v8。v8 发布归档 47 个常规成员、39 个 payload（API 21/Worker 0/静态 18），基线精确绑定原 API/Worker/Compose/0091 与所有静态 before SHA。私有备份 root/0700、最终 74 个常规文件均 0600、无 symlink；dump SHA `a211d90151edc3112126f23a874695727a90a2853e9edd4be296e05a4bb915de`。生产 0092 nullable 扩展无 downgrade：迁移前管理会话 2 行，迁移后 NULL 2 行，旧会话须重新登录；未运行生产财务写入、邮件或短信。[v8 阶段证据](artifacts/2026-09-29/admin-entry-release-v8/server-stage-evidence.json)与[发布结果](artifacts/2026-09-29/admin-entry-release-v8/production-result-evidence.json)。

发布后 `server_release.py verify` exit 0，候选 API `sha256:0bdf751c05015454781c24b66a0c5066ca08ce23436c232ff8aecd1ba5042993` healthy/restart 0；Worker 原 `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf` healthy/restart 0；18 个静态本机及双端 HTTPS 响应 SHA 匹配。服务器和工作站经临时 jumper SOCKS 的严格 TLS JSON ready、无凭据 `/api/v1/admin/context` 401 各两次 exit 0，隧道已关闭。发布后一次 `_other_containers_unchanged` 只读检查瞬时 exit 1（运行容器集合差异，原因未证实）；立即再查新增/缺失/同名 ID 变化均空，随后 17:48:08 与 17:48:58 UTC 两次间隔检查确认 29 运行容器及其他 27 名称、ID、镜像、StartedAt 精确等于准备基线，API/Worker 日志自切换起 Traceback 0、JSON ERROR/CRITICAL 0、未归类 ERROR 字样 0。最终独立安全复核把未定因瞬时观察列 P3，无持续漂移；未因该观察执行会停 API 并撤销管理 family 的回退。若后续真需回退，仅按[冻结执行单](artifacts/2026-09-29/admin-entry-release-v8/production-execution-handoff.md)停唯一 API 入口、撤销管理 refresh family、恢复静态并切 0092 兼容 API，不降级 DB。**匿名探针不能证明真实客服邮件/短信、登录后目录/资料与钱包只读，也未做真实资金写入；这些待授权产品会话验收。**
