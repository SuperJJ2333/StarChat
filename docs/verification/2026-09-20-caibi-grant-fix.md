# 2026-09-20 客服点钻派发修复验证（储备策略接线 + 错误细分 + 前端红字icon）

## 结论

**已上线**。客服点钻派发的"发放失败：点钻发放请求无效"根因已修复并部署生产（2026-09-20 23:36 UTC / 2026-09-20 23:36+08 切换，容器 healthy）。管理员现在重新派发应当成功；若再次失败，将看到具体原因（储备覆盖不足/证据过期/未决赔付/幂等冲突/金额格式），不再是笼统"请求无效"。

用户问题 2 的结论：**不是输入框规范问题**。422 响应发生在目标解析（内部ID/畅聊号/邮箱，trim+casefold）与 SUPPORT_AGENT 角色校验之后；真实失败点是账本入账时的 `ValueError('insufficient reserve coverage')`。金额输入框原先无格式守卫属实，本次一并加固（本地拦截，不打接口）。

## 根因

1. **策略不一致（主因）**：生产以 `BUSINESS_WALLET_RESERVE_POLICY=manual_liquidity` 运行（储备缺口按记录型策略放行、保留待决赔付与 120s 证据时效守卫）。但 `LedgerService.reserve_policy` 类属性硬编码 `full_backing`，`admin.py`（直发）与 `ledger.py`（审批执行）两处实例未接 `settings.wallet_reserve_policy`。生产储备实况（监控每次观察都记录在 `ledger_manual_reserve_evaluations`）：`eligible_usdt=40.00`（tron-watch 对官方托管钱包链上实测）、`usdt_liability=58.91`（2 笔待付提现 hold 20+30、用户兑换所得 8.91）、`caibi_liability=4508.11`（按账户净余额合计，含红包/转账在途托管），缺口 `backing_deficit=4527.02` 每次观察留痕。每次派发 `require_coverage` 以 full_backing 口径抛 `insufficient reserve coverage`，被端点笼统映射为 422 `CAIBI_GRANT_INVALID`"点钻发放请求无效"。
   - 更正：本任务早期报告曾引"负债 7134.59"，那是行级毛流入（`SUM(GREATEST(amount,0))` 未按账户合并，重复计入同一账户的历史进出）；储备检查真实输入是按账户净余额合计（现值 4508.11），结论不变。
2. **文案过度笼统**：`except ValueError` 未区分错误种类，系统状态问题（储备/幂等）被误报为"请求无效"。

## 债务流水来源（2026-09-20 生产审计）

- 点钻侧净发行来源（对应 `PLATFORM_CLEARING=-4523.09`）：客服派发 4550（2026-08-29 一笔 1000——早于 9/8 首次储备观察、当时储备行不存在故 full_backing 直接放行；9/20 修复后 23:42 两笔 1550+2000）、USDT→点钻 1:1 兑换 232、手工赔付取消 60。聊天转账/红包领取/过期退回属用户间移动，不改变净负债。
- USDT 侧 `usdt_liability=58.91`：待付提现 hold 20+30、用户兑换所得余额 8.91；托管钱包链上实测仅 40 USDT（期间的 USDT 经提现/兑换流出）。

## 代码改动（未提交，工作树）

| 文件 | 改动 |
| --- | --- |
| `services/business-api/app/api/admin.py` | ①派发路径 `adjustment_workflow.ledger.reserve_policy = settings.wallet_reserve_policy`；②`CAIBI_GRANT_ERROR_DETAILS` 把 7 类 ValueError 映射为独立错误码/中文文案，兜底保留 `CAIBI_GRANT_INVALID` |
| `services/business-api/app/api/ledger.py` | 审批执行路径同一策略接线 |
| `frontend/src/admin-support-panel.js` | 金额本地校验（`^\d{1,12}(\.\d{1,2})?$` 且 >0，`inputMode=decimal`，placeholder）；`setFeedback()`：错误 `is-error` 红字+icon+`role=alert`，成功 `is-success` 绿字+icon+`role=status`（客服管理表单一并统一） |
| `frontend/src/styles/admin-modern.css` | `.admin-support-feedback` icon 样式（CSS mask SVG，颜色用 `--color-danger`/`--color-brand-primary` token，无字面 hex） |
| `frontend/admin.html`、`frontend/src/admin-home.js` | 资源版本 `?v=20260920-grant` |
| `tests/business_api/admin/test_caibi_grant_errors.py`（新增） | 6 项：manual_liquidity 缺口下派发成功、full_backing 缺口返回 `RESERVE_COVERAGE_INSUFFICIENT`、证据过期、未决赔付、幂等冲突、审批执行同策略 |
| `frontend/tests/admin-support-panel.test.mjs` | +4 项：金额本地拦截、失败红字+icon+alert、成功绿字+icon+status、管理表单错误样式 |

## 门禁

| 门禁 | 结果 |
| --- | --- |
| 新增后端测试（先红后绿） | 首轮 5 failed（策略未接线/笼统文案），实现后 **6 passed**；admin 定向回归 24 passed |
| `pwsh -NoProfile -File scripts/verify.ps1`（最终代码，完整运行） | **`Verification: PASS`**（退出码 0）；Business API/Worker **2215 passed / 58 skipped**（23:10）；Alembic/OpenAPI/Compose render PASS；日志 `docs/verification/artifacts/2026-09-20/caibi-grant-verify.log` |
| `npm test`（frontend 全量） | **222 passed / 0 failed**（含 admin-modern.css 禁字面 hex 契约——已移除 fallback hex） |

## 生产部署证据（2026-09-20）

- **镜像**：`starchat-business-api:caibi-grant-20260920` = `defect-restore-20260920`(333c6727) + `admin.py`(`d4c35d82…`) + `ledger.py`(`633a06b5…`) 叠加；构建前哈希门 `SHA256SUMS` 通过；in-image 内容身份核对：admin/ledger 为新版本，`identity.py=336da69e…`、`config.py=91b3f28b…`、`registration.py=a263c791…` 与 main 一致。
- **顺带恢复批次B**：切换前容器（2026-09-20T02:21Z 创建自 `sha256:fb41d7fa…`，12:50Z 仅 restart 未切镜像）缺失 defect-restore 的 3 个批次B文件（403 ACCOUNT_SUSPENDED、换邮箱端点）。本次切换一并恢复；换邮箱端点 `POST /auth/registrations/{id}/email` 未授权返回 422（路由在线），403 语义由 defect-restore 任务的原验证背书。
- **切换**：`docker compose -f releases/caibi-grant-20260920/candidate-frozen-private.json up -d business-api`；脚本与输出：`/opt/starchat/releases/caibi-grant-20260920/{prepare.sh,switch.sh,baseline-*.txt}`。
- **切换后核验**：healthy；env 63 键/3 mounts/1 port；`/health/live`、`/health/ready` 200；派发未授权 401；日志 0 error/0 traceback；**其余全部容器未变**（baseline diff 仅 business-api 一行）；储备监控持续刷新（切换后 observed_at 年龄 34s，version 29655→29761）。
- **回退**：`cd /opt/starchat && docker compose -f releases/mi6-rate-limit-20260920/candidate-frozen-private.json up -d business-api`。无迁移、无 DB 写。

## admin 静态发布证据（先行于后端切换）

- 备份：`/opt/starchat/frontend/**.bak-20260920T150505Z`；安装 4 文件后哈希与本地一致：admin.html `7b37d5ab…`、admin-home.js `4f800d0d…`、admin-support-panel.js `c7f549b0…`、admin-modern.css `4021682d…`。
- 公网（jumper SOCKS 隧道，HTTPS 证书校验保留）：`https://admin.liuhetong888.com/admin.html` 200 且引用 `admin-modern.css?v=20260920-grant`；`/src/admin-home.js?v=20260920-grant` 引用 `admin-support-panel.js?v=20260920-grant`；四个公网文件 SHA256 与本地逐字节一致。抓取件存 `docs/verification/artifacts/2026-09-20/caibi-grant/public-*`。

## 缺口与后续

- **生产复验已完成（审计在案）**：切换后 23:42:30/23:42:49（+08）管理员（actor `57743ca0…`）成功派发 1550.00 与 2000.00 点钻至两个客服账号，`admin.caibi.granted` 审计与清算账户 -973.09→-4523.09 变动一致。
- 储备缺口 40 vs 4567.02（缺口 4527.02，监控每次观察记录 backing_deficit）是既有财务事实：manual_liquidity 只记录不阻断。是否补充托管储备、或将某类发行收紧回 full_backing，属产品/财务决策，需用户另行立项。
- `ledger.py` 审批执行端点对"申请不存在/状态非法"的 ValueError 未映射为 409（500），属既有行为，与本任务无关，建议另开小任务。
- 改动尚未 commit/push，待用户指示（工作树另有其他任务的未提交改动，提交时需按文件拆分）。
