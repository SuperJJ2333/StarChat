# 管理后台可读性版本发布

用户于 2026-09-10 明确授权部署。通用规则见 app-release-deployment.md。

- 主机：ssh -J jumper -p 23421 root@207.56.8.8。
- 发布目录：/opt/starchat/releases/admin-readability-20260910/。包含真实运行配置和数据库备份，权限受限，禁止复制整个目录到工作区或输出其中环境配置。
- 范围：4 个只读 API 报表文件、17 个静态文件，名单及 SHA256 见 source/manifest.json。
- 候选 API：sha256:f62cd9d02c402cd6d86058951652c29cf588483f0b8f821ace2e9e3dedc9901f。
- 回退 API：sha256:0d330c6e2172c637b28fca9d788ea511b718af6698cbf904570257dfe6f4a839。
- API 环境、挂载、网络、命令、健康检查和隔离设置从当前容器冻结并比对。Worker、网关及其他容器不重建；数据库保持0059_chat_payment_pin。

## 部署与验收

发布目录内 server_release.py snapshot/build/backup、rehearse.py 和 static_release.py preflight 已执行；不可覆盖初始备份。

最终切换：python3 /opt/starchat/releases/admin-readability-20260910/static_release.py deploy。
该操作重新校验基线，先切换API并等健康，再逐文件原子安装静态文件，admin.html最后安装；异常自动恢复旧静态文件和原API冻结配置。已有浏览器可能需刷新以加载新版模块。

复核：python3 /opt/starchat/releases/admin-readability-20260910/static_release.py verify。
此外核对公网 https://liuhetong888.com/api/v1/health/ready 返回JSON200，未登录管理员接口返回401；静态页面及17个文件内容摘要匹配。禁止把www静态HTML200误当API健康。

## 回退

确认当前容器仍属于本次发布，执行：python3 /opt/starchat/releases/admin-readability-20260910/static_release.py rollback。
恢复已备份的静态文件及旧API；新增加但旧版本不引用的静态文件可以保留。不会回滚数据库、账本、事故、资金控制或移动端发布设置。

旧 reserve-resampling 发布器假定 API 仍为旧镜像；本次发布后不要直接运行旧发布器的部署/回退命令。Worker 独立配置和有界重采样保持有效；需要调整 Worker 时重新核验实际配置。

## 实际发布结果

2026-09-10 已执行并验证成功；生产后台 https://admin.liuhetong888.com/，静态哈希校验也使用该域名。API健康探针仍使用liuhetong888.com。数据库版本未变，API健康且重启计数0，其他容器ID不变。详见 docs/verification/2026-09-10-admin-readability-production.md。
