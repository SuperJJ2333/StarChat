# 管理台入口合并、客服改密与用户目录 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完成同页管理员/客服登录与自动首次开通、客服改共用密码、墨夜银锋登录与加载态、钱包负责人免密码只读，以及管理员专属用户目录。

**Architecture:** 保持现有静态 HTML/ES module 管理台和业务 API。认证、钱包、用户目录分别由身份、钱包和管理员应用接口授权；用户目录通过账本与客服模块公开批量读接口取权威资料。钱包只读从 60 分钟 grant 分离，写入保留原授权。生产候选以现行镜像和静态文件为基线，精确合并 2026-09-28 已上线的 T2 行为。

**Tech Stack:** FastAPI、SQLAlchemy、PostgreSQL/SQLite 测试、Python pytest、原生 JavaScript/CSS/Canvas、Node test runner、OpenAPI、PowerShell 7。

---

## 前置与所有权

- 书面设计：`docs/superpowers/specs/2026-09-28-admin-entry-merge-design.md`，用户已批准。受保护变更 ADR：`docs/adr/2026-09-28-admin-entry-merge.md`，执行前须获用户批准。工作树 `C:\Users\Administrator\.codex\worktrees\admin-entry-merge\StarChat`，分支 `codex/admin-entry-merge`。
- 根目录 `AGENTS.md`、`docs/runbooks/mobile-delivery-workflow.md`、`docs/workflow/current-state.md`、`docs/runbooks/admin-production-workflow.md` 和账本模块 `AGENTS.md` 均为执行约束。每个 PowerShell 7 命令先设置无 BOM UTF-8 的三种编码及 `PYTHONUTF8=1`、`PYTHONIOENCODING=utf-8`；Python 测试设置 `PYTHONPATH=services/business-api;services/business-worker/app`。
- 文件所有权依任务切分：认证任务拥有 `api/identity.py`、`modules/identity/recovery.py`、`modules/identity/tokens.py`、必要时的 `modules/identity/phone.py`、`modules/admin/service.py` 中客服角色写入、新 `modules/identity/staff_password.py`、Worker 的 `main.py`/`tasks/identity.py`、`frontend/src/admin-login.js`、新客服改密/开通对话框及对应测试；用户目录任务拥有 `api/admin.py`、`api/admin_report_contracts.py`、新 `modules/admin/user_directory.py`、`modules/ledger/service.py`、`modules/support/service.py`、新目录前端及测试；钱包任务拥有 `api/admin_session_boundary.py`、`modules/identity/wallet_grant.py`、各钱包读路由、`frontend/src/admin-wallet-access.js`、`admin-manual-wallet-panel.js`、`admin-chain-panel.js`及测试；集成任务串行拥有 `frontend/src/admin-home.js`、`admin-dashboard.js`、`admin-api.js`、`admin.html`、OpenAPI 和文档。若并行代理需改集成文件，先交接口给集成负责人，禁止同时编辑。
- 独立工作树公开分支 `971fb50d` 早于已经发布的钱包 T2，也早于主工作区未提交的账号安全变更。实施前核对 2026-09-28 钱包 T2 任务记录、生产 manifest 与当前生产文件/镜像 SHA。把本任务受影响的 T2 代码精确前移并通过原 T2 专项，不以旧树整建覆盖生产。账号改密只移植经核对的公开事务所需代码，不复制未批准的手机/邮箱功能或迁移。

## Task 1：冻结基线与兼容输入

**Files:** `docs/workflow/tasks/2026-09-28-admin-entry-merge.md`；`docs/verification/2026-09-28-admin-entry-merge.md`；受影响的三份 T2 后台 JS 及其 API/Worker 源文件仅在逐文件哈希核对后纳入。

- [ ] **Step 1:** 读取当前生产 API/Worker 镜像、schema、管理台静态 SHA 和 `docs/workflow/tasks/2026-09-28-wallet-monitor-t2.md` 的已发布清单；将相同文件的工作树、主工作区和线上哈希填入验证报告。使用 `pwsh -NoProfile -File scripts/starchat-server.ps1 -Action Probe` 及固定只读 `-Action Command -RemoteCommand`，不读取或打印密钥。
- [ ] **Step 2:** 核对当前隔离工作树的 Alembic 唯一 head、OpenAPI 导出及受影响 JS 导入。对已发布的 T2 源码用精确文件/补丁前移，保持 `manual-reserve:MANUAL_SOURCE_UNAVAILABLE` 的 T2、由链源 `max_age_ms` 驱动的 360 秒储备发布有效期，以及独立出款的 120 秒证据门槛。差异未解释前不得构建或发布。
- [ ] **Step 3:** 跑基线 `node --test frontend/tests/admin-login.test.mjs frontend/tests/admin-user-panel.test.mjs frontend/tests/admin-wallet-access.test.mjs`；Python 运行 `python -m pytest tests/business_api/identity/test_staff_login.py tests/business_api/identity/test_staff_activation.py tests/business_api/admin/test_user_readability.py -q`。记录真实退出码、通过数和源码 SHA；初次 Python 失败的错误环境 `PYTHONPATH=services/business-api;services/business-worker` 与纠正后的结果分开记录。
- [ ] **Step 4:** 仅提交精确前移和证据，提交信息 `chore(admin): align released wallet and identity baseline`；主工作区未提交文件不在提交范围。

## Task 2：客服首次登录自动开通

**Files:** Modify `frontend/src/admin-login.js`, `frontend/src/admin-staff-activation.js`, `frontend/src/styles/admin-login.css`; create `frontend/src/admin-staff-activation-dialog.js`; test `frontend/tests/admin-login.test.mjs`, `frontend/tests/admin-staff-activation.test.mjs`。

- [ ] **Step 1: Red.** 增加 DOM 测试：只有“管理员 / 客服”切换；客服 `staffLogin` 返回 `STAFF_ACTIVATION_REQUIRED` 后出现标题“首次开通验证方式”和邮箱/手机选择，同时加载新的图形验证码并把有效 `challenge_id`、`captcha_answer` 传给开通挑战；图形验证码失败刷新；确认 OTP 后再次登录；其他 401/403 不弹窗；取消/切换时清除密码。关键断言：

```js
assert.equal(document.querySelectorAll('.admin-login-modes button').length, 2);
assert.equal(document.querySelector('[aria-label="首次开通验证方式"]')?.hidden, false);
assert.equal(activationRequest.challenge_id, captcha.challenge_id);
assert.equal(activationRequest.captcha_answer, enteredCaptcha);
assert.equal(loginCalls, 2);
assert.equal(document.querySelector('[name="password"]')?.value, '');
```

- [ ] **Step 2:** 运行 `node --test frontend/tests/admin-login.test.mjs frontend/tests/admin-staff-activation.test.mjs`；确认失败点是独立“首次开通”仍存在、首次登录未触发对话框。
- [ ] **Step 3: Green.** 将原 activate 模式移至独立对话框，按精确错误码启动。对话框取得独立 CAPTCHA，显示/刷新图片并在请求开通挑战时提交 `challenge_id` 与 `captcha_answer`；复用 `createStaffActivationApi()` 的请求/确认。当前密码在原登录输入清空前存入仅本次交互的闭包，所有终止路径置空。保留管理员验证码、已开通客服免验证码、服务端限频和脱敏目标。
- [ ] **Step 4:** 复跑两个 Node 文件并执行 `node --check frontend/src/admin-login.js`；提交 `feat(admin): open staff activation from first login`。

## Task 3：客服专属共用密码修改服务

**Files:** Create `services/business-api/app/modules/identity/staff_password.py`; modify `services/business-api/app/modules/identity/recovery.py`, `services/business-api/app/modules/identity/tokens.py`, `services/business-api/app/api/identity.py`, `services/business-api/app/modules/admin/service.py`, `services/business-worker/app/tasks/identity.py`, `services/business-worker/app/main.py`; when candidate includes OTP recovery proof invalidation, also modify `services/business-api/app/modules/identity/phone.py` and the existing recovery confirmation entry points; tests `tests/business_api/identity/test_staff_password.py`, `tests/business_api/identity/test_staff_password_app.py`, `tests/business_worker/test_staff_password_event.py`, `tests/business_api/identity/test_staff_login.py`, `tests/business_api/admin/test_support_role_concurrency.py` and affected OTP recovery tests。

- [ ] **Step 1: Red.** 写服务/API 测试：已开通客服（含仅 SUPPORT_SUPERVISOR）携带当前管理 Bearer、匹配的 HttpOnly Cookie、同源标头与当前密码可改；仅主管首次登录应收到 `STAFF_ACTIVATION_REQUIRED`，开通后可登录；超级管理员（含混合角色）、普通用户、未开通/撤权客服、普通 App Bearer、缺 Cookie/CSRF、旧设备及错误密码拒绝；成功撤销 App/后台旧 family、建立 24 小时提现 hold、审计和 Outbox 各一次。Worker 能消费新事件，且 payload 无密码/联系方式。隔离 PostgreSQL 并发测试让邮件重置与客服改密同账号竞争，只允许一个成功，另一明确失败/重试，不死锁且旧链接不能在改密后生效；另测试客服角色撤销与改密竞争，若撤权先提交，改密拒绝；角色授予与开通摘要校验也在相同锁序下执行。若候选失效 `OtpChallenge` 恢复凭据，再测 OTP 确认与客服改密竞争，不得死锁或让旧 OTP 在改密后生效。核心断言：

```python
assert response.status_code == 204
assert old_admin_access.status_code == 401
assert old_app_refresh.status_code == 401
assert hold.reason_code == "PASSWORD_RESET"
assert audit.actor_id == staff_id and event.aggregate_id == staff_id
```

- [ ] **Step 2:** 运行 `python -m pytest tests/business_api/identity/test_staff_password.py tests/business_api/identity/test_staff_password_app.py tests/business_worker/test_staff_password_event.py tests/business_api/identity/test_staff_login.py -q`；确认缺接口/权限行为导致红灯。
- [ ] **Step 3: Green.** 新建 `POST /api/v1/auth/admin-session/staff-password` 严格模型 `{current_password,new_password}`，`repr=False`，204/no-store。复用 `admin_origin`、`tokens.admin_session`、`tokens.require_admin_cookie` 和按 IP/账号的限频。身份服务在用户行锁内复核当前 AdminSession/family、ACTIVE、STAFF_ROLES 且不含 SUPER_ADMIN、开通摘要及密码；`tokens.issue_admin_pair(staff_only=True)` 同步允许已开通的仅 SUPPORT_SUPERVISOR。`AdminControlService.set_support_role`、`revoke_support_role` 和 `revoke_all_support_roles` 同一事务先锁目标 User，再读取或写入 UserRole；改密复核角色和激活摘要也在 User 锁内读取最新角色行，统一 User→UserRole 锁序。随后调用从恢复服务提取的 `reset_in_session`，在同一事务做哈希、family 撤销、恢复挑战/证明失效、提现 hold、审计和 `identity.account_credentials`/`identity.password.reset` Outbox。旧邮件重置先无锁读取 challenge 的 user_id、锁 User、再锁 challenge 并重验令牌/时效/未消费；若候选恢复证明还包含 `OtpChallenge`，须核对并统一所有相应 `verify_code`/恢复确认路径先锁 User、再锁 OTP，锁后重验用途、时效、未消费及身份摘要。客服改密同样 User→挑战/OTP，不得引入逆序锁环。把完成事件消费者接入 Worker `main.py`，在 `tasks/identity.py` 精确验证该事件类型/安全 payload；不投递到邮件请求 handler。
- [ ] **Step 4:** 复跑四组专项，并回归旧 `/auth/password/reset`；检查 OpenAPI 只包含约定字段，无密码回显；提交 `feat(identity): allow activated staff to change shared password`。

## Task 4：客服改密页面与会话退出

**Files:** Create `frontend/src/admin-staff-password-dialog.js`; modify `frontend/src/admin-session.js`, `frontend/src/admin-dashboard.js`, `frontend/src/admin-home.js`; tests `frontend/tests/admin-session.test.mjs`, `frontend/tests/admin-dashboard.test.mjs`, new `frontend/tests/admin-staff-password.test.mjs`。

- [ ] **Step 1: Red.** 测试仅客服且非 SUPER_ADMIN 有“修改密码”；三字段校验；请求带 Bearer、同源 Cookie、`X-Admin-CSRF` 和 session id；成功清空输入及 `adminSession.clear()` 后显示登录；失败保留可编辑新密码但不记录明文。关键断言：

```js
assert.equal(staffHeader.textContent.includes('修改密码'), true);
assert.equal(adminHeader.textContent.includes('修改密码'), false);
assert.equal(request.headers['X-Admin-CSRF'], '1');
assert.equal(adminSession.peek(), null);
```

- [ ] **Step 2:** 运行三个 Node 测试文件，确认缺入口和方法导致红灯。
- [ ] **Step 3: Green.** `adminSession` 增加 `changeStaffPassword(body)`，先取 `token = await getToken()`，再调用 `call('admin-session/staff-password', body, token)`；成功立即清会话并通过 `admin-home.js` 回登录。账号菜单只控制呈现，最终权限由 Task 3 接口决定。`dialog` 支持 Escape、焦点恢复、等待和错误状态。
- [ ] **Step 4:** 复跑并提交 `feat(admin): add staff shared password action`。

## Task 5：管理员用户目录的权威数据与权限

**Files:** Create `services/business-api/app/modules/admin/user_directory.py`; modify `services/business-api/app/modules/ledger/service.py`, `services/business-api/app/modules/support/service.py`, `services/business-api/app/api/admin.py`, `services/business-api/app/api/admin_report_contracts.py`; tests `tests/business_api/admin/test_user_directory.py`, `tests/business_api/ledger/test_ledger.py`, `tests/business_api/admin/test_user_readability.py`。

- [ ] **Step 1: Red.** 写 150 人跨页、按畅聊号/昵称/邮箱/手机搜索、游标绑定过滤、零余额和大额精确 `"0.00"`/两位字符串、客服撤权、禁用账号、原 analytics/security/context 不含完整联系方式的测试；普通客服、财务、审计角色和 App Bearer 返回 403/401。用查询计数断言账本不会每用户执行一次求和。
- [ ] **Step 2:** 运行 `python -m pytest tests/business_api/admin/test_user_directory.py tests/business_api/admin/test_user_readability.py -q`，确认新接口缺失或越权断言失败。
- [ ] **Step 3: Green.** 在账本服务新增 `balances_for(account_ids)`，单次 `GROUP BY LedgerEntry.account_id` 只统计 `CAIBI`，用 Decimal 并为缺账户填 `0.00`；客服模块新增批量官方头衔读取，交叉核对当前客服角色。目录服务筛选 User 的合法列，复用有界游标策略，在 API `POST /admin/users/search` 上同时要求真实管理 session、同源、SYSTEM_ADMIN；限制 `q` 最长 128、`limit` 1–100，默认 50；审计只存搜索摘要，响应 no-store。独立响应模型不加入 `/admin/context` 预取。

```python
def balances_for(self, account_ids: list[str]) -> dict[str, Decimal]:
    ids = list(dict.fromkeys(account_ids))
    if len(ids) > 100:
        raise ValueError("balance page exceeds 100 accounts")
    with self.session_factory() as session:
        rows = session.execute(select(LedgerEntry.account_id, func.sum(LedgerEntry.amount))
            .where(LedgerEntry.asset == "CAIBI", LedgerEntry.account_id.in_(ids))
            .group_by(LedgerEntry.account_id)).all()
    found = {account_id: money(Decimal(amount)) for account_id, amount in rows}
    return {account_id: found.get(account_id, Decimal("0.00")) for account_id in ids}
```
- [ ] **Step 4:** 复跑三组专项，检查 OpenAPI 模型无 hash、钱包地址或 Matrix ID；提交 `feat(admin): add administrator-only user directory projection`。

## Task 6：用户目录页面

**Files:** Create `frontend/src/admin-user-directory.js`; modify `frontend/src/admin-home.js`, `frontend/src/admin-dashboard.js`, `frontend/src/admin-api.js`, `frontend/src/styles/admin-users.css`; tests new `frontend/tests/admin-user-directory.test.mjs`，及 `frontend/tests/admin-dashboard.test.mjs`、`frontend/tests/admin-api.test.mjs`。

- [ ] **Step 1: Red.** 测试管理员侧边栏显示“用户管理”而客服不显示；进入时才请求 `/admin/users/search`；搜索和翻页稳定；列含畅聊号、邮箱、手机号、点钻余额、客服头衔；迟到结果不覆盖新搜索；错误保留已显示页且不持久化 PII。
- [ ] **Step 2:** 运行三个 Node 文件，确认缺入口及专用 API 方法造成红灯。
- [ ] **Step 3: Green.** 增加目录组件和专用 `searchUsers({q,limit,cursor})`，将搜索词置 JSON body、`cache:no-store`、同源 credentials 与管理 token，不采用用于金融写入的 `command()` 自动重试。入口权限取服务端 context 的管理员身份；用 `textContent` 填单元格，保留筛选/游标、空态、载入、重试和销毁防竞态。原有统计/封禁面板不改敏感列。

```js
searchUsers: ({q='', limit=50, cursor=null}={}) => request('/api/v1/admin/users/search', {
  method: 'POST', credentials: 'same-origin', cache: 'no-store',
  headers: {'Content-Type': 'application/json', 'X-Admin-CSRF': '1'},
  body: JSON.stringify({q, limit, cursor})
})
```
- [ ] **Step 4:** 复跑并提交 `feat(admin): present restricted user directory`。

## Task 7：钱包只读授权与写操作守卫

**Files:** Modify `services/business-api/app/modules/identity/wallet_grant.py`, `services/business-api/app/api/admin_session_boundary.py`, `services/business-api/app/api/manual_wallet_operations.py`, `services/business-api/app/api/admin_wallet_repairs.py`, `services/business-api/app/api/admin_wallet_owner_transfers.py`, `services/business-api/app/api/manual_wallet_handover.py`, `services/business-api/app/api/admin.py`（Task 5 完成后由集成负责人串行修改 context 和 no-store）；tests `tests/business_api/identity/test_wallet_access_app.py`, `tests/business_api/identity/test_wallet_access_boundary.py`, `tests/business_api/test_admin_repairs_full_app.py` 及钱包相关专项。

- [ ] **Step 1: Red.** 在 `wallet_access_grant_enabled=true` 下，使用真实 `create_app()` + TestClient 逐条请求 21 条已审查 GET：为需 ID、txid、日期或查询参数的路由准备合法 fixture，有效 owner admin session 且无 grant 能进入业务查询并返回预期 200；另单独断言授权阶段不再返回 `WALLET_ACCESS_REQUIRED`，敏感 `/admin/modules/wallet` 响应 no-store；非 owner、App token、已撤销/冻结/替换 session、提现 SecurityHold 均拒绝。菜单仅 owner 可见。同 URL 的 POST、未列新 GET 默认仍要求 grant。相同 owner 无 grant 的四项直接出款 `claim/adjust-rate/txid/correct-candidate`、事故 ack、三类 repair preview、owner transfer POST 仍拒绝且无业务写；有 grant 的旧命令仍可执行，过期/锁等待跨截止不能提交。grant verify/revoke、固定密码初设/修改保持各自原门槛；功能开关关闭时旧策略不变。
- [ ] **Step 2:** 运行两个 wallet access 测试文件，确认 owner 读取仍被 `WALLET_ACCESS_REQUIRED` 拒绝。
- [ ] **Step 3: Green.** 在 `wallet_grant.py` 增加 `require_read(claims)` 与事务内 `read_authorization()`，复用 `_identity` 对 owner/会话/设备/family/ACTIVE/提现 SecurityHold 的检查，不调用 grant `_valid`。统一 boundary 只对下列显式白名单 GET/HEAD 调只读授权，其他受 gate 的方法仍 `require`。逐个显式 GET 路由改用事务内 read callback；`admin_wallet_repairs.py` 拆 `read_context` 和仍用 grant 的 `preview_context`，三个 POST preview 继续原授权；`admin_wallet_owner_transfers.status` 使用 read callback 同时保留 feature flag。业务写入事务中的原授权回调与提交前复核不动。`admin.py` 的 context 给实际 owner 专用 `wallet_owner_read` capability，前端不凭 `*` 猜测 owner；钱包模块 GET 响应 no-store。钱包安全 bootstrap 和 access verify/revoke 排除项不变。

```python
if settings.wallet_access_grant_enabled and wallet_management_path(request.url.path):
    grant = wallet_grant_service(settings, session_factory, clock)
    if request.method in {"GET", "HEAD"} and wallet_read_allowlist(request):
        grant.require_read(claims=claims)
    else:
        grant.require(claims=claims)
```

当前白名单采用**真实请求时** `request.scope['route'].path` 的相对模板，而非 OpenAPI 的完整路径、路径前缀或宽泛正则。此应用的 `_IncludedRouter` 使 `/api/v1/admin/modules/wallet` 的运行时模板为 `/admin/modules/{module}`，daily report 为 `/admin/wallet/reports/daily`，其余为 `/wallet/...`；这些值已由真实 `create_app()` 请求逐条核对。全局管理会话边界是路由依赖，执行时 `route` 已存在；若不存在则关闭豁免并继续要求 grant。外层 `wallet_management_path(request.url.path)` 仍用完整实际 URL 限制到钱包域。仅以下集合可只读授权，未来新路由默认落回 grant：

```python
WALLET_READ_ROUTE_TEMPLATES = frozenset({
    "/admin/modules/{module}",  # 外层 wallet_management_path 仅匹配实际 wallet 值
    "/admin/wallet/reports/daily",
    "/wallet/reports/closed/{id}",
    "/wallet/incidents",
    "/wallet/incidents/{id}",
    "/wallet/monitor/status",
    "/wallet/chain/summary",
    "/wallet/chain/transactions",
    "/wallet/chain/transactions/{txid}/{log_index}",
    "/wallet/manual/payouts",
    "/wallet/manual/payouts/{order_id}",
    "/wallet/manual/operations/control",
    "/wallet/manual/operations/diagnostics",
    "/wallet/manual/handover/{id}",
    "/wallet/manual/deposit-repairs/candidates",
    "/wallet/manual/deposit-repairs/{operation_id}",
    "/wallet/manual/manual-deposit-cases/context",
    "/wallet/manual/manual-deposit-cases/operations/{operation_id}",
    "/wallet/manual/manual-deposit-cases/{case_id}",
    "/wallet/manual/payout-reconciliations/{operation_id}",
    "/wallet/manual/owner-transfers/{txid}",
})
def wallet_read_allowlist(request: Request) -> bool:
    route = request.scope.get("route")
    return getattr(route, "path", None) in WALLET_READ_ROUTE_TEMPLATES
```
- [ ] **Step 4:** 复跑受影响 wallet/repair/owner-transfer/incident/出款专项和 OpenAPI 导出，提交 `feat(wallet): allow owner session to read without grant`。

## Task 8：钱包页面进入即读、写前验证

**Files:** Modify `frontend/src/admin-wallet-access.js`, `frontend/src/admin-home.js`, `frontend/src/admin-manual-wallet-panel.js`, `frontend/src/admin-chain-panel.js`, `frontend/src/admin-wallet-repair-dialog.js`, `frontend/src/admin-manual-deposit-case.js`; tests `frontend/tests/admin-wallet-access.test.mjs`, `frontend/tests/admin-manual-wallet-api.test.mjs`, `frontend/tests/admin-repair-entry.test.mjs`, `frontend/tests/admin-chain-panel.test.mjs`。

- [ ] **Step 1: Red.** 无 grant 但 owner 进入即见只读钱包；出款、事故、链上详情中“充值补入账/提现核对”及嵌套 create/decision/preview/execute 均在未授权时提示“验证以操作”，验证成功后用户再次提交；grant 到期且服务端确认 owner 有效时仍可读但不能发写请求；网络失败、401、owner 切换清空旧 DOM 和 detached dialogs；操作密码首次设置/更换在无 grant 时仍可走独立凭据流程。不自动重放资金或事故命令。
- [ ] **Step 2:** 运行三组 Node 专项，确认现有页面仍强制模态验证才读取。
- [ ] **Step 3: Green.** 将读取 API 与命令 API 分开，`walletAccessPanel` 初始只读渲染，已有 grant 状态只控制业务命令。`admin-dashboard.js` 的 wallet 菜单需读取 Task 7 的 `context.capabilities.wallet_owner_read`，不可由管理员 `*` 权限直接推断。`manualWalletPanel` 和链上嵌套修复/核对对话框显式接收 `canWrite`/`requestWriteGrant`；未授权时禁用或拦截资金/事故/preview 命令，验证仅调用原 verify API，不回放先前动作。固定操作密码 setup 继续走 raw API 和原登录密码/近期登录校验，不被 `canWrite=false` 禁用。grant 到期清空操作证明与待提交状态，服务端 owner 状态有效时保留只读视图；网络/权限不明、401、owner 变化则销毁旧资料及 detached dialogs。保留已发布的 T2 事故文案与筛选。

```js
async function requireWriteIntent() {
  if (gate.allowed()) return true;
  await showWriteVerification();
  return false; // User must review the action again after verification.
}
async function submitAfterIntent(run) {
  if (!await requireWriteIntent()) return;
  await gate.guard(run);
}
```
- [ ] **Step 4:** 复跑、DOM 浏览器核查并提交 `feat(admin): separate wallet viewing from command proof`。

## Task 9：墨夜银锋登录和居中加载态

**Files:** Create `frontend/src/admin-login-scene.js`; modify `frontend/src/admin-login.js`, `frontend/src/admin-home.js`, `frontend/src/styles/admin-login.css`, `frontend/admin.html`; tests `frontend/tests/admin-login.test.mjs`, `frontend/tests/admin-dashboard.test.mjs`；视觉参考 `docs/verification/artifacts/2026-09-28/admin-entry-design/login-directions.html`。

- [ ] **Step 1: Red.** DOM 测试精确四行诗、居中品牌图标与 `role=status` 的加载态；画面失败也能提交登录、减少动效时不持续动画；窄屏和键盘对话框可用。
- [ ] **Step 2:** 运行 Node 专项，确认诗句/图标加载态缺失导致红灯。
- [ ] **Step 3: Green.** 依据已选 A 视觉稿实现深墨双栏、银锋、青色星轨；本地 CSS 与 Canvas 轻量渐进动效，`prefers-reduced-motion` 静止，Canvas `aria-hidden`。保留现有登录验证表单可访问标签和错误播报。加载态用品牌图标、环形指示、状态文字居中，错误仍显示重试。版本参数更新为本批唯一候选值。

```js
function loadingView() {
  const main = element('main', 'admin-loading');
  main.setAttribute('role', 'status');
  main.append(element('img', 'admin-loading-icon'),
    element('span', 'admin-loading-spinner'),
    element('p', null, '正在加载管理台'));
  main.querySelector('img').src = '/assets/branding/admin-logo.png';
  main.querySelector('img').alt = '畅聊';
  return main;
}
```
- [ ] **Step 4:** 复跑 Node、用桌面/窄屏浏览器截图检查布局及键盘焦点，提交 `feat(admin): add ink-and-silver login and loading state`。

## Task 10：契约、审查、完整验证与生产交付

**Files:** Update `packages/api-contracts/openapi/liuhetong-v1.yaml`、`docs/workflow/tasks/2026-09-28-admin-entry-merge.md`、`docs/verification/2026-09-28-admin-entry-merge.md`、`frontend/admin.html`。若发布步骤变化，再修改 `docs/runbooks/admin-production-workflow.md`。

- [ ] **Step 1:** 比对实现与设计及本 ADR 五项验收；先请领域/规格审查，修正缺项后请独立质量/安全审查。特别核对管理员验证码、客服角色撤销、CSRF、密码/PII日志、钱包读写清单、T2保留及资金事务。审查意见与修复证据记录在验证报告。
- [ ] **Step 2:** 运行所有受影响 Python/Node 专项、格式/类型/OpenAPI 检查；预检 `.env`、解释器、磁盘、迁移 head 和当前并行工作后运行 `pwsh -NoProfile -File scripts/verify.ps1`。所有失败记录原始命令/退出码/根因/复跑；不以旧树缺环境冒充通过。
- [ ] **Step 3:** 依 `docs/runbooks/admin-production-workflow.md` 冻结真实现行镜像、schema、Compose、静态与数据库备份；0700 私有目录与隔离 PG 恢复演练；做精确 manifest/SHA 和回退脚本。检查候选含已发布 T2 和现行非本任务改动，仅重建清单内服务。真实短信/邮件和资金写入不在本任务自动触发范围。
- [ ] **Step 4:** 按已批准的生产后台工作流发布，服务器及工作站经 jumper 保持 HTTPS/TLS 证书验证，核对 API JSON 健康、未授权拒绝、前端资源 SHA、其他容器未变及错误日志。无真实客服/管理员账号时只报告未能亲历登录，不伪造验收。
- [ ] **Step 5:** 更新验收台账逐项标明“实现/测试/发布/真实操作反馈”，记录候选 commit、镜像和静态 SHA、起止时间、回退位置及尚未验证的外部渠道；再按 `finishing-a-development-branch` 流程处理分支。

## 计划自检

五项用户需求分别由 Task 2–4、Task 9、Task 7–8、Task 5–6 覆盖；Task 1 处理已发布 T2/主工作区漂移，Task 10 处理契约、审查与发布。没有将客服订单免二次验证扩大为管理员钱包写入豁免；没有给客服用户目录权限。任何实现前必须先有本 ADR 与计划的明确批准。
