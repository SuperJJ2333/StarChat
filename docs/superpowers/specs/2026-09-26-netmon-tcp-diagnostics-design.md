# TCP443 与 Release 网络诊断补强设计

状态：2026-09-26 用户直接指定方案并授权实施。三项需求本身为本设计批准来源，不重复请求发布已有批准范围。

## 范围与数据流

1. 扩展现有 netmon：服务器侧与大陆阿里云观测点每分钟分别对真实主服务器443执行有界 TCP connect。只记录真实成功/失败、单次连接耗时、样本数/成功率和固定错误类别。TCP握手与DNS/TLS/HTTP检查分开；本探针直接对已确认主IP连接，DNS/TLS阶段不估算。保留现有netmon检查、定时和回退。
2. 公共Business HTTP入口把真实TimeoutException、socket/transport异常及401写入现有ChatDiagnostics，stage为闭集network_request，error复用timeout/network/rejected。异步请求捕获sessionGeneration，旧会话完成不能污染新会话。无业务请求重放或额外业务查询。
3. ChatDiagnostics Release开启现有低频上报；PerformanceMetrics保留其当前profile/diagnostic条件。401和离线的诊断批次保留，有界本地异步暂存并在同账号恢复后补报。record必须同步近O(1)，不做磁盘、网络或JSON编码；持久化在尾随任务中串行处理。

## 安全与边界

诊断继续闭集枚举/数字，禁止异常字符串、请求URL/query、token、原始用户/房间/媒体身份、消息内容或E2EE数据。暂存载荷按大小/数量/TTL限额，损坏载荷安全丢弃；本地拥有者隔离元数据不上传。真实异步存储需要覆盖会话切换、旧写入完成、并发新事件及恢复竞态。401不允许诊断上传触发会话续期/登出。现有422 operations/frames兼容降级保持，不能无条件丢掉整个正常批次。新network_request枚举在服务端同步严格白名单，旧协议继续可用。

## 验收

- 两处每分钟实际TCP成功率/耗时证据、定时无重叠、日志有界、备份回退，业务容器身份不变。
- Timeout/transport/401均计数；恢复后补报成功；离线/401暂存不丢最后写入；会话切换不串线；oversized/corrupt载荷无泄漏。
- Release策略有测试证据；旧diagnostic protocol和privacy/security/schema/limit行为不回归。
- 专项红绿、Flutter analyze及完整Flutter、服务端契约、适用verify门禁和先规格后质量安全独立审查。

客户端新包构建/装机不由本条新增要求自动覆盖之前设备验收；本轮交付明确区分源码、探针定时部署和API接收端部署。Release配置仅在下一次从本源码构建的包生效，不声称旧安装包已经生效。
