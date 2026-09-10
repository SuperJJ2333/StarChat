# 钱包页面60分钟验证态实施计划

2026-09-10。用户已确认规格并明确要求修改生产验证逻辑，授权实现与部署。范围仅wallet访问验证缓存，不实施此前其余报表/补入账需求，不改后台48小时登录缓存。

1. 身份领域增加服务端60分钟钱包grant，绑定后台会话/账号/设备/验证配置版本；普通refresh不延长；撤权/退出/换号/凭据变化失效。补只读状态、verify、revoke接口及扩展迁移，保留旧逐次证明兼容且默认关闭feature flag。
2. 管理钱包读写路由统一接入grant；有效grant替代该作用域5分钟近期登录与逐次密码/TOTP，但金融事务提交前继续检验会话、grant、角色、资金控制与证据；身份凭据设置/轮换仍单独验证当前/新秘密。
3. 前端进入USDT页面先验证，不预加载敏感信息；60分钟内重进/刷新/跨标签复用服务端grant，过期隐藏内容并模态验证；密码只用于首次verify且即刻清除；未确认请求不重放。
4. 先red/green与规格审查，再质量安全审查；覆盖5分/59:59/60分、revocation、跨账号、并发/锁等待、所有真实路由、隐私遮罩和无重复写。更新OpenAPI/runbook/evidence；全仓verify。
5. 按app-release-deployment.md基于实际API镜像冻结配置，备份恢复演练、扩展迁移及flag灰度，静态哈希校验；只重建API；不修改资金状态或订单。回退flag关闭+旧API/静态恢复，保留扩展表，不复活失效凭证。

文件归属：身份代理拥有新grant模型/服务/API/migration、wallet_access.py、operation_password.py、admin_wallet_auth.py、config.py及其测试；页面代理拥有admin-api/home/manual-wallet-panel、新钱包access UI、CSS/tests；根协调者拥有其他wallet路由与全局boundary/main集成、ADR/计划/部署与集成验证。代理不得覆盖彼此文件。
