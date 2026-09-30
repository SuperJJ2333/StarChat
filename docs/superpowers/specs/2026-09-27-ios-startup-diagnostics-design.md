# iOS 启动失败诊断设计（用户已确认）

用户 2026-09-27 确认“按此方案实现”。下述独立审查收紧容量/时限，不扩大数据采集或外发通知范围。

## 目标与现状

用户要求在 iOS 本地会话启动失败时及时向服务器报告，并检查 refresh-watch 告警 cecd31ea-4450-454d-8b47-6b8d8bc57aed。现有 `/api/v1/client-diagnostics` 必须先读取 SecureSessionStore 并带业务访问令牌，ChatDiagnostics 又只在 authenticatedBuilder 内启动；不能覆盖持续的钥匙串/本地会话初始化失败。

本次只增加诊断观察能力，保持本地会话、Matrix 身份、密钥读写及恢复判定不变。不能把未知故障推定为手机锁定；诊断本身不能保证故障不再发生。

## 提议方案

1. 新增独立 `POST /api/v1/startup-diagnostics`，允许未登录的 iOS 客户端提交严格限定的元数据。既有认证诊断接口保留原鉴权。
2. 客户端在本地启动检查、诊断盐读取、安装标识读取、Matrix 只读预检、会话 bootstrap/本地恢复失败处记录闭合枚举；固定 boundary 区分失败操作，并覆盖 matrix_login(L04)/account_storage(L07) 包装边界。只报告终止/阻断错误，安全空壳延迟恢复不会冒充故障。包装异常仅保留安全的错误类别、预检 cause 和允许列表内的 OSStatus，不保留原始异常对象、文本或堆栈。
3. 报告只有：协议版本、随机单次事件 UUID、UTC 分钟、公开 app 版本/build、iOS 系统版本的数字部分、固定 stage/category/cause/native-status、有限发生次数。没有账号/安装/设备标识、手机邮箱、IP 字段、数据库路径、消息、令牌、密钥、附件或自由文本。未认证的客户端声明一律视作不可信观测。
4. 上传独立于 SecureSessionStore、diagnosticSalt 和登录刷新；默认 iOS 启用。在 `main` 初始化早期安装 recorder，诊断 I/O 不参与启动/重试成功判定。每次请求总超时 5 秒，禁止重定向、令牌、cookie 和失败递归上报。
5. 仅将脱敏报告保存到 app-support 本地小队列，最多 20 个事件/32KiB、最长 24 小时；路径解析或写入失败时保留内存队列，不覆盖未成功读取的保留文件。固定同目录临时文件原子替换，拒绝文件链接；允许受信平台支持目录的规范化路径别名。初始化、恢复前台及有限退避时补发。成功接收后删除；同一启动进程、同一失败类别/阶段合并计数，首次发送尝试前即冻结整个事件（包含 count），之后重复故障在本进程抑制，避免同 UUID 计数变化被服务端去重丢掉。已尝试签名最多128项，满后停止新增签名并保留已抑制项；413/422永久拒绝丢弃，其他失败有限重试。离线、系统保护、进程退出仍可能导致延迟或丢失，不能承诺所有失败立即送达。
6. 服务端最大 4KiB/请求，严格拒绝额外字段、自由文本和不合法枚举。专用原子 Redis 门禁先限制全局每分钟 120 次，再限制受信代理链解析后的 ASGI 来源每分钟 10 次；计数+TTL 原子执行，不复用现有分步设置 TTL 的限流器。应用不自行解析或信任调用方任意填写的 forwarded headers；保留当前明确代理信任范围，nginx 追加实际连接方地址，Uvicorn 从右侧选取首个非受信地址，API 端口仅绑定回环。受信内部代理属于特权边界，代理配置变化需重复等价链路的伪造/重复 XFF 限流验证。日志不输出来源/IP；共享出口可能共享来源限额，运行手册明确观测限制。去重固定 Redis 结构最多 10000 个 UUID/24 小时，每次批量清理最多128项并单独核验请求UUID是否过期；清理后容量已满即429，不存在每 UUID 永久新建 Redis 键。接收使用短租约，只有日志写入成功后确认；处理中重复请求503，已确认重复202，依赖/日志故障释放或待租约过期重试。Redis 失败拒绝接收，不放宽限制。只有校验后的元数据进入有界轮转日志；无数据库迁移。
7. 新增只读脱敏汇总工具和运行手册，使运维可按版本/build、阶段及类别检索；测试独立 receiver、客户端序列化及启动故障接线。此类未认证事件不直接触发邮件或参与 refresh-watch 的真实 refresh 失败率，防止伪造报告驱动告警。新增外发通知或生产发布另行按相应流程执行。

## 接口约束

- `schema`: 常量 1；`platform`: 常量 ios；`event_id`: UUID4。
- `app_version`: 数字语义版本，例如 0.4.15；`build`: 正整数，上限 10000000。
- `os_version`: 1–3 段数字，每段最多 3 位，读取失败用 unknown；不采集硬件型号、vendor ID 或完整系统描述，获取系统信息不阻塞记录。
- `occurred_at`: UTC 分钟，校验不得未来超过 5 分钟、不得早于 24 小时。
- `stage`: initialization / installation_check / diagnostic_salt / installation_identity / matrix_preflight / start_application / session_bootstrap / local_restore。
- `boundary`: 固定的 version_load / preferences_load / marker_read / protected_data_probe / container_probe / marker_register / installation_cleanup / reconcile / diagnostic_salt / installation_identity / identity_snapshot / database_presence / database_header / database_identity_read / olm_identity_check / original_identity_search / database_key / database_open / client_migration / application_start / local_identity / matrix_grant / switch_local_clear / matrix_login / matrix_sync / identity_binding / account_storage / matrix_session / local_restore / bootstrap。
- `category`: protected_data / keychain_permission / platform / metadata / database / filesystem / matrix_identity / matrix_credentials / matrix_rejected / matrix_rate_limited / matrix_service / network / unknown。
- `preflight_cause`: 当前 MatrixLocalIdentityCause 的 11 个 camelCase 枚举之一，可省略或 null。
- `native_status`: -25308 / -34018 / -25291 / -25300 / -50 / other，可省略或 null；非null仅限 platform/protected_data/keychain_permission。
- `login_stage`: L01–L08，可省略或null；保留深层 boundary，同时记录 L04/L07 等既有固定阶段编号。
- `count`: 1–100；只在首次发送前合并计数，首次发送后元数据不可变。
- 成功 202，已确认重复也 202；响应仅 {accepted: true, event_id: 合法UUID}；格式拒绝 422、过大 413、限流 429、接收依赖故障/同事件处理中 503。错误响应不反射输入。

## 验收与边界

- 锁定/权限/元数据/数据库故障分别分类；包装异常不丢安全根因，界面文本不泄露信息。
- 未登录和钥匙串读取失败时可发送报告，真实业务 session/token 完全不被读取。
- 报告中任意自由文本/凭证/用户标识被拒绝；本地损坏或旧协议队列丢弃，不读取任意路径。
- 队列、退避、并发、超时、退出以及服务器重复接受行为有明确测试；诊断异常不改变启动结果。
- 现有认证 receiver、账号恢复、E2EE、refresh-watch 状态机不变。
- 执行前完成 ADR/domain 与质量安全审查；完成代码候选、测试、OpenAPI 和回退后，按生产工作流单独请求服务端发布授权。实际 iOS 签名包与受影响真机验收是后续分发门禁，不能宣称现有 0.4.7 已具备埋点。

## 服务器告警初步观察

2026-09-27 06:53–06:56 UTC 只读调查：timer active(waiting)/enabled、service 上次退出 0。06:08:18 UTC 出现一次 PROTOCOL_PROBE_FAILED，06:09:20 UTC 恢复；当前 synthetic refresh 返回 401/REFRESH_TOKEN_INVALID。告警窗口与 API e880 容器切换时间高度吻合，现有 watch 未记录失败 HTTP 状态/异常，不能据此证明唯一根因。当前状态不等于历史邮件最终送达；详见任务证据。
