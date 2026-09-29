# USDT 钱包工作台、链上流水现场与所有者转出申报

## 恢复入口

- 目标、授权与边界：用户要求移除只读验证横幅、美化钱包/链上详情/监控与事故/所有者转出，缩略显示哈希但复制完整，失焦和菜单返回保留链上只读现场，并解释人工出款与旧提现编号。用户批准书面规格后补充：所有者转出表单移除日志序号，原因码与用途说明合为管理员必选菜单；本轮又明确答复“批准你开始执行”，批准钱包 ADR 与含受控发布的逐项计划。反复 `PROTOCOL_PROBE_FAILED` 的修复方案独立制定，不混入钱包界面代码；生产发布以完成的候选和实时现场证据为准。
- 关联规格：[钱包工作台书面规格](../../superpowers/specs/2026-09-29-wallet-workspace-polish-design.md)及[静态视觉稿](../../verification/artifacts/2026-09-29/wallet-ui-design/wallet-direction.html)；[受保护 ADR](../../adr/2026-09-29-wallet-workspace-visibility-and-owner-transfer.md)及[逐项实施计划](../../superpowers/plans/2026-09-29-wallet-workspace-polish.md)已获用户本轮实施批准。[刷新探针故障修复方案](../../superpowers/plans/2026-09-29-refresh-watch-protocol-probe-repair.md)独立处理。[本轮验证记录](../../verification/2026-09-29-wallet-workspace-polish.md)逐阶段更新。
- 当前状态：WUI-1 至 WUI-7 本地实现、领域及独立质量/安全审查完成；前端 395/400 通过，5 项为改动前同名全局样式失败，业务 API/Worker 全目录 3182 通过、79 跳过，本地 `scripts/verify.ps1` 仍因无 `.env` 停在配置渲染。冻结的 2 API + 11 静态包通过隔离 PostgreSQL 六项断言及候选/回退镜像门禁，生产约 10:47 UTC 受控切换。r3 仅修正发布校验器对 Docker `Env` 列表顺序的误报，经独立安全复核 PASS 后按 SHA 门禁备份、原子替换；2026-09-29 11:00:46 UTC 正式 `server_release.py verify` exit 0，服务器与工作站严格 TLS 公开只读探针再次通过。**生产技术发布已完成；真实管理员会话 WUI-1 至 WUI-7 交互验收仍待执行。**
- 负责人、工作树、文件所有权、源码 commit：`C:/Users/Administrator/.codex/worktrees/wallet-ui-polish/StarChat`，`codex/wallet-ui-polish-20260929`；设计/计划提交 `87541ff3`、`c6a1e73c`、`e3535ca9`，基于 `e014619e`。领域代理独占 `admin_wallet_owner_transfers.py`、`owner_transfers.py` 及领域/API 测试；链上代理独占 `admin-chain-panel.js`、新纯函数模块及对应测试；主代理拥有本任务记录、验证记录与后续授权生命周期整合。各文件互不并发编辑。
- 最后更新时间：2026-09-29 19:04 +08:00。
- 下一条具体操作：使用真实授权管理员会话逐项验收 WUI-1 至 WUI-7 的只读页面、菜单现场、完整复制及申报预检/确认界面；保持实际资金写入依既有受保护流程。独立处理刷新探针反复告警，不把本次钱包发布或当前 watcher 空状态当作邮件送达证明。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| WUI-1 | 去掉只读验证提示；写操作仍按需验证 | 已实现 | 授权面板专项、真实浏览器回归通过 | 生产技术验收通过；真实会话待验收 | 待真实管理员会话验收 |
| WUI-2 | USDT 钱包工作台统一视觉、响应式及准确数据状态 | 已实现 | 500px/1440px 合成视觉验收及布局断言通过 | 生产技术验收通过；真实会话待验收 | 待真实管理员会话验收 |
| WUI-3 | 缩略哈希与完整复制 | 已实现 | 链上专项覆盖复制成功/拒绝与完整值 | 生产技术验收通过；真实会话待验收 | 待真实管理员会话验收 |
| WUI-4 | 失焦/菜单返回保留授权后的链上只读现场 | 已实现 | 真浏览器菜单返回与晚到会话响应回归通过；跨标签页、401/403、网络未知专项通过 | 生产技术验收通过；真实会话待验收 | 待真实管理员会话验收 |
| WUI-5 | 链上详情按证据、路径、关联分组 | 已实现 | 链上 DOM/状态专项通过 | 生产技术验收通过；真实会话待验收 | 待真实管理员会话验收 |
| WUI-6 | 区分人工出款队列、链上流水与托管提现申请编号 | 已实现 | 名称、来源与关联说明测试通过 | 生产技术验收通过；真实会话待验收 | 待真实管理员会话验收 |
| WUI-7 | 监控/事故排版；转出申报无日志输入、用途单选、预检后确认 | 已实现 | 领域 27 项含 OpenAPI；人工钱包/链上专项与独立审查通过 | 生产技术验收通过；真实会话待验收 | 待真实管理员会话验收 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源 commit | 包名/签名渠道 | 文件位置及 SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| 书面规格与静态稿 | 设计候选 | `87541ff3` + `c6a1e73c` | 不适用 | 见上方链接；本阶段尚未冻结发布 SHA | 未发布 |
| 刷新探针只读调查 | 2026-09-29 04:51 UTC 前现场快照 | 不适用 | 不适用 | [报告](../../verification/2026-09-29-refresh-watch-protocol-probe.md)从原管理台工作树按字节复制，SHA-256 `5cfe504d507e7f0a39256cedb780a1caf9ede3944bccb425ea4fe4b8be0c40e1` | 仅调查，未修复 |
| 钱包工作台生产发布 | API `sha256:83aedc06dd6763f819c4147736d0f422d238f4284b926429094d3e38eb8367f5`；Worker 仍为 `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`；schema 0092 | `ec34c51ddf92a084b0681be388b70505a89d4b91` | API 受控镜像 + 11 静态 | [冻结包与 21 文件清单](../../verification/artifacts/2026-09-29/wallet-ui-acceptance/release-package-evidence.json)：archive `0e63fe9d77d307c02fa42be71626d2061564d5f19c5bbee460efc61e09f64450`，manifest `02d1b118045dbf8de84dbfae08a6fd9893a2af3accd9b1986a8a0ee3ad65229a`；`private/verified.json` SHA `49a523a8471d66e514f7415bd26925320a4d5b4f45a71f46012c98f8892363ce` | 2026-09-29 11:00:46 UTC 正式 verify exit 0；真实管理员会话待验收 |

设计检查：2026-09-29 本工作树通过 Python `html.parser.HTMLParser` 解析静态稿，并断言申报表单无日志序号、原因码、用途说明三个旧输入且存在必选用途菜单；`git diff --check` 退出 0。此为文档/示意验证，不能代表业务实现通过。

前端改动前基线：PowerShell 7 UTF-8 会话，在 `frontend/` 运行 `npm test`，退出码 1；345 项中 340 通过、5 失败、0 跳过，产品源码仍为 `e014619e` 的输入。五项为 `frontend/tests/gradient-divider.test.mjs:13` 渐变分隔符、同文件 `:105` 分隔符与品牌色、`frontend/tests/group-moments-wallet-demo.test.mjs:28` 公告/Moments/钱包文案、`frontend/tests/token-contract.test.mjs:17` 明暗语义色键、同文件 `:66` 客服身份黄色。该基线只用于区分后续新增失败，不能作为本任务代码通过证据；依赖锁版本、完整命令日志与最终候选 SHA 将在实施验证记录补齐。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 既有调查与视觉稿 | 较早会话，准确开始时间未记录 | 2026-09-29 用户书面规格审阅 | 主动与工具；准确耗时未知 | 前轮 | 已形成初版规格及静态稿 | 吸收用户修正 |
| 用户修正与规格更新 | 2026-09-29 本轮，准确开始时间未记录 | 2026-09-29 13:37 +08:00 | 主动；准确耗时未知 | 主代理 | 修订规格/静态稿并提交 | ADR/计划审查 |
| ADR 与实施计划 | 2026-09-29 前轮，准确开始时间未记录 | 2026-09-29 本轮用户批准，准确答复时间未记录 | 代理并行、审查返工及外部等待；准确耗时未知 | ADR、计划 | 已批准本地实施 | TDD 红绿 |
| 前端改动前基线 | 2026-09-29 本轮，准确开始时间未记录 | 2026-09-29 本轮，准确结束时间未记录 | 工具；准确耗时未知 | 计划代理 | `npm test` 340/345，5 个原有样式断言失败 | 最终候选复测并归类 |
| 本地实施启动/预检 | 2026-09-29 15:07 +08:00 | 2026-09-29 15:08 +08:00 | 主动/工具 | 领域与链上代理并行前置 | 干净 HEAD、唯一迁移 head、OpenAPI 基线与工具版本已记录 | 专项 red/green |
| 本地实现、专项与审查返工 | 2026-09-29 15:08 +08:00 | 2026-09-29 17:56 +08:00 | 主动/工具、代理并行；部分等待计时未分离 | 领域、链上、会话、规格/安全审查 | WUI-1 至 WUI-7 实现；两处规格细节补测；最终 `npm test` 395/400，五项旧基线失败；真实 Chrome 菜单/会话 2/2 | 业务全目录与发布冻结 |
| 生产只读预查 | 2026-09-29 17:42 +08:00 | 2026-09-29 17:50 +08:00 | 工具/只读 | 发布准备代理，与本地审查并行 | API/Worker healthy、schema 0092、2 API + 11 静态目标；[精确快照](../../verification/artifacts/2026-09-29/wallet-ui-acceptance/release-prep.md) | 最终源码/实时生产重新冻结 |
| 业务 API/Worker 全目录 | 2026-09-29 17:28:39 +08:00 | 2026-09-29 18:09:13 +08:00 | 工具；与前端审查/发布准备并行，不叠加墙钟 | Python 全目录 | 3182 passed、79 skipped、1 条依赖弃用警告、exit 0，2434.03 秒；[日志](../../verification/artifacts/2026-09-29/wallet-ui-acceptance/business-api-worker-pytest.txt) | 隔离发布门禁 |
| 发布包冻结、预检和隔离恢复 | 2026-09-29 10:38 UTC 冻结；生产阶段准确开始未记录 | 2026-09-29 约 10:47 UTC 切换前 | 工具/外部等待；逐阶段精确耗时未记录 | 发布与安全审查 | 21 文件包及 2 API/11 静态 SHA 冻结；候选/回退 API 9/9、Worker 8/8；隔离 PostgreSQL 六项钱包场景通过，克隆和匿名卷删除经核对 | 受控部署 |
| 受控切换与公开只读探针 | 2026-09-29 约 10:47 UTC | 2026-09-29 约 10:52 UTC | 工具；精确阶段耗时未记录 | 生产发布 | API/静态切换完成、Worker 未改；服务端与工作站严格 TLS ready/未授权 401/11 静态 SHA 通过 | 正式 verify |
| 正式 verify 首次尝试 | 2026-09-29 约 10:52 UTC | 同次立即停止，精确时刻未记录 | 工具/诊断返工 | 发布控制脚本 | Docker `Env` 89 项原文集合相同、仅次序不同，原比较误报；当时未写 `private/verified.json` | r3 已独立复核、受控修正并重跑 |
| r3 控制脚本修正与正式 verify | 2026-09-29 约 11:00 UTC，准确开始未记录 | 2026-09-29 11:00:46 UTC | 工具/独立安全复核；准确耗时未记录 | 发布控制脚本 | 原脚本先备份；新脚本 SHA 门禁和原子替换通过；正式 verify exit 0、27 个其他容器不变、API/Worker healthy/restart 0、11 静态与私有日志门禁通过；公开只读探针两地再通过 | 真实管理员会话验收 |

总墙钟及重复工作耗时：历史阶段没有完整起止计时，不能精确计算。修订原因是用户在批准规格时提出申报表单修正，已集中落在本工作树，不重复业务代码实现。

## 交接与回退

- 已确认根因/已排除假设：链上列表消失由 `admin-wallet-access.js` 的失焦授权回查清空与 `admin-dashboard.js` 的菜单切换销毁共同导致；现在保留受授权的只读现场并阻断旧会话响应回填。监控探针故障另见[只读排查](../../verification/2026-09-29-refresh-watch-protocol-probe.md)，不能把当前已恢复视为邮件历史投递成功。
- 待办及验收失败项：本地完整 verify 仍被缺 `.env` 阻断，五项原有前端样式测试仍失败。生产正式 `server_release.py verify` 已 exit 0，公开只读探针两地再次通过；真实管理员会话验收尚未执行，不能用匿名 401 或合成界面代替。
- 已发布与仅候选的区别：本地功能提交和 21 文件压缩包冻结；生产 API 与 11 静态已切换，Worker、schema 与其他 27 个容器不变。原版 verifier 曾因 `Env` 顺序误报，r3 修正后 `private/verified.json` 已生成，SHA `49a523a8471d66e514f7415bd26925320a4d5b4f45a71f46012c98f8892363ce`。**生产技术验收通过，真实管理员会话待验收。** [冻结清单](../../verification/artifacts/2026-09-29/wallet-ui-acceptance/release-package-evidence.json)与[校验器修正说明](../../verification/artifacts/2026-09-29/wallet-ui-acceptance/verification-env-order-r3.md)分别记录身份与误报修复。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：私有备份位于 `/opt/starchat/releases/wallet-workspace-20260929-v1/private/`（0700）；数据库备份 SHA `2d155401fc430b9809e86e1fa35219a72df97ccace765cc7c27904862acf9d06`、0092 回退镜像 tar SHA `922f93d9c57ccf09909cb986af4200aa0e4df5e679ce277d6b8f1f33cd74ffc8`，回退 API 镜像 `sha256:0bdf751c05015454781c24b66a0c5066ca08ce23436c232ff8aecd1ba5042993`。旧控制脚本另存 `private/server_release.py.pre-env-order-r3`，SHA `561b17e14afe51ea57e61168734c38ea8867dca1c5e620def5112f21566131ff`；当前脚本 SHA `febd6177661f45eefda1464dd646ce382c468ec1e382a60458442219dedac153`，原 archive/manifest 不变。guarded Compose SHA `98ce96d861fa207319f0cbeb46ac3909aa3b8f468d700272ce9fb9c90573691d`。不重跑 `deploy`；只有发现实际异常再按受控回退路径处理。
- 运行中 CI/命令/隧道：本地业务全目录测试已退出 0；本任务无运行中 SSH 隧道。
- 下次恢复先检查的事实：读取本任务规格、ADR、计划和用户批准，核对产品提交 `ec34c51ddf92a084b0681be388b70505a89d4b91`、archive/manifest SHA、`private/verified.json` SHA、当前 API/Worker/Compose/静态/schema/授权探针；正式 verify 是 2026-09-29 11:00:46 UTC 的通过快照，后续操作先重读现场。真实管理员会话与独立 watcher 告警修复仍待后续任务。
