# 后台 UI 生产发布与验证弹窗修复

授权：用户已检查 HTML demo，并于本轮明确要求发布到生产及修复已验证进入钱包仍闪弹窗。沿用现有授权机制，仅修改展示时序；不执行真实资金操作。

- [x] G1（本轮缺陷编号）：wallet_flash（显式 gpt-5.6-terra）独占 frontend/src/admin-wallet-access.js 和相关新测试。未知状态在页面内等待，不创建 dialog；敏感内容隐藏、服务器验证仍为唯一授权依据。覆盖延迟已验证、重新进入/focus、未验证/过期、网络失败、销毁后响应。先 red 后 green。
- [x] G2（关联 U1/U2）：ui_release_prepare（显式 gpt-5.6-terra）仅编写本任务 artifacts 下发布工具与模拟测试；Astra 独立审查。发布清单仅 src/admin-support-panel.js、src/styles/admin-modern.css、src/admin-wallet-repair-dialog.js、src/admin-manual-deposit-case.js、src/admin-wallet-access.js。保持接口、金额、审批、未知结果查询、幂等与审计。
- [x] G3：Astra 审查真实 diff/调用链及红绿证据，运行全前端、UI 契约。核对当前生产与基线，冻结 SHA256 清单，服务器私有备份，静态最小发布。HTTPS 文件 hash、JSON 健康、未授权拒绝和容器不变验收；记录回退路径和限制。

并行仅 G1 产品文件与 G2 发布工具，无共享修改。G3 必须等待前两项完成并通过审查。沿用 U3 的真实浏览器客服/入账 demo 验证；未变后端和 Flutter 复用原范围证据。

2026-09-13 13:49 +08 验收完成：[发布记录](../../verification/2026-09-13-admin-ui-production.md)。
