# 服务端移动登录续期恢复已上线

## 结论

用户明确授权恢复后，2026-09-24 04:56 +08:00切换API/worker。恢复0.4.6及后续客户端operation_id兼容及同操作重试保护。当前协议探针不再422，切换后有界日志观察到2次自然业务续期200。用户朋友圈/钱包/资料页面仍需实际复验，不把合成无效令牌401当作成功登录。

## 源码、范围与批准

沿用已批准且完成设计领域/质量安全审查的ADR0080；本次先进行候选领域规格审查，再质量安全审查，均通过。生产原API8ca2962190f2、workerbdf21c309d89；现网294项Python/迁移/依赖文件身份冻结，只更改app/api/identity.py、app/modules/identity/models.py、app/modules/identity/tokens.py。

以实时生产源码为基底，仅提取主目录既有批准实现中的MobileRefreshRequest、两列模型映射、rotate及其两个helper。保留其他接口及管理员策略，不整文件替换为main，不混入手机注册/客服历史差异。数据库0087已有可空operation_hash/result_key_version，无迁移、无用户令牌清理、不复活已撤销会话。

同一operation重复返回同一刷新值，不延长子令牌期限；不同/缺失operation重放仍撤销；退出/封禁/设备撤销优先；子令牌推进后409不撤销新会话。管理员模型不放行operation，48小时绝对期限不变；移动15分钟/60天不变。

## 验证证据

目录：`docs/verification/artifacts/2026-09-24/refresh-restore/`（原主工作树的忽略归档，不随 Git 交付）。

- RED真实生产源码：44失败/1通过，包括34个刷新相关缺失行为及10个既有Matrix错误分类差异。本次不包含后者，保留记录不宣称完整ADR历史差异都修复。
- GREEN候选63通过/10明确排除Matrix范围，15.84秒；额外identity API回归8通过，32秒，共71项。
- 真实候选镜像+隔离PostgreSQL：7组证明通过（4并发重试仅一个子令牌、不延长期限、子结果推进、不同/缺失operation重用、先前撤销原因保留、父过期子有效、旧协议）。只在隔离恢复库独立schema创建测试用户，测试schema已删除。
- 生产备份恢复136表/223354行，前后既有行摘要一致；数据库schema仍0087。既有迁移镜像目录缺历史文件，本次无迁移，不冒称迁移升级通过。
- 仓库/部署策略通过。按移动交付影响复用规则复用既有ADR实现及未修改模块证据，重跑实际部署候选认证/API与PG门禁；本轮未重复完整37分钟后端verify，不声称脚本全量exit0。
- 规格后安全审查独立复算294文件哈希和AST：TokenService旧方法仅rotate变化，新增两helper，其他方法保持生产基线。

## 发布与现场

- API `sha256:38ed2becf2b9f75a3d0dd46e51188c84c638092c57ffa002de6b2118b9165e59`。
- Worker `sha256:237162bea8f8b8f8e662daa35ed585b17ee16922fde2eec97ff478892f7860b4`。
- 服务器证据与私密配置/备份：`/opt/starchat/releases/refresh-restore-20260924`（私有目录）。候选和运行源码全量身份一致，环境不变；两服务healthy/restarts0/新异常0，其他22容器ID及启动时间未变。
- 双侧正常TLS `/api/v1/health/ready` 200且database ready。工作站经既有jumper的临时loopback SOCKS，结束已关闭自己创建的隧道。
- 公网合成无效刷新值+合法operation：现在401 REFRESH_TOKEN_INVALID，表明进入令牌验证，而非旧422参数拒绝。未登录moments/feed仍401 AUTH_REQUIRED。
- 切换后自然流量refresh200计2次；另外refresh401一次、feed401一次分别来自本轮明确无效/未登录探针。观察窗口有限，不宣称所有用户已复验。
- 未发布APK/官网/iOS；未清设备数据或改变财务业务状态。

## 恢复与后续门禁

本次成功镜像记录于`compatible-recovery-images.json`，作为后续兼容恢复基线。旧镜像是事故前态，会重新造成422，只保留作启动失败时恢复服务可用性的紧急取证快照，不是正常兼容回退目标。沿用发布工具的manifest内部字段名rollback_compatible/同名日志表示旧镜像源码身份核对，不表示其支持operation_id；以本说明及本次成功镜像为准。未执行紧急回退。

完整payload/生成脚本/294文件manifest保存在本报告证据目录；主目录批准源码本来已包含恢复实现，未覆盖其他任务源码。后续发布必须对实际候选运行模型及HTTP协议探针，不能只凭main测试或schema水位认定运行镜像兼容。

下一步用户回到App前台，等待既有自动续期退避后重试朋友圈/钱包/资料；无需重新安装0.4.6。曾因其他原因已撤销的会话不由本修复复活。
