# 钱包生产应用部署记录

2026-09-06 15:32:45 UTC（香港时间23:32:45）开始正式发布；用户在上一轮部署就绪交付后授权继续。范围为真实资金关闭的应用部署，不包含真实USDT开放。

## 实际执行

- 重新校验线上五层Compose基线、原API/Worker镜像、候选镜像ID、源码归档与172文件SHA256清单。
- 刷新服务器受限备份 `/opt/starchat-backups/wallet-20260906T153107Z-894518`，SHA256 `ce4f81b53ce3802e6a6564beddf1c48bce5fbc7c2adeddb568d6e12e3266f13b`。完整数据库在断网容器恢复并确认0038；数据和私密配置未下载。
- 停止旧Worker，生产数据库从0038升级至0041；预检返回 `RELEASE_READY_FUNDS_DISABLED`。
- 按镜像ID启动新API，再启动新Worker，均通过健康检查。其他已有容器ID保持不变，没有重建数据库、Redis或Matrix。
- 准备了失败自动回退旧应用镜像的执行分支，本次未触发；没有降级或恢复覆盖生产数据库。

## 上线验收

- API实际镜像：`sha256:961c3a0e1b9a32f40455ed1fe14cfa7e4a28ef9b6c2f139cb792108ca350b276`。
- Worker实际镜像：`sha256:78080de4b17ebf515278c623ec0182f19b828373747a8840bcc5ec327f9f5233`。
- 公网 `/api/v1/health/ready` 返回200，未登录访问钱包配置返回401；Matrix版本入口返回200。
- 在运行中的API内直接只读调用钱包配置路由，确认 `funding_enabled=false`、`conversion_enabled=false`；此项不冒充登录后的HTTP流程测试。
- 生产版本表确认0041；钱包监控最近尝试距检查约12.6秒，错误明确为 `MONITOR_UNAVAILABLE`。这是无provider的预期受限状态，不代表真实链上监控或外部通知已可用。
- 登录后的聊天/钱包端到端流程未重跑：本轮没有提供可用测试账号。不伪造用户令牌或使用真实用户身份进行验收。本轮没有改动或重新安装MI 6客户端；此前真机证据仍属此前测试环境。

## 证据与后续维护

[发布结果](artifacts/2026-09-06/wallet-production-readiness/deployment-result.json)、[发布前检查与新备份](artifacts/2026-09-06/wallet-production-readiness/deployment-prechecks.txt)、[上线后只读检查](artifacts/2026-09-06/wallet-production-readiness/postdeploy-check.json)。执行脚本及私密命令日志位于服务器发布目录；工作区只保存脱敏结果。

本轮未修改应用代码；复用上一轮已通过45项专项、全仓库601通过30跳过及领域/安全审阅的源码与镜像。新运维脚本Ruff通过。真实MPC、操作MFA、外部告警送达、RPO=0与iOS真机验收仍未完成。

操作与回退参考[发布手册](../runbooks/wallet-production-release.md)。手册旧0038前置检查现在属于历史步骤，不要重复执行；当前只读复查使用 `postdeploy_check.py`。后续发布应重新取得当前基线并备份。应用回退必须保留新增账本、Outbox和审计，不用上线前备份覆盖新交易。
