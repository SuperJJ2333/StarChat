# 后台 UI 生产发布

- 授权：用户“好的，请你发布到生产”，另要求已验证进入 USDT 页面绝不闪验证弹窗。
- 计划：[admin-ui-production](../../superpowers/plans/2026-09-13-admin-ui-production.md)。关联已验收 U1/U2/U3。
- 状态：2026-09-13 13:49 +08 已发布验收完成。当前工作区，不克隆/拉取/回退其他修改。
- 模型：主代理 Astra 审查；已实际创建 wallet_flash、ui_release_prepare，均显式 gpt-5.6-terra，最多两执行代理。工作区无 .codex 自定义覆盖目录，工具支持显式模型且创建成功。
- 根因：walletAccessPanel 在 getWalletAccess 返回前 show(unknown)，除 ready/legacy 外直接创建 dialog/showModal；focus 的 lock 同样触发。
- 当前生产只读核对：API sha256:119e69710767af56613425341ed7e7920f5f1d9123d3926c8ee0139dd159ce1f；上一轮四个静态文件均匹配 U1/U2 保存的基线，钱包 access SHA256 9ceb3a2d4a98e98b8e886e45a8d67fb21d4163468ce722e6231ed5b2a38f6d7e。
- 下一步：用户刷新后台进行实际管理员体验验收；无待执行自动化发布步骤。五文件发布完成，未改服务/数据库/配置。
- 阶段计时：本轮最早准确时间未采集；后续测试/发布日志记录时间，不虚构总耗时。
- 验证证据：docs/verification/artifacts/2026-09-13/admin-ui-production/。
- 最终验收：207 前端通过、UI 契约通过、8+3 发布工具测试通过、真浏览器 showModal 累计 0；两端 HTTPS/hash/健康通过。详细范围、计时、回退及限制见[发布记录](../../verification/2026-09-13-admin-ui-production.md)。
