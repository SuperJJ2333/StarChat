# StarChat / 畅聊文档入口

整理日期：2026-09-20。这里只标注文档职责和状态，不代表重新验收生产或产品。

| 要做的工作 | 从这里开始 |
| --- | --- |
| 恢复当前任务 | [当前状态](workflow/current-state.md)、[任务模板](workflow/task-template.md)、[根规则](../AGENTS.md) |
| 开发、修复、移动交付 | [交付总流程](runbooks/mobile-delivery-workflow.md)、[批准计划](superpowers/plans/) |
| Android/iOS构建 | [构建与Actions](runbooks/mobile-release.md)、[Android固定打包](runbooks/android-apk-rebuild.md) |
| 官网、安装包、更新弹窗 | [轻量发布唯一入口](runbooks/release-metadata.md)、[传输与备份](runbooks/app-release-deployment.md) |
| 生产与后台 | [生产工作流](runbooks/admin-production-workflow.md)、[配置漂移](runbooks/production-config.md) |
| 聊天、推送、通话 | [通信索引](runbooks/communications.md) |
| 钱包、资金、安全操作 | [钱包索引](runbooks/wallet.md) |
| Flutter / HTML界面 | [UI交付](runbooks/ui-development.md)；Figma门禁已退役 |
| 全部专题手册 | [运行手册目录](runbooks/README.md) |

## 资料分层

- [architecture](architecture/)：设计与实现参考；[testing](testing/)：测试矩阵。
- [ADR](adr/)：已记录的架构决策；[规格](superpowers/specs/)和[计划导航](plans/README.md)。
- [reports](reports/)与[verification](verification/README.md)：历史结论及证据，不当作今日状态。
- [本次历史归档](archive/2026-09-20/README.md)：旧发布命令、一次性部署、旧审计/重构正文；不直接执行。
- 根目录两份0917缺陷CSV是原始需求与标准化输入，保留原名和内容，进度进入[任务记录](workflow/tasks/)。

根目录旧文件保留简短兼容跳转，使原链接和跨会话引用继续可用；正文已合并或归档，不再维护平行版本。
Current表示入口或现行流程；Reference表示专题资料需现场核对；Historical/Retired不能作为新任务授权。归档不删除审计、财务、加密证据，也不把未验收项改成已完成。
