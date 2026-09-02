# ChatFlow 管理后台正式构建记录（2026-08-28）

## 错误记录与根因

此前后台模块点击后仅使用前端 context 中的空数组，导致页面看似有入口但无法展示真实业务数据；同时钱包地址、账本对象直接交给通用渲染器会产生 `[object Object]`。本次将模块卡片改为按需调用 `/api/v1/admin/modules/{module}`，并增加模块专用数据投影与钱包地址脱敏，避免重复错误。

## 已实现

- Admin API：`analytics`、`security`、`support-role`、`finance`、`ledger`、`wallet`、`ads` 返回真实业务表数据；`online` 使用设备心跳窗口统计。
- 概览 KPI：注册用户、在线客户、待审核提现、当日点钻流水。
- 钱包地址仅返回首字符+末四字符掩码；CAIBI 两位、USDT 六位字符串格式。
- 前端模块点击触发真实 API 请求，显示加载/错误状态；专用 presenter 防止对象字符串化。

## 验证证据

- BASELINE：`python -m pytest -q tests/business_api/admin/test_admin_api.py`（新增数据测试在修改前失败：ledger items 为空）。
- MODIFIED：同命令 -> `4 passed`。
- MODIFIED：`cd design-demo; npm test` -> `20 passed`。
- MODIFIED：`python scripts/export_openapi.py --check` -> `OpenAPI contract: PASS`（先检测到漂移后重新生成，再次检查通过）。

## 回滚

使用 Git 恢复 `services/business-api/app/api/admin.py`、`design-demo/src/admin-home.js`、`design-demo/src/admin-presenters.js` 及对应测试/契约文件即可恢复此前行为；未修改 Matrix 通信域及资金 application service。

---

## 受控写操作增量（2026-08-28）

### 新增受控命令

- `POST /api/v1/admin/security/bans`：按用户或 IP 封禁；用户封禁同步写入身份状态。
- `POST /api/v1/admin/security/bans/{ban_id}/revoke`：解除封禁并恢复此前被本流程暂停的用户。
- `POST /api/v1/admin/support-roles/{target_user_id}`：授予客服/财务客服/客服主管角色。
- `POST /api/v1/admin/notices`：创建立即或定时公告。
- `POST /api/v1/admin/ads`：创建朋友圈原生广告草稿。
- `POST /api/v1/admin/finance/adjustments/{request_id}/review`、`POST /api/v1/admin/finance/withdrawals/{withdrawal_id}/review`：后台审批入口委托既有账本/钱包 application service。

所有新增的高风险创建命令均要求 Bearer RBAC、`Idempotency-Key`、`X-TOTP-Code`，并在同一业务事务写入 AuditEvent 和 OutboxEvent。新增表采用 expand migration `0027_admin_controls`；不破坏 Matrix 通信域。

### 增量验证

- RED：新增测试在端点尚未存在时返回 `404`。
- GREEN：`python -m pytest -q tests/business_api/admin/test_admin_api.py` -> `7 passed`。
- 契约：`python scripts/export_openapi.py --check` -> `OpenAPI contract: PASS`。
- 生产：业务容器应用迁移后 `healthy`；`/api/v1/health/live` -> HTTP `200`；未认证受控命令 -> HTTP `401`。

### 生产回滚

部署前镜像仍保留在 Docker 本地缓存；可将 `business-api` 恢复为前一镜像并 `docker compose ... up -d --no-deps --force-recreate business-api`。数据库新增表不被旧版本引用，属于向后兼容 expand 变更；不要在紧急回滚中执行 destructive downgrade。

---

## 后台运营完整流程增量（2026-08-28）

### 已完成

- 公告编辑、撤回与用户阅读回执（`notice_receipts` 唯一约束确保重复上报幂等）。
- 原生广告投放时段、JSON 定向规则与曝光/点击累计（`native_ad_campaigns`）。
- 客服角色撤销。
- 后台受控操作表单：封禁、角色配置、广告创建、公告发布、点钻审批与提现审批；客户端每次生成 `Idempotency-Key`，显式填写 TOTP。
- API 继续仅通过账本和钱包 application service 执行点钻、提现审批；不直接写资金状态。

### 部署故障记录

初版迁移 revision `0028_notice_receipts_ad_campaigns` 超过生产 `alembic_version.version_num VARCHAR(32)` 上限，迁移 DDL 已事务回滚但版本更新失败，导致容器重启。根因已确认并改为 `0028_notice_receipts_ads`（24 字符）。生产数据库确认版本已更新，容器随后从头重建并健康恢复；没有执行 destructive migration，聊天和业务健康检查恢复 HTTP 200。

### 验证

- `pytest tests/business_api/admin/test_admin_api.py -q`：`8 passed`。
- `cd design-demo; npm test`：`21 passed`。
- `alembic upgrade head --sql`：包含 0027、0028 expand DDL。
- OpenAPI drift：`PASS`。
- 生产：Business API healthy；`https://liuhetong888.com/api/v1/health/live` HTTP 200；管理首页 HTTP 200；未认证管理 context HTTP 401；新模型 import `PASS`。

---

## 安全中心 TOTP 绑定（2026-08-28）

- 新增管理 API：`GET /admin/security/totp`、`POST /admin/security/totp/enroll`、`POST /admin/security/totp/confirm`、`POST /admin/security/totp/disable`。
- 密钥仅在 enroll 响应中返回一次；服务端持久化加密密钥，状态接口绝不返回密钥。
- 管理后台新增“安全中心”，支持查看状态、绑定/更换、输入验证码确认与停用。
- 测试：后台 API `9 passed`；前端 `23 passed`；OpenAPI drift `PASS`；生产 health / 管理首页 HTTP 200。

### 安全中心请求失败修复

- 根因：生产错误响应采用 `{error:{code,message,trace_id}}` 包装，前端只读取顶层字段，因而显示通用“请求失败，请重试”。
- 修复：客户端统一解包 `error` envelope，并显示实际错误码与可读提示；验证码输入增加 6 位数字校验。
- UI 说明补充：明确列出 Google Authenticator、Microsoft Authenticator、1Password 等身份验证器 App 及绑定步骤。
- 验证：前端 `24 passed`；生产后台首页 HTTP 200；TOTP status HTTP 200；enroll HTTP 201。
