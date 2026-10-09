# 后台导航、分页与客服权限

## 恢复入口

- 用户授权：2026-09-30 六项明确要求、直接实施，包括客服业务权限。
- 设计/计划：../../superpowers/specs/2026-09-30-admin-navigation-staff-design.md；../../superpowers/plans/2026-09-30-admin-navigation-staff.md。
- 工作树：C:/Users/Administrator/.codex/worktrees/wallet-alert-only-payout-void/StarChat；基线 ed0dbbc8。
- 状态：已上线并完成生产核验。所有权：后台 frontend/src/admin-*、后台 CSS/HTML demo、admin API/controls/RBAC 及对应测试/契约/文档。
- 保留既有 mobile pubspec.lock 与 staff-order-access 任务记录。
- 生产观测：API 40ad213c、worker 3efd5924，2026-09-30 SSH 实际核验；本次已受控升级 API 至 001ddf33，worker 保持不变。
- 下一步：用户刷新后台使用；具体故障按当前镜像和最终清单定位。

## 验收台账

| ID | 预期 | 状态 |
| --- | --- | --- |
| N1 | 钱包五独立子模块，保留钱包验证 | 已实现、测试并上线 |
| N2 | 列表默认10，可选20/50 | 已实现、测试并上线 |
| N3 | 中文徽章，单角色撤销保留其他角色 | 已实现、测试并上线 |
| N4 | 有效用户/IP封禁可准确解除 | 已实现、测试并上线 |
| N5 | 客服五模块，点钻只查询，提现仍管理员 | 已实现、测试并上线 |
| N6 | UI demo、审查、发布及回退证据 | 已实现、测试并上线 |

## 阶段计时

2026-09-30 +08：恢复和源代码调查进行中；具体起止以工具与证据日志为准，不推测历史生产状态。

## 完成证据

见 [交付报告](../../verification/2026-09-30-admin-navigation-staff.md)。最终候选后台72项、真实PG9项、续期协议、备份恢复通过；338生产路径保留，17静态文件双端哈希一致；worker/其他容器未变。全前端5项旧基线失败、verify环境限制如报告所述。
