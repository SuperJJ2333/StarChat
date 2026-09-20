# 运行手册导航

**2026-09-20 文档整理。** 实际目录为docs/runbooks；不另建runbook副本。

发布只走[轻量发布门禁](release-metadata.md)；构建进入[mobile-release](mobile-release.md)；生产操作先读[admin-production-workflow](admin-production-workflow.md)。钱包专题从[钱包索引](wallet.md)、通信专题从[通信索引](communications.md)进入。

## 当前入口与专题参考

Reference文档的日期、镜像、迁移头、凭据缺口和测试结论属于其记录时点，不构成最新生产事实。执行前读[当前任务状态](../workflow/current-state.md)及任务批准计划；未做本轮全业务复审。

| 文档 | 状态与边界 |
| --- | --- |
| [Registration Activation Codes](activation-codes.md) | Reference：专题操作，须现场核对 |
| [Admin browser login](admin-browser-login.md) | Reference：专题操作，须现场核对 |
| [管理后台会话与报表运行说明](admin-console-sessions-and-reports.md) | Reference：专题操作，须现场核对 |
| [StarChat后台完整交付与跳板发布工作流](admin-production-workflow.md) | Current：总流程/分类入口 |
| [Android APK 固定打包流程](android-apk-rebuild.md) | Current：总流程/分类入口 |
| [安装包传输与发布职责](app-release-deployment.md) | Current：总流程/分类入口 |
| [红包与转账支付密码](chat-payment-pin.md) | Reference：专题操作，须现场核对 |
| [聊天、媒体、通知与通话入口](communications.md) | Current：总流程/分类入口 |
| [充值自动兑换点钻运维说明](deposit-auto-conversion.md) | Reference：专题操作，须现场核对 |
| [Direct-room V2 deployment and metadata recovery](direct-room-v2-recovery.md) | Reference：专题操作，须现场核对 |
| [窗口外充值人工补录](manual-deposit-cases.md) | Reference：专题操作，须现场核对 |
| [imToken 人工出款首版操作与验收](manual-tron-funding.md) | Reference：专题操作，须现场核对 |
| [Matrix framework deployment](matrix-framework-deployment.md) | Reference：专题操作，须现场核对 |
| [BUG、新功能与 Android/iOS 交付工作流](mobile-delivery-workflow.md) | Current：总流程/分类入口 |
| [Android / iOS 构建入口](mobile-release.md) | Current：总流程/分类入口 |
| [生产配置与漂移管理](production-config.md) | Current：总流程/分类入口 |
| [个人资料头像存储运行手册](profile-avatar.md) | Reference：专题操作，须现场核对 |
| [Public-domain gateway deployment](public-domain-deployment.md) | Reference：专题操作，须现场核对 |
| [推送通道配置手册（Matrix Pusher + Sygnal + FCM/APNs）](push-setup.md) | Reference：专题操作，须现场核对 |
| [邀请码（referral）API 与安全性说明](referral-invite-codes.md) | Reference：专题操作，须现场核对 |
| [注册邮件与 Matrix 开户运行手册](registration-email-matrix.md) | Reference：专题操作，须现场核对 |
| [Android / iOS 轻量发布门禁（2026-09-20，用户批准）](release-metadata.md) | Current：总流程/分类入口 |
| [已退出私聊房间的定向修复](retired-direct-room-repair.md) | Reference：专题操作，须现场核对 |
| [千人加密群容量验证](thousand-member-capacity.md) | Reference：专题操作，须现场核对 |
| [TRON真实只读观察器](tron-watch-only.md) | Reference：专题操作，须现场核对 |
| [TURN 服务与通话网络兜底](turn.md) | Reference：专题操作，须现场核对 |
| [UI Development and HTML Demo Workflow](ui-development.md) | Current：总流程/分类入口 |
| [Production user-declared address mode](wallet-address-registration.md) | Reference：专题操作，须现场核对 |
| [钱包日流水预览与导出](wallet-daily-ledger-preview.md) | Reference：专题操作，须现场核对 |
| [人工钱包事故后的恢复](wallet-incident-recovery.md) | Reference：专题操作，须现场核对 |
| [Independent manual wallet activation](wallet-independent-activation.md) | Reference：专题操作，须现场核对 |
| [Wallet MFA setup without signing out](wallet-mfa-setup.md) | Reference：专题操作，须现场核对 |
| [钱包日结与事故处置（Sandbox）](wallet-operations.md) | Reference：专题操作，须现场核对 |
| [钱包应用 Sandbox 操作边界](wallet-sandbox-application.md) | Reference：专题操作，须现场核对 |
| [钱包与资金操作索引](wallet.md) | Current：总流程/分类入口 |

## 兼容跳转

这些旧路径不再包含可误执行的旧步骤。历史正文、旧版本和回退证据完整保留在归档中，不能对新环境直接运行。

| 旧入口 | 状态 |
| --- | --- |
| [管理后台完整交付与受控人工修复发布](admin-completion-deployment.md) | 历史正文已归档，仅兼容入口 |
| [管理后台可读性版本发布](admin-readability-deployment.md) | 历史正文已归档，仅兼容入口 |
| [App 更新配置发布与回退](app-update-publication.md) | 历史正文已归档，仅兼容入口 |
| [Durable direct-room creation](direct-room-coordination.md) | 历史正文已归档，仅兼容入口 |
| [仅使用 Windows 和 iPad 配置 TestFlight](ios-windows-testflight-setup.md) | 历史正文已归档，仅兼容入口 |
| [Moments 评论权限部署与回退](moments-comment-privacy-deployment.md) | 历史正文已归档，仅兼容入口 |
| [Wallet access verification release](wallet-access-deployment.md) | 历史正文已归档，仅兼容入口 |
| [私人钱包绑定与后台链上查询发布准备](wallet-binding-deployment.md) | 历史正文已归档，仅兼容入口 |
| [钱包客户端与服务端联合发布核对](wallet-client-server-release.md) | 历史正文已归档，仅兼容入口 |
| [钱包应用生产发布：真实资金关闭模式](wallet-production-release.md) | 历史正文已归档，仅兼容入口 |
| [钱包过期快照重采样：生产维护](wallet-reserve-resampling-deployment.md) | 历史正文已归档，仅兼容入口 |

[文档总入口](../README.md) · [历史归档](../archive/2026-09-20/README.md) · [验证保留策略](../verification/README.md)
