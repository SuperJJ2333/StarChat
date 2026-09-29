# USDT 钱包工作台实施验证记录

## 身份与授权

- 用户于本轮明确答复“批准你开始执行”，批准[钱包 ADR](../adr/2026-09-29-wallet-workspace-visibility-and-owner-transfer.md)和[逐项计划](../superpowers/plans/2026-09-29-wallet-workspace-polish.md)的实施及 Task 10 受控生产发布。发布执行按[后台工作流](../runbooks/admin-production-workflow.md)重核候选、生产基线和回退证据；正式生产验收仍受 `server_release.py verify` 结果约束。
- 工作树：`C:/Users/Administrator/.codex/worktrees/wallet-ui-polish/StarChat`，分支 `codex/wallet-ui-polish-20260929`；开始基线 commit `e3535ca9a41167f98daa217f7acf135e329cb3d0`，当时 `git status --short` 为空；该行是 15:07 的历史基线。最终产品提交为 `ec34c51ddf92a084b0681be388b70505a89d4b91`。
- 根 `AGENTS.md`、管理台与移动交付工作流、规格及计划已作为实施入口读取。`.codegraph/` 不存在。本任务无移动端包。

## 2026-09-29 15:07–15:08 +08:00 前置检查

全部命令在 PowerShell 7 中设置无 BOM UTF-8 输入/输出及管道编码，Python 设置 `PYTHONUTF8=1`、`PYTHONIOENCODING=utf-8`。工作站 Windows 10.0.19045，PowerShell 7.6.5，Node v22.22.2，npm 10.9.7，Python 3.12.10，Docker CLI/Server 29.2.1；C 盘可用空间约 94.23 GiB。`scripts/verify.ps1` 存在，根 `.env` 不存在；不能为通过门禁复制生产秘密。`frontend/package.json` SHA-256 `24f569670f98549ab61a8f7eae18a1b6d5eb5fCCE97E1B496E8AE2DF6BA22FCA`（大小写仅为显示），前端无 package lock。OpenAPI 文件基线 SHA-256 `a6e95fb56393345b7b81cb879306078e40c2efa9779a1ebc219ca2cfdda84681`。

| 检查 | 命令及目录 | 结果 |
| --- | --- | --- |
| 独立迁移 head | `py -3.12 -m alembic heads`，`services/business-api/` | exit 0；`0092_admin_session_entry_mode (wallet_access) (head)` 一项 |
| 当前 API 契约 | `py -3.12 scripts/export_openapi.py --check`，根目录，`PYTHONPATH=services/business-api;.` | exit 0；`OpenAPI contract: PASS`，实施前基线 |
| Docker 可用性 | `docker version --format '{{.Client.Version}}\|{{.Server.Version}}'`，根目录 | exit 0；`29.2.1\|29.2.1` |

前轮同一工作树、相同产品源码 `e014619e` 输入的 `frontend/npm test` 基线为 exit 1、345 项中 340 通过、5 个样式令牌断言失败（无跳过），已在[任务台账](../workflow/tasks/2026-09-29-wallet-workspace-polish.md)逐项列名；本轮文档提交没有改变该产品输入。它不是后续功能通过证据，最终候选必须重新运行、分类新增失败。专项 red/green 和完整门禁结果将逐阶段追加。

## 阶段

| 阶段 | 当前事实 | 下一步 |
| --- | --- | --- |
| TDD 实现 | WUI-1 至 WUI-7 代码与专项回归已完成；owner 预检唯一解析、菜单现场与二次确认均先红后绿 | 冻结最终源码身份 |
| 规格、领域与质量安全审查 | 独立规格复核、领域复核、质量/安全复核均完成；审查发现的跨标签页/晚到响应与重取证明测试缺口已修复，队列/事故独立读取时点及观察器扫描时点文案已补齐，最终无 P0–P2 | 发布前重核候选 SHA |
| 完整门禁与发布 | 前端全量 400/395/5（五项已知基线）；OpenAPI/领域专项和业务 API/Worker 3182/79 跳过通过；本地完整 verify 因缺 `.env` 停在 render-only 配置。生产隔离 PG、候选/回退镜像门禁通过，API/11 静态受控切换；首次正式 verify 因 Docker `Env` 列表顺序误报停止，r3 修正后于 11:00:46 UTC 正式 verify exit 0；服务器与工作站严格 TLS 公开只读复核通过 | 真实管理员会话 WUI-1–7 验收 |

## 本地实现与审查（2026-09-29 15:08–17:44 +08:00）

领域改动仅扩展所有者转出**预检**模型：可省略 `log_index`，仅当新鲜证明中恰有一条官方 USDT 转出时自动解析真实索引；零笔及多笔分别返回稳定 409。执行请求仍要求精确索引，保持原 owner、ADMIN、钱包 grant、预算锁、新鲜链上覆盖、账本平衡、幂等、审计及 Outbox。新增“预检索引 7 后证明变化，执行必须拒绝且零财务副作用”的回归。领域独立审查无 P0/P1 代码缺陷，补齐测试后通过。

前端已删除只读验证横幅/按钮，写操作仍在具体点击时验证且不自动重放。链上哈希只显示首尾和日志号，复制动作写入完整定位键；详情按链上证据、资金路径、平台关联分组。授权回查遮蔽旧 DOM、关闭挂在 body 的对话框；返回菜单先核验 owner/管理会话，再恢复一页筛选、页码、滚动和已读详情，不自动重取链上列表。另一标签登录或退出会发不含令牌/身份资料的 BroadcastChannel 信号，旧标签立即清内存会话；未完成的 cookie refresh、旧 context 请求也被代次拒绝。退出按钮在服务端响应前同步清除钱包数据。真实 Chrome 合成 API 回归覆盖菜单往返、延迟授权、同账号换管理会话及延迟退出；另一个浏览器回归覆盖旧 context 晚到。

人工出款队列标明人工签名订单定位；旧底表明确为“托管提现申请记录”，其编号仅定位平台申请/审计，链上哈希定位实际转账。监控心跳、事故与资金启停分组；队列及事故列表各有独立北京时间读取时点，区内刷新也更新。链上缓存时点与观察器最近成功扫描分别标记。所有者申报仅填哈希、必选用途和所有权确认：唯一事件自动预检，多事件由链上已观察详情选择；预检展示精确六位金额及真实目的地址，再由管理员独立确认。结果未知先查原事务，不自动重放。合成视觉截图：[桌面](artifacts/2026-09-29/wallet-ui-acceptance/wallet-desktop-final.png)、[窄屏 500px](artifacts/2026-09-29/wallet-ui-acceptance/wallet-mobile-postpalette.png)、[监控与事故桌面](artifacts/2026-09-29/wallet-ui-acceptance/wallet-monitor-desktop.png)；资料均为合成，不能代替已授权生产会话验收。

| 门禁 | 最终候选实测 | 结论 |
| --- | --- | --- |
| 前端 `npm test` | 400 项：395 通过、5 失败、0 跳过，exit 1；[最终完整日志](artifacts/2026-09-29/wallet-ui-acceptance/frontend-npm-test-final.txt) | 五项失败与实施前 345/340/5 的全局样式令牌测试**同名**，新增钱包/会话测试无新增失败 |
| 真实浏览器与会话专项 | 新增菜单往返、退出同步遮蔽、旧 context 晚到；最终真实 Chrome 2/2，exit 0；[日志](artifacts/2026-09-29/wallet-ui-acceptance/browser-final.txt)。独立质量审查此前复跑钱包/会话/链上/人工钱包合计 140/140，exit 0；文案修补后对应链上 27/27、人工钱包 67/67 | 通过 |
| Owner 领域 + OpenAPI 合同 | `pytest` 27 passed，exit 0；`export_openapi.py --check` exit 0；单一 Alembic head 0092 | 通过 |
| 业务 API/Worker 全目录 | `py -3.12 -m pytest tests/business_api tests/business_worker -q`，3182 passed、79 skipped、1 条 Starlette/httpx 依赖弃用警告，2434.03 秒，exit 0；[日志](artifacts/2026-09-29/wallet-ui-acceptance/business-api-worker-pytest.txt)。最终提交 `ec34c51ddf92a084b0681be388b70505a89d4b91` 仅在该测试执行期间补了前端文案/时点及文档，没有改 Python 产品文件 | 通过；依赖警告不影响本次钱包域断言 |
| JS 解析与差异 | 八个改动/新增 JS `node --check` 通过；`git diff --check` exit 0；源码样式规则测试通过 | 通过 |
| `scripts/verify.ps1` | Repository/Deployment/Template 三段通过；Matrix RenderOnly 缺根 `.env`，exit 1；[原始日志](artifacts/2026-09-29/wallet-ui-acceptance/verify-full.txt) | 环境阻断，不能称全绿 |

只用公开 `.env.example` 临时生成合成配置、运行后清除的命令被自动审批以“blocked by policy”拒绝，**未创建或复制该文件**。其余不依赖此文件的门禁独立执行。独立质量/安全审查最终结论 PASS、无 P0–P2，复核了跨标签页、晚到响应、敏感 DOM、Grant/TOTP、幂等和窄屏。

## 生产只读冻结（2026-09-29 17:42–17:44 +08:00）

经已配置 jumper/严格主机密钥只读检查：API 运行镜像 `sha256:0bdf751c05015454781c24b66a0c5066ca08ce23436c232ff8aecd1ba5042993`、Worker `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`，二者 healthy、restart 0；API 容器 Alembic 为单一 `0092_admin_session_entry_mode`。gateway 的静态挂载源为 `/opt/starchat/frontend`。钱包新候选在此 17:44 +08:00 历史快照时尚未上传或切换；`admin.html`、`admin-home.js`、`admin-wallet.css`、`tokens.css` 当前 SHA256 依次为 `cd82dbf9813e9fe3b7805bbf5deed72fcd42c712629cdba143a3c5ef8c87923f`、`fd4e76b5f905bda79c531acd905cf867b64666c4355f73815ac392ad0963b0d9`、`9c34ef1f98cb0193838d5461759edb7341c8ad30d668d3d184085c827d0a301d`、`39bebda4b6b18452f79da5fc758bedc20a8b8bb453ff02ad489dfc88046e1853`。两项 API 源码当前 SHA 为 `a3de9a28...`、`760547c6...`，完整值见后续精确发布清单。角色化发布 guard SHA `78b2beb6...` 与 runbook 历史值相同，探针路径仍待清单复核。

只读现场逐文件目标与 v8 旧发布器适配差异见[发布预查](artifacts/2026-09-29/wallet-ui-acceptance/release-prep.md)。上述只是 17:44 +08:00 的**历史只读快照**；随后的发布流程已重新冻结 Compose、镜像、schema、静态 before SHA、双角色探针及隔离 PG/回退证据，结果见下文。未做真实资金申报、出款或生产账号登录。

## 候选身份（2026-09-29 18:09 +08:00）

本地功能与证据提交为 `ec34c51ddf92a084b0681be388b70505a89d4b91`，工作树当时干净。已由该提交的 2 API + 11 静态目标生成 after SHA，并在切换前重新核对生产 before SHA；随后的文档提交 `acc05171` 不改变产品字节。


## Task 10 冻结包与生产预切换门禁（2026-09-29 10:38–约 10:47 UTC）

[本地 21 文件发布清单](artifacts/2026-09-29/wallet-ui-acceptance/release-package-evidence.json)逐成员列出 SHA-256。冻结 archive `wallet-workspace-20260929-v1.tar.gz` SHA `0e63fe9d77d307c02fa42be71626d2061564d5f19c5bbee460efc61e09f64450`，manifest SHA `02d1b118045dbf8de84dbfae08a6fd9893a2af3accd9b1986a8a0ee3ad65229a`，清单 JSON 自身 SHA `6befe8899569808308ebc90a35b92e44e0d33220793f574c75c6e88a092a644e`。本地逐成员和 13 个源码 after SHA 独立复核、`release.py validate` 通过，独立安全复核 PASS，无 P0–P2。发布范围仅 2 个 API 文件与 11 个静态文件；Worker、迁移和 schema 不变。

生产压缩包上传至 `/opt/starchat/releases/wallet-workspace-20260929-v1.tar.gz` 后，远端 SHA 与冻结值相同；解包目录为同名 release ID，root 私有，manifest 远端 SHA 一致且 `release.py validate` 通过。`server_release.py preflight` 在现网 schema `0092_admin_session_entry_mode` 通过；`prepare` 留下 root/0700 私有备份，数据库备份 SHA `2d155401fc430b9809e86e1fa35219a72df97ccace765cc7c27904862acf9d06`，回退镜像 tar SHA `922f93d9c57ccf09909cb986af4200aa0e4df5e679ce277d6b8f1f33cd74ffc8`，并冻结 27 个其他容器身份。

`build` 生成候选 API 镜像 `sha256:83aedc06dd6763f819c4147736d0f422d238f4284b926429094d3e38eb8367f5`；回退 API 镜像为发布前 v8 `sha256:0bdf751c05015454781c24b66a0c5066ca08ce23436c232ff8aecd1ba5042993`；Worker 继续使用 `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`。候选/回退 API 分别通过 9/9 角色化刷新镜像门禁，Worker 通过 8/8。禁网 PostgreSQL 16.9 克隆恢复、候选/回退 0092 探针通过，候选钱包六例真实服务/SQL 断言通过：唯一预检解析非零索引、多事件要求选择、无事件拒绝、撤销 grant 拒绝、撤销 owner 拒绝、执行要求精确索引。`restore-finalize` 核对克隆及匿名卷均删除；**没有向生产财务表写入**。

## 受控切换与首次正式验收（2026-09-29 约 10:47–10:52 UTC）

`server_release.py deploy` exit 0：仅切换 API 至上述候选镜像并发布 11 静态，Worker 保持原镜像，schema 0092 不变；API/Worker healthy、重启计数 0。guarded Compose 快照 `/opt/starchat/releases/guarded-9c3emvpv/compose.json` SHA `98ce96d861fa207319f0cbeb46ac3909aa3b8f468d700272ce9fb9c90573691d`。`private/deployed.json` 已形成。受控切换只能执行一次，后续不重跑 `deploy`。

首次 `server_release.py verify` 在 `_same_runtime_configuration('api')` 提前停止，报 `ValueError: api runtime configuration changed`，**没有写出 `private/verified.json`**。只读诊断证实 Docker 前后 `Config.Env` 各有 89 个原始条目、键均唯一，其中各有一项不带 `=`；`sorted(raw_before) == sorted(raw_now)`，仅列表顺序不同。`Cmd`、`Entrypoint`、`WorkingDir`、`User` 及检查的 `HostConfig` 字段一致。故该次失败是校验器对环境变量顺序的误报；这不等同于正式验收成功，也不证明后续门禁已经运行。原脚本的回退入口亦调用相同严格比较，处理前不应尝试触发原版回退。

独立的 `public_verify.py` 在服务器和经 jumper 的工作站均通过严格 TLS：JSON ready，匿名 admin context、所有者转出 preview 和 execute 均返回 401，全部 11 项候选静态响应 SHA 与 manifest 相同。此为公开只读与未授权访问边界检查，**没有使用真实管理员登录会话**，也不能代替正式内部 verify。刷新监视 timer 为 active/waiting，约 10:52 UTC 的状态 `active=[]`、`pending=null`、`delivery_error=false`；早前 `PROTOCOL_PROBE_FAILED` 的 `sent_at` 仍在，不能把当前恢复或本次钱包发布当作历史邮件已成功投递的证据。

## 控制脚本顺序误报与修正（历史，2026-09-29 18:58 +08:00 时待办）

[窄范围 r3 修正说明与补丁](artifacts/2026-09-29/wallet-ui-acceptance/verification-env-order-r3.md)仅把 `Env` 当作键唯一的原始条目集合比较，仍要求值、增删项、无 `=` 条目及其他运行配置完全相同。原发布包脚本 SHA `561b17e14afe51ea57e61168734c38ea8867dca1c5e620def5112f21566131ff`；本地修正版 SHA `febd6177661f45eefda1464dd646ce382c468ec1e382a60458442219dedac153`；补丁 SHA `dcb05e620541012fb08ccde574f084588f49da1f831c347cd7a0ec5422f910c2`。原 archive、manifest、产品文件及镜像不为这项修正而改。补丁本地 red/green、28 项发布脚本测试通过、1 项可选 PG harness 跳过，Python 编译通过；该时点独立复核与生产受控落地尚待完成，最终结果见下节。

上述步骤现已执行，结果见下节；真实管理员会话的 WUI-1–7 交互验收仍待执行。


## r3 受控修正与正式生产验收（2026-09-29 11:00:46 UTC）

r3 控制脚本补丁经独立安全复核 **PASS，无 P0–P2**。生产落地前按 SHA 门禁确认旧脚本 `561b17e14afe51ea57e61168734c38ea8867dca1c5e620def5112f21566131ff`；备份至 root 私有 `private/server_release.py.pre-env-order-r3` 并回读同 SHA，再原子替换为修正版 `febd6177661f45eefda1464dd646ce382c468ec1e382a60458442219dedac153`。原 archive `0e63fe9d77d307c02fa42be71626d2061564d5f19c5bbee460efc61e09f64450` 与 manifest `02d1b118045dbf8de84dbfae08a6fd9893a2af3accd9b1986a8a0ee3ad65229a` 原字节不变；未重跑 `deploy`，未改产品文件、镜像、Compose、schema 或生产财务数据。

2026-09-29T11:00:46.122701Z，`python3 server_release.py verify` **exit 0**。私有 `private/verified.json` SHA-256 `49a523a8471d66e514f7415bd26925320a4d5b4f45a71f46012c98f8892363ce`。候选 API `sha256:83aedc06dd6763f819c4147736d0f422d238f4284b926429094d3e38eb8367f5` 与原 Worker `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf` 均 healthy、重启 0；schema 仍为 0092，11 静态与冻结 SHA 一致，其他 27 个容器身份不变，guarded Compose 快照 SHA `98ce96d861fa207319f0cbeb46ac3909aa3b8f468d700272ce9fb9c90573691d`。API/Worker 有界私有日志检查没有新 traceback、fatal 或 exit；原始日志保持在服务器私有目录。

切换后再次在服务器运行 `public_verify.py`，并通过 jumper 工作站 `--socks5-hostname` 运行，**两端均 exit 0**：严格 TLS JSON ready、匿名 admin context/所有者转出 preview/execute 均 401、11 项静态响应 SHA 与 manifest 一致。工作站隧道已关闭。这些结果确证生产技术发布门禁，不替代真实管理员会话对 WUI-1–7 的页面与交互验收；没有真实资金申报或出款操作。

刷新监视 timer 仍 active，状态 `active=[]`、`pending=null`、`delivery_error=false`，`sent_at.PROTOCOL_PROBE_FAILED=1790678886`。监视故障属于独立任务，当前无 active 告警或恢复通知均不能证明此前邮件送达。本地 `scripts/verify.ps1` 仍因工作树无 `.env` 阻断，五项同名旧前端全局样式断言仍失败；本次生产 verify 通过不改写这两项本地证据。

[生产验收去敏结果](artifacts/2026-09-29/wallet-ui-acceptance/verification-env-order-r3-production.json) SHA-256 `68e29f8817ecb0938478f4636be9bfccfbf5d78f1546f496f285448a9839c0a0`，同字节副本以 0600 存入服务器私有发布目录。原包与 manifest、控制脚本勘误、最终 `verified.json` 的身份由该结果串联。
