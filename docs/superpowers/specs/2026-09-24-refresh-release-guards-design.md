# 续期协议发布门禁与异常告警设计

用户已选定并授权三项：最终镜像协议测试、兼容回退限制、续期异常报警。沿用ADR0080，不改变令牌或鉴权政策。复用现有隔离worktree codex/refresh-restore。

1. 最终镜像测试：固定sha256镜像，在无网络、无生产配置/挂载、只读根文件系统、独立临时SQLite的容器中调用真实ASGI接口。覆盖登录、新版续期、同操作重试、错误操作重用、旧版请求、失效访问令牌后续期、退出严格请求模型、管理员令牌不能用于移动续期，以及管理员cookie/CSRF入口边界。报告只含检查名与镜像摘要。
2. 发布/回退同一门禁：新统一guard检查所有目标镜像，全部通过才允许Compose切换；按摘要固定最终Compose，禁止标签竞态。现用生产release.py的deploy与rollback入口接入检查，不允许只查健康或手工提供通过标记。root直接执行docker仍可绕过，文档明确这是运维流程边界，不能声称限制宿主机root。
3. 每分钟systemd检查五分钟窗口，仅解析固定auth/refresh路由的HTTP状态，不持久化原始日志。422>=3、5xx>=3、请求>=10且非2xx比例>=20%进入告警；网络/协议探针失败、日志截断、容器/检查异常也告警。五分钟内同类告警去重，恢复通知；状态原子写0600，日志有界并脱敏。公开接口只用合成无效令牌验证合法operation返回401且错误码正确，不生成生产会话。由monotonic周期重跑，不当作长效真实用户端到端监控。
4. 用户后续指定查看backend报警邮件，复用business-worker已有SMTP及BUSINESS_WALLET_ALERT_RECIPIENT。密码和收件地址只在worker内读取，复用既有SMTP配置校验；强制TLS、证书校验与超时，独立续期主题，仅发送原因码与事件ID。失败保留同一待发事件并有界退避重试；单待发事件期间合并最新状态，送达后通知恢复。SMTP接受不等于收件箱确认。监控自身异常经systemd OnFailure尝试同一通道，SMTP不可用时保留服务器状态供运维检查。

文件所有权root：scripts/business_refresh_image_probe.py、business_release_guard.py、refresh_watchdog.py、refresh_alert_email.py、install_refresh_watchdog.py，tests/infra/test_refresh_release_guards.py，以及计划/运行手册/任务。临时证据仅命名目录。先RED再GREEN，先规格审查后质量安全审查，实际好/坏镜像与服务器告警演练后交付。
