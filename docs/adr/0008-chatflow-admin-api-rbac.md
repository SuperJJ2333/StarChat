# ADR-0008: ChatFlow 后台管理 API 与真实 RBAC

**状态：** 已批准  
**日期：** 2026-08-27  
**评审：** 领域评审通过；Quality/Security 评审通过

## 决策

1. 产品用户可见名称统一为 **畅聊 ChatFlow**；后台、官网、OpenAPI 客户端示例和错误页面不得新增“六合通”展示文案。内部数据库、迁移、`PRODUCT_SLUG=liuhetong` 与历史 API 路径保持兼容。
2. 新增 `/api/v1/admin/*` 管理端 API。管理端不再把 fixture 视为权威数据；fixture 仅作为 API 不可用时的开发空状态，不得用于写入或绕过授权。
3. 所有管理 API 使用 Bearer access token，通过服务端 `RbacService` 按 `Permission` 枚举鉴权，默认拒绝未知权限。前端隐藏按钮不构成授权。
4. 读取接口按权限返回最小字段；敏感值（IP、USDT 地址、用户邮箱）只返回脱敏值。后台 API 不读取普通 E2EE 房间正文、附件明文或密钥。
5. 管理写操作必须同时满足：权限、`Idempotency-Key`、稳定 `reason_code`、actor identity、AuditEvent 与 Transactional Outbox。`SUPER_ADMIN`（或拥有 `system.admin` 权限的管理员）在其权限范围内可直接执行修改命令；管理员操作不再要求额外审批、二次验证或 TOTP。账本和提现状态只能调用对应 application service，禁止直接写表。
6. 角色沿用既有 `USER`、`SUPPORT_AGENT`、`FINANCE_SUPPORT`、`SUPPORT_SUPERVISOR`、`SUPER_ADMIN`；普通角色继续遵循原有权限矩阵，只有 `system.admin` 管理员获得跨模块直接修改能力。直接执行不会绕过 RBAC、幂等冲突检查、审计记录或 Transactional Outbox。

## API 边界

- `GET /api/v1/admin/session`：返回当前管理员的用户标识、角色和权限集合。
- `GET /api/v1/admin/overview`：返回聚合 KPI、待处理队列和审计摘要。
- `GET /api/v1/admin/modules/{module}`：返回九个后台模块的分页、筛选结果；模块服务负责字段和权限裁剪。
- `POST/PATCH /api/v1/admin/...`：仅在对应模块 service 暴露的命令上执行，拒绝客户端传入 actor、余额、审计结果等权威字段。

OpenAPI 由 `scripts/export_openapi.py` 生成并进行 drift check；React/HTML 客户端通过同源 `fetch` 或生成客户端调用，不硬编码生产凭据。

## 领域评审结论

- Matrix 仍是通信域；Admin API 只访问业务域的身份、客服、账本、钱包、通知和审计 application service。
- 点钻使用 `CAIBI` 两位小数，USDT 使用六位小数；两者不转换、不混账。
- 客服身份来自业务 RBAC 响应，不由 Matrix 昵称或前端状态推断。

## Quality/Security 评审结论

- 未授权、过期 token、未知权限和跨租户对象访问均返回稳定 `PERMISSION_DENIED`/`AUTH_REQUIRED` 错误。
- 测试覆盖权限矩阵、管理员直接修改（无需 TOTP/审批）、幂等冲突、审计脱敏、Outbox 事件、OpenAPI 契约和前端权限门控。
- 日志与响应禁止包含密码、token、消息正文、恢复密钥、完整钱包地址和未脱敏 IP。

## 后果

- 管理后台可由真实权限驱动并可审计，后续可替换为生成的 TypeScript OpenAPI client。
- 需要维护 Admin API 契约、权限测试和前端 session 失效处理；本 ADR 不改变既有业务 API 路径。
