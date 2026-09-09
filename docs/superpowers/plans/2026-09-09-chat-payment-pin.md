# 红包与转账支付密码实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan. Steps use checkbox syntax for tracking.

**Goal:** 已批准的六位支付密码、首次设置、统一键盘，服务端强制校验及Redmi隔离验证。

**Architecture:** identity模块管理支付凭据与短期意图票据；业务创建事务通过公开接口验证及消费票据。Flutter共享输入组件，API适配层保留原有Matrix卡片重试边界。PIN不落盘，不修改账本公式。

**Tech Stack:** Flutter/Dart、FastAPI/Pydantic、SQLAlchemy/Alembic、Argon2、pytest、Android adb。

## 责任与接口

- 服务端实施者独占 `services/business-api/` 和 `tests/business_api/test_payment_pin*.py`，负责新增identity支付模块、API、迁移及红包/转账事务接入；不得修改账本计算。
- 客户端组件实施者独占 `apps/mobile_flutter/lib/features/payment_pin/` 和对应 `test/payment_pin*`；共享组件通过注入网关，便于隔离Widget/真机验证。
- 主实施者独占其余Flutter调用点、`business_api_client.dart`、API契约、发布检查、计划及验证材料；审查后协调集成。

API约定：`GET /payment-pin/status`返回`configured`；`POST /payment-pin/setup`请求`pin, login_password`及幂等头；`POST /payment-pin/authorize`请求`pin, action, payload, idempotency_key`，返回`authorization`。action为`chat_transfer.create`或`red_packet.create`，payload为实际创建请求（不含票据）。创建请求增加可选`payment_authorization`；服务端按账号凭据/正式切换策略决定强制性。授权绑定完整规范化参数、会话及幂等键。配置过PIN的账号始终强制，不可用旧客户端绕过；全账号强制开关只影响尚未设置的账号，默认兼容期，正式切换需配套客户端。客户端自身始终执行设置与校验。

## Task 1: 凭据与授权（测试先行）
- [x] 写并运行失败用例：ASCII恰好六位、前导0、登录密码确认、不能覆盖、失败锁定持久化。
- [x] 新增独立Argon2封装、凭据/授权表、审计与Outbox、会话和账号/IP限流。
- [x] 写并运行授权绑定、过期/重放/跨会话、并发、回滚和幂等回归用例。
- [x] 通过公开接口接入红包/转账创建事务；检查所有创建API入口。
- [x] 添加0059扩展迁移、更新head检查、导出OpenAPI；PostgreSQL迁移及恢复验证。

## Task 2: 六位键盘与设置（测试先行）
- [x] Widget失败用例：最多六位、删除、清空、确认按钮、前导0、不自动提交、小屏无溢出。
- [x] 实现六格掩码、三列数字键、底部显式确认；操作时禁重复、关闭清理、无系统数字键盘。
- [x] 实现登录密码确认、首次输入/再次确认、错误重输和服务端设置成功后返回。
- [x] 支付确认显示用途/对象/金额/费用；校验失败清空PIN并保留上下文，账号变更终止。

## Task 3: 客户端业务接入
- [x] API客户端新增状态/设置/授权，创建接口支持固定幂等键及授权，并检查账号作用域。
- [x] 红包和转账入口先获取账号配置，未设置引导；提交时获取绑定当前参数的授权。
- [x] 验证取消不扣款、失败不重复创建、Matrix卡片重试只重发引用；所有原有发送入口接入。
- [x] Widget/控制器/API传输契约聚焦测试通过；更新本地UI契约，记录远程Figma不可用边界。

## Task 4: 复核、构建与真机
- [x] 先规格/领域复核，再质量安全复核；修复发现问题并运行对应回归。
- [x] 运行Flutter analyze/test、业务pytest及 `scripts/verify.ps1`；保存命令和结果到 `docs/verification/artifacts/2026-09-09/payment-pin/`。
- [x] 服务端先隔离部署验证。正式环境只在兼容、迁移和审查通过后部署，保留现有API增量，不改正式Android/iOS更新配置。
- [ ] 按APK重建runbook生成并验证稳定Debug签名包，安装Redmi `cbd0156b`，不卸载/清除原数据。
- [ ] 真机使用隔离测试界面/账号验证完整设置和支付请求链路；当前真实账号只验证安全的打开/输入/取消，绝不替用户设置未知永久PIN或动用真实余额。
- [x] 逐项记录预期与实际、APK校验值、包版本、设备证据及未验证边界；提交代码和变更说明。

## 验证命令

PowerShell 7设置UTF-8后，业务测试使用`PYTHONPATH=services/business-api;services/business-worker/app;.`及`py -3.12 -m pytest tests/business_api/test_payment_pin*.py -q`。Flutter使用`C:/src/flutter/bin/flutter.bat test`及`analyze`。验证所有服务端拒绝用例的余额、账本笔数、授权状态及审计，不仅检查HTTP状态。

当前阻塞：真机隔离流程已运行，但flutter drive清理自动卸载了正常包名，恢复安装被MIUI拒绝。已向用户披露并请求在手机允许安装；APK已放下载目录。真实账号恢复登录与加密数据恢复仍待用户操作，不能宣称完整交付。详见本次验证报告。
