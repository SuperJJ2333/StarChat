# StarChat / 畅聊文档导航

**status:** Current index；**owner:** 项目维护者；**last_verified:** 2026-09-10（文档治理核对，未重新验收产品或生产）。

## 当前入口

- [根 AGENTS.md](../AGENTS.md)：任务、发布、安全与证据约束；[产品设计基线](superpowers/specs/2026-08-12-starchat-product-modernization-design.md)。
- [Runbooks 导航](runbooks/README.md)：打包、发布、生产配置、后台与业务操作；[发布总入口](RUNBOOK_RELEASE.md)。
- [UI 开发与 HTML demo](ui-development-html-demo-workflow.md)：现行 Flutter–HTML 交付流程；历史 Figma 不再作为门禁。
- [统一计划导航](plans/README.md)：新计划使用 [superpowers/plans](superpowers/plans/)，两份旧计划原址保留；[设计规格](superpowers/specs/)；[ADR](adr/)。
- [验证证据与保留策略](verification/README.md)：结论、工件、归档和恢复约束。

## 历史需求与证据

- [Figma 历史索引](figma/README.md)：冻结 registry、parity、CSV 与截图；保留远端未同步事实。
- 审计链：[需求](ChatFlow_Codex_审计修复Prompt.md) → [计划](plans/chatflow-audit-remediation.md) → [结果](reports/chatflow-audit-remediation-result.md)。Historical；原记录为 2026-09-05 完成及其剩余限制，财务 / E2EE 审计永久保留。
- [聊天 UX 计划](plans/chatflow-chat-ux-spec.md)：Historical / pending reconciliation，不能将部分完成或历史待做自动视为当前完成。

## 专题资料（原址保留）

以下是当前文档导航中的参考入口，统一状态为 **Reference / pending revalidation**；尚未逐段核对现行代码，不能把“被收录”当作最新规格或最新验收。历史问题与实现结论继续保留，由相应功能维护者在下次相关变更中核对。

| 主题 | 文档 |
|---|---|
| Android 安全与私聊兼容 | [安全审计](ANDROID_SECURITY_AUDIT.md) · [Android 私聊兼容](DIRECT_CHAT_ANDROID_COMPATIBILITY.md) |
| 好友 | [好友系统重构](FRIEND_SYSTEM_REFACTOR.md) |
| 媒体 | [媒体选择修复](MEDIA_PICKER_FIX.md) · [视频发送链路](VIDEO_SEND_PIPELINE.md) |
| 推送 / 通知 | [通知系统](NOTIFICATION_SYSTEM.md) · [QA 矩阵](NOTIFICATION_QA_MATRIX.md) · [推送配置](PUSH_SETUP.md) |
| 通话 / 性能 | [TURN](TURN.md) · [性能与缓存审计](PERFORMANCE_AND_CACHE_AUDIT.md) |
| 生产配置 | [生产配置 Runbook](RUNBOOK_PRODUCTION_CONFIG.md)（Current reference；与打包文档职责独立） |

## 状态口径

Current 表示当前入口或生效流程；Historical 表示历史事实；Retired 表示流程已被替代；pending revalidation / reconciliation 表示仍需按代码和证据核对。`last_verified` 只涵盖声明的检查范围，不暗示所有业务或线上状态有效。文件日期旧、主题相近或没有文本引用均不足以删除。

本次治理依据[审核清单](verification/2026-09-10-docs-cleanup-review.md)及[用户批准的执行计划](superpowers/plans/2026-09-10-docs-cleanup-execution.md)。
