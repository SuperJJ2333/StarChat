# iOS 启动诊断：只读收集与解释

此入口只观察终止或阻断启动的错误元数据。方案和代码候选已获实施授权；生产 API 发布、新 iOS 签名分发和外发通知需按各自流程执行。本手册不代表已部署。

## 接收与隐私边界

`POST /api/v1/startup-diagnostics` 独立于 SecureSessionStore、diagnosticSalt、登录及刷新。请求无认证、令牌、cookie、重定向，每次总超时 **5 秒**；诊断失败不改变启动、恢复或密钥判定。现有认证 `/client-diagnostics` 保留认证条件。

报告只有 schema、随机单次 UUID4、UTC 分钟、公开 app_version/build、数字 iOS 版本或 unknown、固定 stage/boundary/category/preflight_cause/native_status/login_stage 和 count。没有稳定账号、安装或设备标识，没有 IP、手机、邮箱、路径、异常文本、堆栈、令牌、密钥、聊天或附件。客户端声明未经认证，不能证明身份或真实原因；未知分类不能被推定为手机锁定。

本地队列上限 **20 个事件 / 32KiB / 24h TTL**，仅固定 app-support 路径；路径或写入不可用时退回内存。首次发送尝试前冻结完整报告（含 count），后续同 UUID 重试不改变内容。本进程同类别/阶段在冻结后抑制重复故障，防止服务端去重掩盖 count 变化。初始化、回前台和有限退避补发，离线、退出、系统保护、限流或损坏队列仍可能延迟或丢失；不保证即时、完整或 exactly-once 送达。

服务端最大请求 **4KiB**，严格拒绝额外字段和非法枚举。Redis 专用原子门禁先限制全局 **120 次/分钟**，再限制受信代理链解析后的 ASGI 来源 **10 次/分钟**；应用不自行解析或信任调用方任意填写的 forwarded headers，不将来源/IP写入诊断日志。当前 API 端口仅绑定回环，nginx 追加实际连接方地址，Uvicorn 在明确的受信代理列表下从右侧选取首个非受信地址；受信内部代理属于特权边界。共享出口可能让多个设备共享一个来源额度，须将该观测缺口保留在结论中。代理配置、绑定地址或信任范围变更时，重新验证伪造及重复 XFF 请求仍共享来源限额。

去重是固定 Redis 结构，最多 **10000 UUID / 24h TTL**；清理过期项后容量仍满则 429。短租约中的重复请求 503，安全日志写入且确认完成后的重复请求 202。依赖或日志失败 503，释放租约或待租约过期重试；Redis失败拒收。日志写入发生在确认之前，确认失败的重试可能产生重复日志，不能承诺 exactly-once。

| 观察 | 解释与下一步 |
| --- | --- |
| 202 / accepted:true / 合法 event_id | 接口接受闭合元数据；不是实际故障根因、可信用户身份或崩溃率证据 |
| 404 | 接口尚未发布或已回退；客户端只保留有界队列并退避，不影响启动结果 |
| 413 / 422 | 请求过大或闭合格式拒绝；不保存/传播原始请求和错误文本 |
| 429 | 全局、共享连接来源或去重容量限制；保留有界重试与覆盖缺口 |
| 503 | 接收依赖、日志、确认或同事件处理中；延迟重试，不当作成功 |
| 无日志 | 可能是留存/扫描限制、404、客户端未分发、离线、保护或丢弃；不能推出没有故障 |

## 本地只读汇总

新工具只读 stdin 或操作者明确提供的本地授权日志文件。它不连接服务器、不探测 API、不读取 session、不修改服务，也不发送邮件。服务器日志获取仍按[生产工作流](admin-production-workflow.md)通过既有跳板执行只读命令；原始日志可能包含敏感内容，不将其写进仓库或上传到证据记录。

```powershell
py -3.12 scripts/collect_startup_diagnostics.py --input C:/authorized/startup.log
py -3.12 scripts/collect_startup_diagnostics.py --input C:/authorized/startup.log --max-lines 20000 --max-events 10000 --max-samples 20 --output docs/verification/artifacts/2026-09-27/ios-startup-alerts/collector/summary.json
```

不提供 `--input` 时读取 stdin，可重复指定最多 16 个明确授权文件。输出默认 stdout；`--output` 只允许 `docs/verification/artifacts/` 下的 `.json`。PowerShell 7 会话先设 UTF-8 无 BOM，Python设 `PYTHONUTF8=1`、`PYTHONIOENCODING=utf-8`。

默认最多扫描 20000 行、总计 16MiB，每行 64KiB；可调上限 100000 行、10000 个唯一事件、100 条闭合样本，默认 20 条样本。超长行的剩余内容消耗同一总字节预算并丢弃，不会被误当成新事件。抵达行数或字节上限保守标为 truncated；唯一事件容量满后的新事件计入 dropped_event_lines。样本省略单独计数，不损失已汇总事件。

工具支持裸 JSON marker、Docker 时间/前缀，以及有界 message/log 包装。只接受 `type=startup_diagnostics` 的闭合 API 格式，拒绝未知字段、重复 JSON 键、非法版本/UUID/时间/枚举、布尔冒充整数；不输出原始行、错误文本、包装来源或 IP。汇总按版本/build、stage、boundary、category、native_status、preflight_cause、L 码分组，只对 UUID 去重后的事件累计 count。同 UUID 内容不同记为 conflicting_duplicate_lines，保留首次内容，不累加被改写的 count。

`measurement_status=validated_metadata_emissions` 表示扫描内有校验通过的日志 marker，`no_validated_metadata_emissions` 表示没有。它不验证服务器身份、不证明 HTTP 确认完成，也不是实际设备故障率。日志留存未知。历史日志校验真实 UTC 分钟格式，允许旧时间；实时 API 仍只接收过去 24h 至未来 5 分钟的报告。

## 当前事故与分发缺口

告警 **cecd31ea-4450-454d-8b47-6b8d8bc57aed** 的只读调查：2026-09-27 Asia/Hong_Kong **14:08** 出现 PROTOCOL_PROBE_FAILED，**14:09** 恢复；调查时 timer active(waiting)/enabled、service 最近退出 0，synthetic refresh 为 401/REFRESH_TOKEN_INVALID。该窗口与 API e880 切换时间相关，现有 watch 缺少失败 HTTP 状态/异常记录，真实原因仍未知；不能据时间相关性认定唯一根因，也不能把当前健康当成历史邮件最终送达证据。见[调查与证据](../workflow/tasks/2026-09-27-ios-startup-diagnostics.md)。

现有 **0.4.7** 签名包没有新埋点。只有新签名 iOS 客户端实际安装到受影响设备后，才能收到该设备的新启动报告；本地代码完成不能修复或证明旧包里的事故原因。匿名报告不自动触发邮件，不计入 refresh-watch 的真实刷新失败率；需要查看 watch 时保持只读，按[生产工作流](admin-production-workflow.md)检查 timer/service 和既有证据。

## 验证与回退

本地门禁：`py -3.12 -m pytest tests/infra/test_startup_diagnostics_collection.py -q`，涵盖脱敏、闭合模式与 API AST 枚举/约束一致性、混合包装、冻结重试去重、扫描/样本容量和 CLI。完整任务门禁及发布授权由[任务记录](../workflow/tasks/2026-09-27-ios-startup-diagnostics.md)管理。

API 回退到已验证旧基线不迁移数据库；新客户端遇 404 继续有界队列/退避。客户端关闭或回退诊断只影响观察能力，不修改会话、Matrix 身份、E2EE、钱包或恢复条件。实际生产切换与回退先按独立候选、基线、漂移检查、授权和证据执行。

关联：[批准设计](../superpowers/specs/2026-09-27-ios-startup-diagnostics-design.md) · [计划](../superpowers/plans/2026-09-27-ios-startup-diagnostics.md) · [ADR](../adr/2026-09-27-preauth-startup-diagnostics.md)。
