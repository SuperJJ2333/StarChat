# ChatFlow Admin API + 真实 RBAC 验证

## 变更
- 产品展示名称统一为“畅聊 ChatFlow”；内部 `liuhetong` slug 与 API 路径保持兼容。
- 新增 `/api/v1/admin/session`、`/overview`、`/modules/{module}`、`/context`。
- Admin API 使用 Bearer access token + 服务端 `RbacService`；未授权模块不返回数据。
- 前端新增 `design-demo/src/admin-api.js`，管理台通过同源 OpenAPI fetch 获取 context，按权限显示模块、KPI 和导出操作，不持久化 token。
- ADR：`docs/adr/0008-chatflow-admin-api-rbac.md`（领域评审、Quality/Security 评审结论已记录）。

## 证据
- BASELINE: `npm test`（原有 14 项 UI 契约测试通过）。
- MODIFIED: `design-demo/npm test` 输出 17/17 通过。
- MODIFIED: `py -3.12 -m pytest tests/business_api/admin/test_admin_api.py tests/business_api/test_openapi_contract.py -q` 输出 7 passed。
- MODIFIED: `py -3.12 -m pytest tests/business_api -q` 输出 164 passed, 1 skipped。
- MODIFIED: `py -3.12 scripts/export_openapi.py --check` 输出 `OpenAPI contract: PASS`。
- ROLLBACK: `docs/verification/artifacts/2026-08-27/admin-homepage-ui-implementation/ROLLBACK.sh` 已在副本上验证 `ROLLBACK_OK`；活动修改保留。

## 评审结论
- 领域：Matrix 通信域与业务 Admin API 分离；账本、钱包和客服操作继续经 application service，点钻/USDT 精度与隔离规则不变。
- Quality/Security：RBAC 默认拒绝、权限按模块裁剪；TOTP、幂等、审计机制沿用现有服务；敏感字段保持脱敏，不返回 E2EE 正文、密钥或完整钱包地址。
