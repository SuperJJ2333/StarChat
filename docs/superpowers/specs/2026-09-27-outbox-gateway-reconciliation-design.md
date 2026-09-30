# Outbox 内部发布与配置模板同步修复

用户2026-09-27明确要求修复持续死信与配置漂移。本设计恢复既有内部事件发布和已生效的网关契约，按既有生产授权执行；不新增金融操作或鉴权政策。

## O01：真实内部接收

固定生产worker镜像0e011134…、实际导入路径和0090数据库身份。只读调查确认21个源码topic、9个注册topic；11个缺消费者的内部审计topic为 `admin`、`friendship.events`、`identity`、`identity.staff`、`identity.wallet_access`、`ledger`、`moments`、`moments.events`、`recharge`、`wallet`、`wallet.incident`。持续新增主体为 `manual_reserve.published` 与 `wallet.funding_scan_discovered`。业务事实与原审计已在生产者事务内完成，消费不得再执行入账、转换、储备发布或钱包扫描。

新增内部发布接收器，严格验证事件信封、固定topic和公开生产者事件契约，使用公共AuditWriter接口持久化追加回执。回执只保存版本、topic、event_type及完整信封的确定性SHA256；原payload仍在Outbox，不复制到审计回执或日志。回执ID由事件ID确定性派生，重试只接受完全一致的既有回执；冲突、非法信封和持久化失败不得确认成功。成功后沿Worker原有租约确认路径标记PUBLISHED；PUBLISHED只代表内部耐久接收。

不同topic承担不同交付：原9个真实handler保持；`wallet.alert`独立SMTP/回执/交接保持；`notification`包含公告分发命令，当前事件数0，不属于内部审计接收器，不以审计回执冒充通知。朋友圈通知已由业务服务同事务写MomentNotification，好友请求/关系也由公共接口读取业务持久记录。未知topic和不支持的事件继续显式失败、告警，不用空handler或关闭reaper掩盖。

## O02：恢复和并发

租约丢失、确认丢失或消费者并发均最多一条内部回执；既有回执的全部稳定字段及摘要必须匹配。使用既有audit_events主键，不新增数据库表、迁移或金融状态写。公共接口封装audit表操作，Worker不得直接跨模块写表。历史DEAD保持原事件与原失败信息，不重设PENDING、不重放资金/未知事件/wallet.alert；新回执不得冒称历史外部投递成功。

测试覆盖生产者→真实Outbox→Worker→AuditWriter→PUBLISHED、失ACK重领、非法/不支持契约、摘要冲突、数据库失败、真实PostgreSQL并发及未知topic继续DEAD。验证账本/钱包状态及原审计保持。

## G01：模板恢复唯一真源

服务器nginx模板缺现网12行登录broker/鉴权拦截；服务器homeserver模板缺现网MobileLoginModule（config为空）。MAIN模板已有正确声明。最小同步两份模板和相关回归测试，必要时只调整安全块位置以匹配现网既有顺序。不得改login broker、16k登录体限制、120s代理超时、register/refresh/sso/cas/saml2/oidc与/_synapse/client拒绝、/_synapse/admin隐藏规则。

生产先在0700私有目录渲染候选并做完整配置对比。秘密值不出站；所有Synapse配置、模块、S3 provider、TURN五条及worker/Element配置保持语义等价。nginx按安全块确切位置核验，不随意忽略regex优先级。保留原配置权限、inode、私有备份；语义不变不重启Synapse。运行 `render_config --check --require-production` 应真正退出0，不能放宽漂移或生产守卫。

## R01：发布基线

另一任务正在发布API；以当次实际镜像/配置为准。本任务Outbox只更新worker及其实际依赖源码，保持API最新功能、PHONE、S3、其它服务与schema。先规格/领域审查，再质量安全审查；聚焦测试后执行预检通过的verify门禁。上线后观察跨过10分钟reaper宽限窗口的真实新事件，核对有耐久回执且无新增对应缺消费者死信；不凭进程healthy就认定解决。
