# 聊天、媒体、通知与通话入口

**Current index · 2026-09-20**。专题文档是各自范围的参考，不是对当前生产和所有设备的重新验收。

| 主题 | 权威入口 / 使用边界 |
| --- | --- |
| 会话恢复与防重复 | [V2元数据恢复](direct-room-v2-recovery.md)、[目标生命周期ADR](../adr/2026-09-19-direct-destination-lifecycle.md)、[恢复ADR](../adr/2026-09-19-recoverable-direct-room-alias.md) |
| 定向修复 | [已退出房间修复](retired-direct-room-repair.md)：这里retired指房间生命周期，不表示手册废弃 |
| 通知设计 | [通知系统参考](../architecture/notification-system.md)、[通知QA矩阵](../testing/notification-qa-matrix.md) |
| 推送配置 | [推送通道](push-setup.md)：历史凭据缺口须现场核对 |
| 通话网络 | [TURN](turn.md)：历史IP/日期不代表现场状态 |
| 视频与媒体 | [视频发送链路](../architecture/video-send-pipeline.md)、[头像存储](profile-avatar.md) |
| 容量与框架 | [千人容量验证](thousand-member-capacity.md)、[框架部署](matrix-framework-deployment.md) |

先读[当前任务状态](../workflow/current-state.md)。不能根据旧check-then-create、旧预约永不恢复说明来覆盖新生命周期协议；保留历史房间、密钥和原消息位置，不把清历史或重复建房当恢复措施。

好友重构、Android私聊兼容、媒体选择与性能审计已归入[历史索引](../archive/2026-09-20/README.md)。原报告的测试结果及开放项保持不变。
