# 管理员提现一致性任务

## 恢复入口

- 授权：用户确认取消边界，审阅批准设计、ADR、计划并要求直接执行。
- 状态：已实现并于 2026-09-30 19:41 +08:00 发布。未代做任何真实订单退款、事故结案或恢复资金。
- 工作树：`C:/Users/Administrator/.codex/worktrees/wallet-alert-only-payout-void/StarChat`，分支 `codex/wallet-alert-only-payout-void`。
- 设计：[spec](../../superpowers/specs/2026-09-30-admin-withdrawal-parity-design.md)、[ADR](../../adr/2026-09-30-admin-withdrawal-parity.md)、[plan](../../superpowers/plans/2026-09-30-admin-withdrawal-parity.md)。
- 完整验收/限制/回退：[verification](../../verification/2026-09-30-admin-withdrawal-parity.md)。
- 下一步：用户在管理员真实会话 Ctrl+F5 后按订单状态独立验证操作；需要调查失败时先读本任务证据和当前生产镜像，不重复已完成门禁。

## 验收台账

| ID | 状态 |
| --- | --- |
| W1 统一充值/提现 UI | 已上线；桌面/窄屏实际渲染 |
| W2 管理员专属提现 | 已上线；官方负责人+SUPER_ADMIN，客服拒绝 |
| W3 自动预览/五按钮 | 已上线；六位定点与草稿刷新 |
| W4 取消与停止复核 | 已上线；未经独立证明不退款 |
| W5 资金/并发/审计 | 本地 172、镜像 18、镜像 PG 12 通过 |
| W6 最小发布/兼容 | API 40ad213c；worker 3efd5924 未变；两端 5 资源 hash+健康通过 |

## 时间与身份

- 设计文档终端观察：2026-09-30 17:57:29 +08:00；精确实施起点未采集，不估算。
- 实施检查：2026-09-30 19:06 起记录最终阶段；实际测试时长见 verification。
- 切换起点：2026-09-30 19:41:00 +08:00。
- 最后更新：2026-09-30T19:46:56.049806+08:00
- 生产 schema 保持 0094，无迁移。最小覆盖 7 API/5 静态文件。
- 完整 verify 因工作树缺 .env 停止；全前端唯一历史 iOS 版本测试失败，两项均明确记录，未掩盖。

## 保留边界

原订单 3e728fe3-7343-4036-b9a0-646e56a46457 未因本次发布被取消。结果未知的退款仍需要当前链上证据及管理员独立声明；无到账不能推断未广播。历史事故、资金启停分别处理。保留无关 pubspec.lock 和 staff-order-access 文档。
