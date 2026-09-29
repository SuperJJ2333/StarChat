# USDT 钱包工作台与所有者转出申报 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

状态：待受保护 ADR 与本计划的用户批准；当前仅完成设计和计划，未实施产品源码。

**Goal:** 完成钱包管理页视觉改造、链上流水只读现场保留及完整值复制，并把所有者转出申报改为用途单选、自动或人工选择链上事件、预检后显式确认。

**Architecture:** 继续使用原生 JavaScript 管理台、现有钱包只读 API 与服务端钱包 grant。链上视图只在当前管理台壳实例中保存一页内存快照；菜单返回先重新核验管理会话及钱包 owner，再显示快照。所有者转出的预检可省略日志索引以解析唯一的官方转出，执行请求仍携带精确索引，并继续由原事务完成证据、账本、幂等和审计校验。

**Tech Stack:** 原生 JavaScript/CSS、Node test runner、FastAPI/Pydantic、SQLAlchemy、pytest、OpenAPI、PowerShell 7。

---

## 授权、基线与文件所有权

- 书面规格：`docs/superpowers/specs/2026-09-29-wallet-workspace-polish-design.md`，用户已批准并补充“去日志序号、原因与用途合一”。受保护 ADR：`docs/adr/2026-09-29-wallet-workspace-visibility-and-owner-transfer.md`。**ADR 与本计划均获批准之后才开始下列代码步骤**；保留 ADR-0071 的执行精确定位与所有原有资金门槛。
- 工作树 `C:\Users\Administrator\.codex\worktrees\wallet-ui-polish\StarChat`，分支 `codex/wallet-ui-polish-20260929`，从已集成 v8 管理台发布基线 `e014619e` 分出。执行前记录 `git rev-parse HEAD`、`git status --short`、生产现行 API/Worker 镜像、schema、管理台静态 SHA；不能把此历史记录当作实时生产事实。2026-09-29 在未改产品源码的本分支上实跑 `frontend/npm test`：345 项，340 通过、5 失败，退出码 1；失败项依次是 `shared gradient divider token keeps the lower alpha and fading ends`、`divider and brand tint tokens match the Flutter token layer`、`announcement color, Moments warning and wallet copy match the requested presentation`、`light and dark themes expose the same semantic color keys`、`support identity yellow matches Flutter`。这仅证明本工作树改动前的基线，最终候选必须再次分类新增失败和发布门禁，不能静默豁免。
- 每个 PowerShell 7 会话先设置无 BOM UTF-8 控制台输入/输出及 `$OutputEncoding`，并设 `PYTHONUTF8=1`、`PYTHONIOENCODING=utf-8`。Python 业务测试设 `$env:PYTHONPATH='services/business-api;services/business-worker/app;.'`。先读根 `AGENTS.md`、管理台/移动工作流、`docs/workflow/current-state.md`、本规格、ADR-0071、`docs/adr/0064-wallet-access-grant.md`、`docs/adr/2026-09-28-admin-entry-merge.md` 和现有任务记录。`.codegraph/` 存在时先用 CodeGraph；当前独立树没有索引。
- 前端生命周期组独占 `frontend/src/admin-wallet-access.js`、`admin-dashboard.js`、`admin-session.js`、`admin-home.js` 和对应测试；链上组独占 `admin-chain-panel.js`、新 `admin-chain-view-state.js` 与对应测试；人工钱包组独占 `admin-manual-wallet-panel.js`、`manual-wallet-panel.test.mjs`；领域组独占 `services/business-api/app/api/admin_wallet_owner_transfers.py`、`app/modules/wallet/owner_transfers.py`、`tests/business_api/wallet/test_owner_transfer_declaration.py`、新增 API 路由测试。Task 4 先由链上/人工钱包各自所有者在其文件加弹窗暂挂/恢复接口，再由生命周期组串行接入 `admin-home.js` 与 `admin-wallet-access.js` 并跑联合红绿测试。`admin-home.js` 的后续链上/人工钱包接线同样等接口定稿后串行完成。CSS/文档/OpenAPI 由集成组串行拥有；代理不得并发修改同一文件。
- 不编辑观察器、人工出款状态机、账本公式/表、迁移或刷新监视器。本用户提出的 `PROTOCOL_PROBE_FAILED` 诊断与修复方案另立认证可用性任务；本计划仅处理钱包管理台及 owner-transfer 预检兼容输入。

## 文件职责图

| 文件 | 本次职责 |
| --- | --- |
| `frontend/src/admin-wallet-access.js` | 保留已授权只读 DOM、回查遮蔽与失权清除；移除顶部验证横幅。 |
| `frontend/src/admin-session.js`、`admin-dashboard.js` | 当前管理会话代次及菜单切换时的有界钱包快照生命周期。 |
| `frontend/src/admin-home.js` | 钱包区结构、快照输入输出、旧托管提现记录名称、链上与申报候选回调。 |
| `frontend/src/admin-chain-view-state.js` | 纯函数校验一页快照、缩略哈希、USDT 六位精度字符串格式。 |
| `frontend/src/admin-chain-panel.js` | 链上列表、复制、详情、候选选择以及读快照导入/导出。 |
| `frontend/src/admin-manual-wallet-panel.js` | 出款/监控视觉分组、用途菜单、预检与执行确认。 |
| `services/business-api/app/api/admin_wallet_owner_transfers.py` | 独立、可省略 `log_index` 的预检请求模型；执行模型保持精确必填。 |
| `services/business-api/app/modules/wallet/owner_transfers.py` | 授权后用新鲜链证据解析唯一官方转出；显式索引及执行校验保留。 |
| `frontend/src/styles/admin-wallet.css`、`frontend/src/styles/admin-modern.css` | 钱包工作台、链上详情及响应式样式；核对实际加载顺序和覆盖。 |
| `packages/api-contracts/openapi/liuhetong-v1.yaml`、`docs/runbooks/wallet-incident-recovery.md` | 兼容契约与管理员申报流程。 |

## Task 1：基线、红灯与任务证据

**Files:** Update `docs/workflow/tasks/2026-09-29-wallet-workspace-polish.md`; Create `docs/verification/2026-09-29-wallet-workspace-polish.md`.

- [ ] **Step 1:** 按 `docs/workflow/task-template.md` 更新本任务已有台账，逐行写 WUI-1 至 WUI-7、源码 SHA、批准范围、现状、对应专项测试、生产证据与下一步；把 `PROTOCOL_PROBE_FAILED` 标为独立任务，不写成已修复。
- [ ] **Step 2:** 记录 `git status --short`、`git rev-parse HEAD`，检查 `node --version`、`py -3.12 --version`、`docker version`、`Test-Path -LiteralPath '.env'`、可用磁盘、`scripts/verify.ps1`、唯一 Alembic head 和当前 OpenAPI `--check`。把上述已实跑的 345/340/5 前端基线和五个测试名放入任务证据，注明当时仅文档改动、产品源码来自 `e014619e`；测试环境缺少 `.env` 时记录为门禁阻断，不复制生产配置。
- [ ] **Step 3:** 运行改动前专项基线：

```powershell
Push-Location -LiteralPath frontend
try { node --test tests/admin-wallet-access.test.mjs tests/admin-chain-panel.test.mjs tests/manual-wallet-panel.test.mjs tests/admin-dashboard.test.mjs tests/admin-manual-wallet-api.test.mjs }
finally { Pop-Location }
$env:PYTHONPATH='services/business-api;services/business-worker/app;.'
py -3.12 -m pytest tests/business_api/wallet/test_owner_transfer_declaration.py tests/business_api/wallet/test_manual_wallet_api.py tests/business_api/test_admin_repairs_full_app.py -q
```

  Expected: capture exact pass/fail counts and exit codes; do not call a pre-existing CSS failure a new regression. Record start/end wall time and commit SHA in verification report. Do not run the full gate yet.
- [ ] **Step 4:** Commit only new task/evidence files with `git add docs/workflow/tasks/2026-09-29-wallet-workspace-polish.md docs/verification/2026-09-29-wallet-workspace-polish.md` and `git commit -m "docs(wallet): record workspace baseline"`.

## Task 2：预检可自动解析唯一链上转出，执行仍要求精确索引

**Files:** Modify `services/business-api/app/api/admin_wallet_owner_transfers.py`; Modify `services/business-api/app/modules/wallet/owner_transfers.py`; Test `tests/business_api/wallet/test_owner_transfer_declaration.py`; Create `tests/business_api/wallet/test_owner_transfer_preview_api.py`.

- [ ] **Step 1: Red.** 在领域测试中让 `owner_outflow(..., log_index=7)` 与 `owner_adapter(..., log_index=7)` 接受非零索引，断言 `preview(service, log_index=None)` 解析 7，返回原始 `amount_units`、`to_address`，且预检后 owner-transfer 表及账本行数不变；证明不是“默认 0”。用两笔官方 USDT Transfer（索引 7/8）断言无索引预检抛 `AppError(code='TRANSFER_SELECTION_REQUIRED',status_code=409)`、不会挑第一笔；用零笔官方转出断言 `AppError(code='TRANSFER_NOT_FOUND',status_code=409)`；显式 8 只能取得第 8 笔，显式错误索引继续返回既有 blocker。
- [ ] **Step 2: Red.** 新路由测试在有效 owner/grant 下以省略 `log_index` 的 JSON 调 preview 应到达领域服务，原带索引 JSON 仍可用；零/多笔分别响应 409 + `TRANSFER_NOT_FOUND`/`TRANSFER_SELECTION_REQUIRED`，不能成为 Pydantic 422 或 200 的猜测结果。执行 JSON 缺索引必须 422 且不得调用领域服务。非 owner、缺 grant 的预检必须在调用 `adapter.transaction_evidence` 前 401/403；模拟授权在预算锁后失效，链证据不读。OpenAPI 的 preview schema `log_index` 非 required，execute schema 仍 required，409 描述这两个稳定错误码。
- [ ] **Step 3:** 运行 `py -3.12 -m pytest tests/business_api/wallet/test_owner_transfer_declaration.py tests/business_api/wallet/test_owner_transfer_preview_api.py -q`，保存缺失的非零自动解析、请求验证失败等红灯及退出码；避免让测试因错误导入而红。
- [ ] **Step 4: Green.** 为 preview 增独立请求类型，执行保留 `OwnerTransferBody`。省略字段是唯一请求形状兼容扩展；明确的 409 错误码是这个扩展的失败响应，而不是执行协议变更：

```python
from app.core.errors import ErrorEnvelope

class OwnerTransferPreviewBody(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    txid: str = Field(pattern=r'^[a-f0-9]{64}$')
    log_index: int | None = Field(default=None, ge=0)
    reason_code: str = Field(pattern=REASON_PATTERN)
    reason_detail: str = Field(min_length=1, max_length=500)
    ownership_attested: bool

@router.post('/preview', responses={409: {'model': ErrorEnvelope, 'description':
    'TRANSFER_NOT_FOUND: no official outflow; TRANSFER_SELECTION_REQUIRED: multiple official outflows'}})
def preview(body: OwnerTransferPreviewBody, claims=Depends(actor)):
    return response(service.preview(**write_context(claims), **body.model_dump()))
```

  `OwnerTransferService.preview()` 允许 `None`；`execute()` 继续拒绝它。`_validate(..., allow_missing_index=False)` 在 `log_index is None and allow_missing_index` 时才跳过索引校验；调用方仅 preview 传 `allow_missing_index=True`，`bool`、负数等继续拒绝。`_snapshot()` 维持可信时钟、`lock_budget(session)`、`_authorize()` 的现有顺序，在两者通过后只调用一次 `_proof(txid)`：

```python
official = [item for item in proof.transfers
            if item.from_address == self.official_config.address]
if log_index is None:
    if not official:
        fail('TRANSFER_NOT_FOUND', 409)
    if len(official) != 1:
        fail('TRANSFER_SELECTION_REQUIRED', 409)
    log_index = official[0].log_index
```

  接着用解析出的索引走原 `_snapshot` 的 VERIFIED 覆盖事实、金额/收款地址一致、未被出款占用、未申报检查；不得放宽显式索引、执行重验或持久化规则。预检响应只在唯一/显式选择成功时包含内部索引，零/多笔时不泄漏猜测的收款地址。
- [ ] **Step 5:** 复跑 Step 3 及 `tests/business_api/wallet/test_manual_wallet_admin_api.py`，预期全绿；再跑 `py -3.12 scripts/export_openapi.py --check`，预期先报告契约漂移（Task 8 导出后绿）。提交领域代码和专项测试：`git commit -m "feat(wallet): resolve unique owner transfer in preview"`。

## Task 3：链上哈希缩略、完整复制及语义化详情

**Files:** Create `frontend/src/admin-chain-view-state.js`; Modify `frontend/src/admin-chain-panel.js`; Test `frontend/tests/admin-chain-panel.test.mjs`; Create `frontend/tests/admin-chain-view-state.test.mjs`.

- [ ] **Step 1: Red.** 添加测试：64 位哈希列表和详情都显示首 8/尾 6 与 `#7`，不含中间 50 位；点击“复制完整哈希 / 日志”写入完整 `${txid} / 7`，成功/拒绝均更新 `role=status`，拒绝不说“复制成功”；详情仍展示链上证据、资金路径、平台关联三组，`REVIEW`/`CONFLICT` 不显示为已结算。无 DEPOSIT/PAYOUT 关联的出流标为“未关联出款订单”，不暗示所有者转出未申报；申报状态只能查独立申报/事故记录。详情关闭后表格、过滤条件、页码与滚动不变。金额以 API 字符串显示，复制按钮 `type=button`。
- [ ] **Step 2:** 运行 `node --test frontend/tests/admin-chain-view-state.test.mjs frontend/tests/admin-chain-panel.test.mjs`，确认缺缩略/复制/分组行为红灯。
- [ ] **Step 3: Green.** 纯函数模块导出：

```js
export const shortHash = txid => /^[a-f0-9]{64}$/i.test(txid)
  ? `${txid.slice(0,8)}…${txid.slice(-6)}` : '哈希不可用';
export const transferKey = item => `${item.txid} / ${item.log_index}`;
export const formatUsdtUnits = units => {
  const raw=String(units);
  if(!/^\d+$/.test(raw))return '—';
  const padded=raw.padStart(7,'0');
  return `${padded.slice(0,-6)}.${padded.slice(-6)}`;
};
```

  列表创建独立缩略哈希节点、完整日志索引文本、复制按钮；完整值仅传给 `clipboard.writeText(transferKey(item))`，不可放在 `title`、可见错误、分析日志。详情继续用现有 `detailDialog`，三个 `<section aria-label=...>` 各有 `<dl>`，真实字段缺失用“暂无”或“尚无可验证关联”；每个长链上值有明确复制动作。`getChainTransaction(txid,log_index)` 继续按原参数读取，异步版本号仍阻止旧响应覆盖新选择。
- [ ] **Step 4:** 复跑两组测试，`node --check frontend/src/admin-chain-panel.js`，提交 `feat(admin): add concise chain locator and evidence detail`。

## Task 4：焦点回查保留只读页面并取消顶部验证横幅

**Files:** Modify `frontend/src/admin-wallet-access.js`, `frontend/src/admin-home.js`, `frontend/src/admin-chain-panel.js`, `frontend/src/admin-manual-wallet-panel.js`; Test `frontend/tests/admin-wallet-access.test.mjs`, `frontend/tests/admin-chain-panel.test.mjs`, `frontend/tests/manual-wallet-panel.test.mjs`; Modify `frontend/src/styles/admin-wallet.css`（仅回查遮蔽样式，Task 7 再做视觉细节）。按上方所有权先形成子面板接口，再由生命周期组串行接线。

- [ ] **Step 1: Red.** 将现有“grant 到期重建”测试改为断言同一 `article` 节点、`renderContent` 仅一次、`dispose` 零次、读仍可用、写仍不可用；加初次无授权可读时没有顶部提示及按钮的断言。模拟 `focus` 与 `visibilitychange` 同时发生，只发一个 `getWalletAccess` 回查；回查未完成期间敏感内容不可见/不可交互、写请求拒绝，成功后同一 DOM 和筛选值恢复，无钱包数据二次 GET。专门打开挂在 `document.body` 的链上详情、事故详情、修复及嵌套补录弹窗，断言主动回查开始立即全部关闭，链上已读详情只在 owner 核验成功后恢复，写弹窗不恢复；详情加载中的旧响应不能越过回查重开。401、owner 变化、403、网络未知立即清 DOM/旧快照；旧请求结束不能回填。现有 30 秒可见页背景轮询成功时不得定时遮蔽或关闭详情，在途禁写，返回撤权/网络未知时立即清除。
- [ ] **Step 2:** 运行 `node --test frontend/tests/admin-wallet-access.test.mjs frontend/tests/admin-chain-panel.test.mjs frontend/tests/manual-wallet-panel.test.mjs`，确认原测试所证明的销毁路径现在红灯，且新增脱离 DOM 弹窗安全测试因未遮蔽红灯。
- [ ] **Step 3: Green.** 删除 `writeNotice` 创建/追加及 `show()` 中的横幅分支；具体写操作继续调用现有 `accessController.requestWriteGrant()`，成功后必须由用户再次触发。`show()` 对已创建子面板的 `unknown` 主动回查，先调用 `child.suspendForAccessCheck()`：链上面板须在关闭详情前暂存已读详情数据（现有 `onClose` 会清选择），关闭挂在 `document.body` 的链上/事故只读详情、修复及嵌套补录/确认写弹窗，清写草稿；然后设置 `content.inert=true` 和 `visibility:hidden`，保持链上列表节点与位置。owner 核验成功后仅调用 `child.resumeReadDetail()` 用已有数据重开链上只读详情，不自动重开事故或任何写弹窗；详情读取未完成就保持关闭、给手动重试。`verify`、`setup` 不因 `ready -> verify` 清子面板；只在 legacy 模式切换时因凭据字段结构不同而重建。`login`、`forbidden`、`network` 与身份变化继续 `clearContent()` 并关闭模态。焦点/可见、BroadcastChannel、storage 和显式钱包回查用去重的主动 `recheck()`，开始前 `gate.lock()` 使读写立即失效，结果确认后去遮蔽或销毁。持续可见页的 30 秒背景轮询调用无预遮蔽的状态检查，期间 `canWrite()` 返回 false 但只读 DOM 与已开详情保持；结果失权或未知时同样清除内容。两类回查共享 generation/epoch 防止迟到成功在撤权后回填。CSS 对遮蔽元素保留占位，禁止鼠标/键盘交互并给非敏感状态 `role=status`。
- [ ] **Step 4:** 复跑三个相关专项及 `node --check` 所有四个改动 JS，检查当前 `admin-wallet-access.test.mjs` 的撤权、认证、TOTP、密码流程无回归；提交 `fix(admin): preserve wallet reads during access recheck`。

## Task 5：菜单切换只在当前会话保留一页链上现场

**Files:** Modify `frontend/src/admin-session.js`, `frontend/src/admin-dashboard.js`, `frontend/src/admin-home.js`, `frontend/src/admin-chain-panel.js`; Test `frontend/tests/admin-session.test.mjs`, `frontend/tests/admin-dashboard.test.mjs`, `frontend/tests/admin-chain-panel.test.mjs`; Create `frontend/tests/admin-wallet-return.test.mjs`.

- [ ] **Step 1: Red.** 用真实 `createAdminShell` + 测试 DOM 走 钱包→其他菜单→钱包：链上筛选草稿及已应用筛选分别保留、offset=25、snapshot、25 条上限、页面/表格横滚、已打开详情和已读取详情数据保留；菜单返回 `getWalletAccess` 先成功，然后恢复快照，核验之前 `document.body` 也无旧详情闪现，`getChainTransactions`/`getChainSummary`/`getChainTransaction` 均没有自动请求。显式刷新才读取新链上数据；返回后显示“本页缓存于”且仍单列“观察器最近成功扫描”。退出/换管理会话/owner 撤权/401/403/网络未知均无旧数据，旧异步响应不可回填；修复/资金弹窗与未提交写草稿不恢复；既有 `operationJournal` pending 元数据和幂等键仍可按原状态读回，绝不自动重放写命令。
- [ ] **Step 2:** 运行 `node --test frontend/tests/admin-wallet-return.test.mjs frontend/tests/admin-chain-panel.test.mjs frontend/tests/admin-session.test.mjs frontend/tests/admin-dashboard.test.mjs`，确认原菜单销毁/自动链上 GET 导致红灯。
- [ ] **Step 3: Green.** `adminSession` 仅暴露不含 token/会话 ID 的内存 `cacheEpoch()`：当 `identity!==null && access!==null && !blocked` 返回 `generation`，否则 `null`；`clear()` 与登录/会话切换增加 generation，token 同身份续期不变。`admin-home.js` 的 `adminView()` 用 `getWalletCacheEpoch:()=>adminSession.cacheEpoch()` 传给 `createAdminShell`；后者只持有 `walletViewSnapshot`、`actorId`、`cacheEpoch` 三值。切走钱包前调用 `walletAccessPanel.exportReadView()`，由它在 `gate.readAllowed()` 时转调 `walletContent.exportReadView()`，再 `dispose()`，因为现有 `detailDialog.onClose` 会清选择。`page.dispose()`、退出和身份代次变化清该变量；`loadCurrent()` 只在 actor/epoch 匹配时把 `walletReadView` 放进 `renderModule()` 的 context。`admin-home.js` 再传给 `walletAccessPanel`，它完成 `getWalletAccess` 并检查 `gate.readAllowed()` 后才调用 `renderContent`，`walletContent` 最后才把快照交给 `chainPanel`。注意 `gate.check()` 的布尔返回值表示**写 grant**，`verify` 状态的合格只读 owner 会返回 `false`；不得因此错误丢弃只读快照。`walletAccessPanel` 在 `login`/`forbidden`/`network` 状态调用 context 提供的 `onWalletReadDenied` 清除 shell 快照。切换期间展示非敏感框架，失权/网络未知清快照而非显示旧表。
- [ ] **Step 4: Green.** `chainPanel(api,{initialReadView})` 仅当 `initialReadView` 经过纯函数校验且授权包装器已成功时恢复；否则执行原 `load()`。构造器结尾写成 `if(initialReadView) restoreReadView(initialReadView); else void load();`，不可先触发原自动 GET 再恢复，否则会发生链上重载竞态。新增 `panel.exportReadView()` 返回普通数据副本：`draftFilters`、`activeFilters`、`offset`、`snapshot`、`items.slice(0,25)`、`summary`、`total`、`pageScrollY`、`rows.scrollLeft`、至多一个 `{item,record,open}` 详情及 `cachedAt=Date.now()`。不要放 DOM、凭据、写表单、地址草稿或 localStorage。保存前取得 `selectedRecord` 和详情数据，恢复后用已读数据构造只读详情、不触发 detail GET；`dispose()` 依旧关闭旧模态、撤销旧请求版本。列表与详情新的写按钮依旧走当前 grant。`admin-home.js` 串行接入 `walletContent` 导出方法并只缓存链上子视图；人工钱包、托管表和监控仍按现有生命周期重新读取。
- [ ] **Step 5:** 复跑 Step 2 专项，加 `node --check` 四个改动 JS；核对切页后 sessionStorage/localStorage 没有新增键，existing operation journal 未删。提交 `feat(admin): restore bounded chain view after menu return`。

## Task 6：所有者用途单选、链上候选选择与二次确认

**Files:** Modify `frontend/src/admin-manual-wallet-panel.js`, `frontend/src/admin-chain-panel.js`, `frontend/src/admin-home.js`; Test `frontend/tests/manual-wallet-panel.test.mjs`, `frontend/tests/admin-chain-panel.test.mjs`, `frontend/tests/admin-manual-wallet-api.test.mjs`.

- [ ] **Step 1: Red.** 对 `walletAccess=true` 的表单断言无可编辑 `log_index`、`reason_code`、`reason_detail` 输入；用途 `<select>` 初值为空、含“钱包测试转出”“对外付款”，未选不能预检。唯一非零事件自动预检的 JSON 无索引；预检成功只显示真实收款地址、由 `amount_units` 精确格式化的六位 USDT、缩略哈希、所选用途，执行调用数仍 0；管理员点击“确认申报”才携带响应里的精确索引执行，同一确认双击或与另一资金操作并发只发一次请求，失去 wallet grant 时拒绝。账本幂等键保持 `owner-transfer:<txid>:<index>`；HTTP `Idempotency-Key` 由 `operationJournal` 保存并在明确重试时复用。网络结果未知先 `getOwnerTransfer(txid)`，只把同一 `txid`、精确 `log_index`、原因码/固定说明和操作者均匹配的行判为本次成功；同哈希其他日志记录不得误判。切菜单关闭确认、清未提交草稿，已提交请求的最小元数据留在既有恢复日志内且不自动重放。
- [ ] **Step 2: Red.** 多转出时 `TRANSFER_SELECTION_REQUIRED` 引导查询链上完整哈希；管理员打开一条观察记录详情，应看金额、收款地址、北京时间，再点“用于所有者转出申报”，该记录的内部索引传给 preview 而不出现可编辑序号。若同哈希下观察器未收齐候选、总数超过可展示上限、两条候选的金额/目标/时间完全相同，禁用候选按钮并提示人工核查；非官方转出或证据冲突仍由后端拦截。预检与执行之间修改哈希/用途或再选另一候选，旧确认失效。
- [ ] **Step 3:** 运行 `node --test frontend/tests/manual-wallet-panel.test.mjs frontend/tests/admin-chain-panel.test.mjs frontend/tests/admin-manual-wallet-api.test.mjs`，确认当前四输入及预检后立即执行导致红灯。
- [ ] **Step 4: Green.** 在人工钱包面板定义固定映射，不接受自由填原因：

```js
const OWNER_PURPOSES=Object.freeze({
  test:{label:'钱包测试转出',reason_code:'OWNER_TEST_DRAW',reason_detail:'官方钱包持有人测试转出'},
  payment:{label:'对外付款',reason_code:'OWNER_EXTERNAL_PAYMENT',reason_detail:'官方钱包持有人对外付款'}
});
```

  构造 `txid`、空值 placeholder 的用途 select、所有权 checkbox；只在 preview 调用时按映射填 `reason_code/reason_detail`。维护闭包 `candidate` 与 `previewed={payload,snapshot}`，`txid`/用途/所有权任一变动时置空预检；`candidate.txid!==txid` 时丢弃候选。唯一情况 `previewOwnerTransfer(payload)` 不带索引，明确选择情况只带受控候选索引。预检调用内部捕获 `TRANSFER_SELECTION_REQUIRED` 和 `TRANSFER_NOT_FOUND`，分别把状态写成“该交易包含多笔官方转出，请从上方流水选择具体记录”与“该交易没有可申报的官方转出”，并直接返回，不进入通用 `commandForm` 的未知写入错误提示。返回 `blockers.length>0` 不显示确认；无 blocker 时展示信息并等待另一按钮点击执行。确认按钮必须复用 `commandForm` 的 `writing/refreshing/reading` 串行门槛、当下 `accessController.canWrite()` 和一次性禁用逻辑，执行前重新比对当前值与 `previewed.payload`，再次失权时只请求验证并要求用户重新主动确认。使用固定 `owner-transfer` journal 槽位，调用 `journal.begin('owner-transfer',{txid,log_index:snapshot.log_index,reason_code})` 前把 `log_index` 加入 `SAFE_METADATA`，仅保存已提交请求最小定位资料，不存固定说明、金额、地址、凭据或确认草稿；槽位在原请求未知时有意阻止提交另一笔 owner transfer，先核查原请求。把 journal 返回的 UUID 作为 HTTP `Idempotency-Key` 传给 `executeOwnerTransfer({...payload,log_index:snapshot.log_index},...)`，原领域账本键继续为 `owner-transfer:<txid>:<log_index>`；两种键不可混同。收到明确成功后 `journal.finish()`；结果未知保持 pending，只提供“查询原申报状态”，查询须从 `getOwnerTransfer(txid).transfers` 按索引、原因码、由映射得到的说明和 actor 精确匹配，匹配才完成日志，其他行或查询失败均不可判成功。再次主动重试须先查原状态、复用同一 journal key 和原 payload，不自动重放。完整用途说明仍写入原审计字段，API 旧调用者原因格式兼容。
- [ ] **Step 5: Green.** `manualWalletPanel` 收到 `TRANSFER_SELECTION_REQUIRED` 后提示管理员在上方流水输入同一完整哈希并查询；`chainPanel` 只允许从真实观察列表行打开 `getChainTransaction` 详情后选择。点击“用于申报”时查询 `getChainTransactions({txid,limit:100,offset:0})`（不按方向过滤），对返回的观察记录逐行读详情并比较金额、目标地址、时间；列表结果超出 100、分页不足、所选行不在观察记录、或两条可见出流在人眼可见字段完全相同，则不给确认选择。链上详情 API 的 `amount` 是六位十进制字符串，没有 `amount_units`；回调使用 `onSelectOwnerTransfer({txid,log_index,amount,to_address,timestamp_ms})`，全程按规范化十进制字符串比较，不用 `Number`；预检响应的 `amount_units` 才用 BigInt/字符串格式化。`admin-home.js` 仅接线，不把候选存入页面快照，并用前端契约测试锁定这两个 API 的不同金额字段。这个比较只验证已观察到的候选，不声称覆盖全部新鲜 TronGrid 证明；选中的行若尚未进入观察记录就无法供选择，服务端最终仍按证明验证精确索引。没有候选时提示等待同步或人工核查，不能把服务端多事件错误退化为默认 0。用户即使通过 DOM 篡改回调，服务端 preview 和 execute 仍复核链证据。
- [ ] **Step 6:** 复跑 Step 3 与 `tests/business_api/wallet/test_owner_transfer_declaration.py`，另加两个相同 txid 不同日志的未知执行结果回查、二次确认双击/并发和 `operationJournal` 按账号恢复测试；提交 `feat(admin): declare owner transfers by purpose and selected chain evidence`。

## Task 7：钱包工作台、监控事故与链上详情视觉

**Files:** Modify `frontend/src/admin-home.js`, `frontend/src/admin-manual-wallet-panel.js`, `frontend/src/admin-chain-panel.js`, `frontend/src/styles/admin-wallet.css`, `frontend/src/styles/admin-modern.css`; Test `frontend/tests/manual-wallet-panel.test.mjs`, `frontend/tests/admin-chain-panel.test.mjs`, `frontend/tests/admin-completion.test.mjs`; Create `frontend/tests/admin-wallet-layout.test.mjs`.

- [ ] **Step 1: Red.** 静态/DOM 测试检查：唯一“USDT 钱包操作台”主标题及锚点导航；“链上观察余额”明确不等于账本可用余额；没有服务端汇总时不呈现伪造人工出款总数；人工出款队列有来源说明、订单编号，旧底表标题为“托管提现申请记录”且表头“托管提现申请编号”；监控心跳、事故、资金控制分组；owner 申报预检/确认层级清晰；小屏表格在自身容器横滚；`prefers-reduced-motion` 关闭动画。所有状态和时间仍由现有 API、北京时间格式器给出。
- [ ] **Step 2:** 跑 `node --test frontend/tests/admin-wallet-layout.test.mjs frontend/tests/admin-chain-panel.test.mjs frontend/tests/manual-wallet-panel.test.mjs frontend/tests/admin-completion.test.mjs`，保存新断言红灯；单列原有 5 个 CSS 基线失败，不改 unrelated 全局令牌只为测试通过。
- [ ] **Step 3: Green.** `walletContent` 用深墨银锋标题区+浅色工作区，导航为 `<a href="#wallet-chain">` 等区内锚点，绝不通过标签卸载区块；链上、队列、事故、申报、账户安全分别为带标题/说明/状态的卡片。给链上余额加观察限定语；指标没有值时显示“尚未取得”而不是 `0`。旧 `GET /admin/modules/wallet` 表保持原数据，只改准确标题/表头与帮助句，说明平台编号和链上定位键差别。`manualWalletPanel` 将监控状态和事故列表分卡，保持原动作、筛选与 `T2` 级别；owner 申报卡采用 Task 6 的两阶段状态。
- [ ] **Step 4: Green.** CSS 采用现有 `--admin-*` 与 `--wallet-*` 变量，限定 `.admin-modern .admin-wallet-*` 或钱包容器，核对 `admin-wallet.css` 先于 `admin-modern.css` 的加载顺序并用足够具体的选择器覆盖；布局大屏双列、小屏单列，`.admin-chain-panel .admin-table-scroll {overflow-x:auto}`、详情桌面宽模态/窄屏接近全屏，按钮焦点轮廓不去掉。对 `@media (prefers-reduced-motion: reduce)` 禁用新动效，`@media (prefers-contrast: more)` 维持清晰边框。所有金额用六位字符串或 `formatUsdtUnits`，替换 owner 申报中的 `Number(amount_units)/1000000`。
- [ ] **Step 5:** 复跑 Step 2，运行 `node --check` 三个 JS；以已授权的隔离后台环境做桌面/窄屏键盘、复制失败、空/失败/成功态视觉检查，截图只存 `docs/verification/artifacts/2026-09-29/wallet-ui-acceptance/`，不采集真实地址、凭据或用户资料。提交 `feat(admin): style wallet operations and monitoring workspace`。

## Task 8：OpenAPI、运行手册与合同验证

**Files:** Modify `packages/api-contracts/openapi/liuhetong-v1.yaml`, `docs/runbooks/wallet-incident-recovery.md`, `docs/verification/2026-09-29-wallet-workspace-polish.md`; Test `tests/business_api/test_openapi_contract.py`, `tests/business_api/wallet/test_owner_transfer_preview_api.py`.

- [ ] **Step 1:** 在 `wallet-incident-recovery.md` 替换手填日志序号/原因描述：输入哈希、必选用途、所有权声明；唯一官方转出自动解析，多个事件从链上流水打开详情按金额/地址/时间选定；看真实收款地址和精确金额后独立确认；证据不足/无法区分时停止申报。保留“申报→事故复核→独立资金恢复”和接口 execute 仍需 `log_index` 的运维说明。
- [ ] **Step 2:** 设置 `$env:PYTHONPATH='services/business-api;.'`，运行 `py -3.12 scripts/export_openapi.py`，只确认 preview 模型的可选索引与 execute 必填索引的增量；再跑 `py -3.12 scripts/export_openapi.py --check` 和 `py -3.12 -m pytest tests/business_api/test_openapi_contract.py tests/business_api/wallet/test_owner_transfer_preview_api.py -q`，预期全绿。若出现其他契约漂移，先查候选基线，不能混入无关生成差异。
- [ ] **Step 3:** 对规格 WUI-1 至 WUI-7 逐行补源码/测试结果；文档链接解析、`git diff --check`、敏感值检查通过后提交 `docs(wallet): describe owner transfer preview and wallet workspace`。

## Task 9：规格与领域审查，再做质量安全审查

**Files:** Modify `docs/verification/2026-09-29-wallet-workspace-polish.md`; code changes only to close concrete review findings in their owning files.

- [ ] **Step 1:** 由独立审查者先按规格逐条核对 WUI-1…7，特别检查菜单返回未自动链上 GET、预检不落账、技术索引未出现在申报输入、旧提现表未混入人工出款队列；记录 PASS 或文件/行号缺陷，修缺陷后复审。
- [ ] **Step 2:** 领域审查 ADR-0071 边界：无索引只可自动选唯一官方 USDT Transfer；多/零/证据冲突拒绝；owner/grant 与预算锁先于 TronGrid；执行仍需索引且重新取证、核 VERIFIED 覆盖、未被订单占用；事务一次性申报、平衡账本、审计和 Outbox；未知执行结果只查原键。复跑领域测试并签署结论。
- [ ] **Step 3:** 领域通过后由另一审查者做质量/安全审查：失焦回查遮蔽、401/403/换账号/网络未知清敏感 DOM、会话代次、晚到异步请求、快照大小及没有浏览器持久化；复制不在 tooltip/log 泄露完整哈希；键盘/手机/减少动效；TOTP/操作密码及人工出款流程无回归。修复 P0–P2 后复审，不能用“已设计”代替通过。
- [ ] **Step 4:** 记录两轮审查的审查者、源码 SHA、缺陷处理、测试身份与耗时；每次变更只重跑受影响专项，最终候选再运行适用完整门禁。

## Task 10：完整门禁、隔离发布、生产验收与回退

**Files:** Modify `docs/verification/2026-09-29-wallet-workspace-polish.md`, `docs/workflow/tasks/2026-09-29-wallet-workspace-polish.md`; Modify admin static manifest/version references only after checking the actual loaded bundle and server baseline. No migration.

- [ ] **Step 1:** 在最后源码 SHA 上运行前端全部 `Push-Location frontend; npm test; Pop-Location` 与本任务业务 API +相邻钱包、权限专项；记录新增/已知失败身份。前置检查 `.env`、依赖、迁移唯一 head、OpenAPI 和 Docker 后运行 `pwsh -NoProfile -File scripts/verify.ps1` 至少一次；若环境缺项或脚本失败，记录出口、根因、修复/复测，不宣称全绿。按 `mobile-delivery-workflow.md` 的输入不变证据复用规则避免重复长测。检查 `git diff --check`、`node --check` 受影响 JS、没有新迁移/密钥/敏感日志。
- [ ] **Step 2:** 执行发布前重新读取 `docs/runbooks/admin-production-workflow.md`、`docs/runbooks/refresh-release-guards.md` 和对应 app release runbook；通过 `scripts/starchat-server.ps1`/既有 SSH 跳板只读冻结现行镜像 digest、实际 Compose、schema、管理台静态 SHA、导入路径、健康与认证探测。生成精确 JS/CSS/API/OpenAPI 清单和 SHA256；不能从脏树整体覆盖服务器。此任务无 Worker 行为改变，除非最终依赖比对证明必须纳入，原则上不重建 Worker。
- [ ] **Step 3:** 在隔离 PostgreSQL 克隆和候选 API 镜像模拟无索引唯一/多索引/失权及原 execute 精确索引；候选与兼容回退镜像都跑实际 `/auth/refresh` 协议镜像门禁（API 9、Worker 8 的现行规则），核对旧图像支持当前 0092 schema 且包含已发布资料审计/朋友圈行为。前端候选用受控合成数据走钱包菜单往返、遮蔽/失权、哈希复制、预检确认；服务端未授权路由返回 401/403。冻结旧静态文件与兼容回退镜像；扩展表和审计保留，不做破坏性 downgrade。
- [ ] **Step 4:** 在核对本任务生产发布授权后，按精确清单切换 API 与静态资源，验证真正由 `admin.liuhetong888.com` 加载的带版本 JS/CSS 及哈希，而不是只看 HTML 200；经 HTTPS/TLS 校验 API JSON ready、未授权 preview/execute 拒绝、真实生产配置与 schema、API/Worker 健康和无新错误，其他容器清单保持不变。没有真实管理员凭据时不冒充产品端登录；真实资金申报/出款不作为发布冒烟。公网可用跳板 SOCKS，保留主机钥匙与证书验证，结束后关闭本次隧道。
- [ ] **Step 5:** 新出现鉴权/协议/财务回归时停止功能发布并按冻结清单恢复旧静态和兼容 API 镜像，再运行 refresh 协议与钱包未授权探测；数据库的历史申报和审计不删。按 WUI-1…7 在台账中标“已实现/已测/已发布/待真实授权会话验收”，不把受控静态稿当作生产结果；写出下一可执行步骤和各阶段实际耗时。

## 自审检查

- WUI-1：Task 4；WUI-2、WUI-7 排版：Task 7；WUI-3、WUI-5：Task 3/7；WUI-4：Task 4/5；WUI-6 的资料意义与精确名称：Task 7/8；所有者转出新补充：Task 2/6/8。
- 所有资金写路径仍由当前 owner、grant、RBAC、事务与幂等审计保护。链上视图快照不用于授权，且只读；菜单返回须先服务端确认。执行缺索引仍 422，预检不生成账本分录。
- 计划每项有红灯、绿灯、明确文件、命令和完成证据；实施期间先规格/领域评审再质量/安全评审。Task 10 的生产行为以发布时冻结证据为准，不由本计划预断为已成功。
