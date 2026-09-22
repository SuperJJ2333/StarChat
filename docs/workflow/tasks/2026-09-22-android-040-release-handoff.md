# Android v0.4.0发布交接

用户明确授权服务器部署、仅Android v0.4.0并合并2156完成修复。2026-09-22 01:18+08已发布正式ARM64 0.4.0+2157及新刷新服务器；iOS设置/安装页和最低版本保持原状。候选源码28bdfc48、交付记录5acfb346，分支codex/android-040-release-20260922，工作树.worktrees/chat-reliability-diagnostics干净。

[完整报告](../../../.worktrees/chat-reliability-diagnostics/docs/verification/2026-09-22-android-040-release.md) · [任务](../../../.worktrees/chat-reliability-diagnostics/docs/workflow/tasks/2026-09-22-android-040-release.md)。Flutter3803/analyze0，mobile108/1条件skip，后端未变证据复用，真实生产备份隔离恢复/并发/协议通过，固定签名APK重建通过。服务器b7d38f99879d/0080健康，7文件哈希一致，无新错误；公网HEAD200，发布器平台隔离和审计通过。

[下载](https://www.liuhetong888.com/downloads/ChatFlow-0.4.0-build2157-arm64.apk)。SHA256 4d488ce6985c998053712bd0729a004a51ddf38b8bdb8480c444b85de2ec8776，80,522,270字节。真机手感和后台返回待用户升级复验，未自动安装/卸载或清数据。

主目录其他未提交金融/手机号/群迁移保留；本次所有已完成指定提交已在候选整合，但不把主目录未完成改动投入生产。未来main整合需显式处理其0072–0080迁移与本次0080分叉。旧服务器镜像在新Android已发布后不再是兼容回退，必须保留新协议。宿主0700备份/审计在/opt/starchat/releases/android-040-20260922/。

所有构建和发布命令已结束；本任务隔离PG/匿名卷/网络已清理，工作站临时T映射和18945隧道关闭。下一步为用户真机反馈，无等待中的发布动作。
