# USDT 钱包工作台实施验证记录

## 身份与授权

- 用户于本轮明确答复“批准你开始执行”，批准[钱包 ADR](../adr/2026-09-29-wallet-workspace-visibility-and-owner-transfer.md)和[逐项计划](../superpowers/plans/2026-09-29-wallet-workspace-polish.md)的本地实施；生产发布仍须用完成的候选及实时现场证据按[后台工作流](../runbooks/admin-production-workflow.md)核对。
- 工作树：`C:/Users/Administrator/.codex/worktrees/wallet-ui-polish/StarChat`，分支 `codex/wallet-ui-polish-20260929`；开始基线 commit `e3535ca9a41167f98daa217f7acf135e329cb3d0`，`git status --short` 为空。产品代码尚无本任务改动。
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
| 完整门禁与发布 | 前端全量 400/395/5（五项已知基线）；OpenAPI 与领域专项通过；业务 API/Worker 全目录 3182 通过、79 跳过、exit 0；完整 verify 因缺 `.env` 停在 render-only 配置；生产尚未发布 | 完成隔离发布门禁 |

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

经已配置 jumper/严格主机密钥只读检查：API 运行镜像 `sha256:0bdf751c05015454781c24b66a0c5066ca08ce23436c232ff8aecd1ba5042993`、Worker `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`，二者 healthy、restart 0；API 容器 Alembic 为单一 `0092_admin_session_entry_mode`。gateway 的静态挂载源为 `/opt/starchat/frontend`。钱包新候选尚未上传或切换；`admin.html`、`admin-home.js`、`admin-wallet.css`、`tokens.css` 当前 SHA256 依次为 `cd82dbf9813e9fe3b7805bbf5deed72fcd42c712629cdba143a3c5ef8c87923f`、`fd4e76b5f905bda79c531acd905cf867b64666c4355f73815ac392ad0963b0d9`、`9c34ef1f98cb0193838d5461759edb7341c8ad30d668d3d184085c827d0a301d`、`39bebda4b6b18452f79da5fc758bedc20a8b8bb453ff02ad489dfc88046e1853`。两项 API 源码当前 SHA 为 `a3de9a28...`、`760547c6...`，完整值见后续精确发布清单。角色化发布 guard SHA `78b2beb6...` 与 runbook 历史值相同，探针路径仍待清单复核。

只读现场逐文件目标与 v8 旧发布器适配差异见[发布预查](artifacts/2026-09-29/wallet-ui-acceptance/release-prep.md)。上述只是 17:44 的只读现场，正式切换前必须重新冻结所有实际 Compose、镜像、schema、静态 before SHA、双角色探针及隔离 PG/回退证据。未做真实资金申报、出款或生产账号登录。

## 候选身份（2026-09-29 18:09 +08:00）

本地功能与证据提交为 `ec34c51ddf92a084b0681be388b70505a89d4b91`，工作树当时干净。发布包须使用此提交的受控 API/静态目标生成 after SHA，且在切换前重新核对生产 before SHA；本提交不表示生产已发布。
