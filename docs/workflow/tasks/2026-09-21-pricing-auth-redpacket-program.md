# 任务记录：点钻人民币计价 / 人工出入款 / 红包抽成 / 群主冷却 / 手机号注册

日期：2026-09-21（Asia/Hong_Kong）。授权：实现 + 隔离测试；**不授权生产发布、实际出款、生产数据修改**。
计划：[2026-09-21-pricing-auth-redpacket-group-program](../superpowers/plans/2026-09-21-pricing-auth-redpacket-group-program.md) · ADR 0075–0079。

## 阶段台账

| 时间 (UTC+8) | 阶段 | 证据 |
| --- | --- | --- |
| 2026-09-21 | 上下文恢复：current-state、交付 runbook、现代化规格、ADR 0010/0068/0070/0073/0074、代码地图 | 本记录 |
| 2026-09-21 | 设计与 ADR 完成（0075–0079 + 总计划 + 规格 2026-09-21 修订） | docs/adr、docs/superpowers/plans |
| 2026-09-21 | 服务端实现批次 1–8（FX/计价关闭/储备口径/红包抽成/群冷却/人工提现/人工充值/手机号）+ 迁移 0072–0078 + worker 接线 + OpenAPI 导出 | [验证记录](../../verification/2026-09-21-pricing-auth-redpacket-program.md) |
| 2026-09-21 | 全量后端测试：首轮 2286 通过/6 失败 → 全部归因修复（迁移头钉×2、webhook 验签顺序、规格契约更新、时间炸弹种子）→ 复跑剩余 4 失败再修复 → 目标 0 失败；`export_openapi --check` PASS；`verify.ps1` 结果见验证记录追记 | 同上 |

## 当前基线

- 工作树：main，含他任务未提交改动（admin 静态、docs 等）；本任务仅触碰「文件所有权」清单文件。
- 迁移链：0071 → 0072…0078（单头 `0078_phone_accounts`）。

## 状态结论（区分层级）

- 已实现+已测试（本地）：见验证记录第一节总表（FX、计价关闭、储备口径、红包抽成、群冷却、人工提现、人工充值、手机号服务端、迁移、OpenAPI、worker 接线）。
- 已实现未测试：无。
- 未实现：admin 静态三页、Flutter 客户端各页（服务端契约已冻结于 OpenAPI）。
- 待真机：无（客户端未实现，无从真机）。
- 未发布：全部未部署生产、未发生真实出款、未改生产数据。

## 下一步可执行操作

1. admin 静态后台三页（API 契约已冻结）。
2. Flutter 注册/登录/钱包/红包/提现页面按 OpenAPI 对接。
3. `SmsSender` 真实供应商适配（生产开启手机功能的前置）。
4. 生产发布需用户另行授权；迁移 expand-only 先行。



## 2026-09-21 追加：独立复审回填后的批次 1（后端一致性阻断项）+ 批次 2（后台三页）

- 输入：[复审报告](../../verification/2026-09-21-pricing-code-review.md)（回填 40 文件后的主工作区）、[下一步 prompt](../../workflow/prompts/2026-09-21-zcode-next-step.md)。
- 批次 1.1 转让协调：`group_transfer_intents`（0080）+ `GroupTransferCoordinator` 阶段机 + 网关 login-as-user/状态发送 + 恢复 worker；故障注入 8 项；**端点默认 503 隔离**（`group_transfer_coordination_enabled=false`）。
- 批次 1.2 充值绑定：`recharge_credit_bindings`（0079）+ bind/complete_bound/sweep + 管理端点 + worker；幂等登记、冲正拒绝、双端唯一。
- 批次 1.3 阿里云短信：用户指定 `alibabacloud_dypnsapi20170525`（SendSmsVerifyCode 供应商生成码 + CheckSmsVerifyCode）；适配器 + `code_verifier` 路径 + 配置校验；真实通道未开通。
- 批次 2 后台：`admin-recharge-panel.js`（案件/目录/汇率+储备三类数量）+ reserve-valuation 端点 + admin-api 方法；frontend 227 passed。
- ADR 0075/0077/0079 实施补充；OpenAPI 重导出；证据：[验证记录](../../verification/2026-09-21-next-step-backend-consistency.md)。
- Flutter 批次 3 未动工（契约入口已在证据文档第五节列明）。
