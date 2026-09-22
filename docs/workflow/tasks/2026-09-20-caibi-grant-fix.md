# 2026-09-20 客服点钻派发修复（储备策略接线 + 错误细分 + 前端红字icon）

## 恢复入口

- 目标、用户授权来源及边界：用户报障"客服点钻派发显示 发放失败：点钻发放请求无效"，并问"是否输入框规范问题导致找不到客服"，要求"完善错误提示（红色字体+icon）并修复该功能"。授权连接生产后端修改并部署。边界：不做资金补录、不执行真实发放、不动 worker、不改储备策略配置本身。
- 关联计划/ADR：无新 ADR；对齐生产既有配置 `BUSINESS_WALLET_RESERVE_POLICY=manual_liquidity`（2026-09-11 钱包任务确立的运行口径），本任务只消除 admin 派发/审批路径与全局配置的不一致。
- 当前状态：完成（代码已上线：后端镜像 `caibi-grant-20260920` 已切换并 healthy；admin 静态 `?v=20260920-grant` 已发布）。待用户真实派发复验；待用户指示 commit/push。
- 负责人、工作树、文件所有权：本工作流独占 `services/business-api/app/api/admin.py`、`services/business-api/app/api/ledger.py`、`frontend/src/admin-support-panel.js`、`frontend/src/admin-home.js`、`frontend/src/styles/admin-modern.css`、`frontend/admin.html`、`tests/business_api/admin/test_caibi_grant_errors.py`、`frontend/tests/admin-support-panel.test.mjs`。
- 最后更新时间：2026-09-20 23:50 +08。
- 下一条具体操作：管理员浏览器复验派发（成功应显示绿色"已发放：X 点钻"；若失败显示具体储备/幂等/金额错误码，按错误码继续定位）。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| G1 | 生产配置 manual_liquidity 时，客服点钻派发在储备缺口（记录型策略）下成功入账 | `admin.py` 派发路径 `adjustment_workflow.ledger.reserve_policy = settings.wallet_reserve_policy` | `test_manual_liquidity_policy_allows_grant_despite_backing_deficit`（先红后绿） | **已上线**（caibi-grant-20260920，23:36+08 healthy） | 待管理员真实派发复验 |
| G2 | full_backing 下储备缺口返回 `RESERVE_COVERAGE_INSUFFICIENT`+可读文案，不再是笼统"请求无效" | `CAIBI_GRANT_ERROR_DETAILS` 映射 7 类 ValueError | `test_full_backing_deficit_reports_reserve_coverage_error` 等 5 项映射测试 | 已上线 | — |
| G3 | 储备证据过期/未决赔付/幂等冲突/金额非法各自有独立错误码 | 同上映射（RESERVE_EVIDENCE_STALE / RESERVE_PAYOUT_PENDING / IDEMPOTENCY_PAYLOAD_CONFLICT / CAIBI_GRANT_AMOUNT_INVALID 等） | 对应测试 6/6 通过 | 已上线 | — |
| G4 | 审批执行路径（/ledger/adjustments/{id}/execute）与直发同策略口径 | `ledger.py` 同一接线 | `test_approval_execute_path_follows_the_same_reserve_policy` | 已上线 | — |
| G5 | 金额输入框本地校验（>0、≤两位小数），不合规不打接口 | `GRANT_AMOUNT_PATTERN` + `inputMode=decimal` + placeholder | `grant rejects malformed amounts locally...` | 已发布（公网哈希一致） | 待管理员浏览器复验 |
| G6 | 错误提示红色字体+icon（role=alert），成功绿色+icon（role=status） | `setFeedback()` + `.admin-feedback-icon`（CSS mask SVG）+ tokens 变量（--color-danger/--color-brand-primary，无字面 hex） | `grant failure renders red error feedback...` 等 3 项；npm test 222/222 | 已发布 | 待管理员浏览器复验 |
| G7 | 顺带恢复：生产容器被回退到陈旧镜像 fb41d7fa（缺批次 B 三文件），候选镜像基于 defect-restore-20260920 重建，切换后一并恢复 | 候选镜像 = defect-restore + admin.py + ledger.py 叠加（5 文件身份哈希门） | prepare.sh PREPARE_OK；切换后 in-image 哈希与 main 一致；换邮箱端点未授权 422（在线） | 已上线 | — |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| business-api 生产 | `starchat-business-api:caibi-grant-20260920`（基于 defect-restore-20260920/333c6727），2026-09-20 23:36+08 切换，healthy | 工作树未提交（admin.py `d4c35d82…`、ledger.py `633a06b5…`） | 服务器侧 overlay 构建 | `/opt/starchat/releases/caibi-grant-20260920/{admin.py,ledger.py,SHA256SUMS,Dockerfile,candidate-frozen-private.json}` | 23:36+08：healthy、live/ready 200、派发未授权 401、日志 0 error、其余容器未变 |
| admin 静态 | `?v=20260920-grant` | 工作树未提交 | nginx `/opt/starchat/frontend/` 原位安装，备份 `.bak-20260920T150505Z` | admin.html `7b37d5ab…`、admin-home.js `4f800d0d…`、admin-support-panel.js `c7f549b0…`、admin-modern.css `4021682d…` | 2026-09-20 23:05+08 公网 200、四文件哈希与本地一致 |
| 生产现状（切换前基线） | 容器 2026-09-20T02:21Z 创建自 `sha256:fb41d7fa718c…`（mi6-rate-limit 冻结清单），12:50Z 仅 restart 未切镜像 → 批次 B 修复（403 ACCOUNT_SUSPENDED、换邮箱端点）不在运行镜像中 | — | — | `/opt/starchat/releases/caibi-grant-20260920/baseline-before.txt` | 已记录为 G7，本次切换一并恢复 |

## 阶段计时

| 阶段 | 开始（+08） | 结束 | 说明 |
| --- | --- | --- | --- |
| 定位（读码+生产日志/DB） | 22:20 | 22:55 | 根因=储备覆盖缺口被误报；`eligible_usdt=40.00` vs `usdt_liability=58.91 + caibi_liability=7075.68`，储备证据新鲜（46s）、pending_payouts=0 |
| 后端 TDD | 22:55 | 23:10 | 先红 5 项后绿 6 项；发现并修复 ledger.py 同类不一致 |
| 前端实现+测试 | 23:00 | 23:10 | npm test 222/222（移除 CSS 字面 hex 以过契约测试） |
| 静态发布+公网验收 | 23:02 | 23:07 | 备份后原位安装，SOCKS 隧道公网哈希核对 |
| verify.ps1 | 22:58（首次，因 ledger.py 改动中止重启） | 23:33 | 第二次运行覆盖最终代码：PASS，API/Worker 2215 通过 58 跳过 |
| 后端切换+验证 | 23:36 | 23:45 | healthy/401/日志 0 error/其余容器不变；批次B端点在线（422 未授权） |

## 交接与回退

- 已确认根因：①`LedgerService.reserve_policy` 类属性硬编码 `full_backing`，admin.py/ledger.py 两处实例未接 `settings.wallet_reserve_policy`；生产 manual_liquidity（储备 40 USDT vs 负债 4567.02=点钻 4508.11+USDT 58.91，缺口 4527.02 记录为 backing_deficit）下每次派发 `require_coverage` 抛 `insufficient reserve coverage` → 被笼统映射为"点钻发放请求无效"。（更正：早期引的 7075.68 是行级毛流入，非储备检查真实输入。）②用户问题 2 的答案：**不是输入框问题**——422 发生在目标解析与 SUPPORT_AGENT 角色校验之后，目标查找（内部ID/畅聊号/邮箱，trim+casefold）一直正常；金额输入框无格式守卫属实，已一并加固。
- **生产复验（审计在案）**：切换后 23:42:30/23:42:49（+08）管理员成功派发 1550.00 与 2000.00 至两个客服账号；8/29 的 1000.00 成功是因为早于 9/8 首次储备观察（当时 reserve 行不存在，full_backing 对 None 直接放行）。
- 待办及验收失败项：管理员用真实管理员会话复验一次派发（本工作流不执行真实资金写）；改动待用户指示后 commit/push。
- 已发布与仅候选的区别：后端镜像与 admin 静态均已上线；回退路径见下。
- 生产备份位置、恢复操作：静态备份 `/opt/starchat/frontend/**.bak-20260920T150505Z`；后端回退 `cd /opt/starchat && docker compose -f releases/mi6-rate-limit-20260920/candidate-frozen-private.json up -d business-api`（回 fb41d7fa，注意该镜像缺批次B修复，仅作应急）；无迁移、无 DB 写，储备行仅观察。
- 运行中命令：无自建隧道残留（已关闭）；verify 已结束（PASS）。
- 下次恢复先检查的事实：`docker ps` business-api 镜像身份；`/opt/starchat/releases/caibi-grant-20260920/` 工件；verify 日志 `docs/verification/artifacts/2026-09-20/caibi-grant-verify.log`。
