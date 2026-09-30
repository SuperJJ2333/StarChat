# ADR: 不依赖本地会话的 iOS 启动错误诊断

Status: Accepted in scope by user on 2026-09-27; domain/security review findings applied before executable changes, implementation reviews required before release.

## 决策

新增独立闭合元数据接收入口 `/api/v1/startup-diagnostics`，未登录可用。保留既有 `/client-diagnostics` 的认证条件。报告不用于认证、恢复授权或金融状态；不改变 Matrix 本地身份、预检、恢复或清理条件。匿名数据不作为可信身份，不驱动邮件或真实 refresh 成功率。

公开入口只接受有限版本信息、随机事件UUID、固定错误分类、固定操作边界、固定预检cause和限定OSStatus；客户端在首次 await 前具有内存记录能力。独立 HTTP 请求不读取钥匙串、不带任何凭证。有限 app-support 队列和退避为 best effort，不保证联网前、退出前或系统保护下必定上传。

## 约束与后果

- 4KiB请求；20事件/32KiB本地队列；24h TTL；第一次发送前冻结事件内容；最多128个已尝试签名后停止新增。可省略/null的预检cause、限定native status及L01–L08 login_stage仍属闭合枚举，不收集额外身份信息。
- 专用 Redis 原子分钟限流，先全局后来源，TTL 与计数一起设置。来源为明确受信代理链解析后的 ASGI client，应用不自行读取调用方任意 forwarded headers；保留 nginx 追加连接方地址、Uvicorn 从右侧取首个非受信地址及 API 回环绑定，受信内部代理属于特权边界。固定结构去重容量10000/24h，批量清理128项加请求UUID单独过期核验；短租约防止并发重复接受，只有写入安全日志后才确认，失败不落为成功。
- 系统版本获取失败使用unknown。异常包装仅带 typed safe metadata，绝不保留cause对象/原异常文本/堆栈。
- 未知故障上报不能证明或防止根因；需要新 iOS 客户端分发后才可从受影响设备得到新报告，0.4.7 原包不会自动获得代码。
- 无数据库迁移；可回退到旧API，客户端404只保留有界队列并退避，不改变启动/会话结果。
- 用户确认代码方案，不代表批准新的API生产部署、外发通知或iOS分发。

## 审查

独立设计检查已确认现有authenticatedBuilder/session/token限制；发现并修订事件count变异、系统信息阻塞、包装根因丢失、Redis无期限计数/高基数去重问题。完整规格见 [设计](../superpowers/specs/2026-09-27-ios-startup-diagnostics-design.md)；审查与证据在 docs/verification/artifacts/2026-09-27/ios-startup-alerts/。
