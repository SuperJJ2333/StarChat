# 请求失败细类与服务端时间线

## 字段与范围

已登录客户端的现有诊断接口可带 `network_requests`。仅当前业务 API 同源请求参与，诊断上传自身除外。每次实际发送生成独立 UUIDv4，401 刷新与重放各有新 ID；父操作 ID、审计 trace ID 分开。随机请求 ID 标识一次请求，不能用于统计用户或区分模拟器、真机。

错误细类固定为 `timeout`、`socket`、`tls`、`http_transport`、`aborted`、`unexpected`、`http_5xx`。阶段为 `awaiting_headers`、`reading_body`、`response_complete`、`unknown`。共享 HTTP 接口不能准确拆分 DNS/TCP；SocketException 也不能直接证明 DNS 失败。

记录版本/build、平台、网络类型、固定接口类别、HTTP 方法、UTC 开始时间和单调耗时。已观察到响应头时才带响应头耗时与状态码。超时可带预算和回调迟到量；迟到量不能单独证明 UI 卡顿。无账号、设备标识、手机号/邮箱、IP、URL/查询、请求或响应正文、原始异常/堆栈、凭证。

当前与跨版本保留队列合计最多64条；每次至多8条新记录、20条事件/操作/请求、16384字节。原有重试和30秒网络持久化节奏保持。202确认本次不可变ID，失败保留ID；422仅撤掉新扩展后按原节奏重试旧渠道。账号范围和 generation 阻止旧回调污染新会话。

## 服务端边界

`server_request_timeline` 记录注册的静态路由模板及响应头准备、最终响应体准备、最终ASGI send返回的单调耗时。仅已准备响应头才带状态。取消/异常与完整发送分开；完整ASGI send不证明手机收到响应。

请求线程只校验并入队，不写stdout。独立惰性daemon消费队列，最多1024条、每worker每分钟600条；退出有限等待。丢弃计数为累计值，不同worker/重启不能相加。既有接收端鉴权、账号/来源限流和日志轮转保留。

## 安全采集

先按[生产工作流](admin-production-workflow.md)读取当次 API 容器/镜像及日志保留范围。原始日志留服务器；下面工具经既有jumper在服务器过滤，再导出闭合字段。工具导入纯 DTO，不启动应用或日志线程。不要将原始日志、环境、数据库或私人请求路径下载到本地。

```powershell
py -3.12 scripts/collect_network_request_diagnostics.py --container starchat-business-api-1 --since-hours 24 --tail 100000 --output docs/verification/artifacts/2026-09-27/network-failure-diagnostics/collector/live.json
py -3.12 scripts/network_request_report.py docs/verification/artifacts/2026-09-27/network-failure-diagnostics/collector/live.json --output docs/verification/artifacts/2026-09-27/network-failure-diagnostics/collector/report.json
```

导出不含路由模板，只保留固定接口类别。总上限20000条/16MiB；每原始行上限64KiB。非法记录、过大行、截断、导出上限、丢弃计数与重复ID冲突均保留覆盖缺口。工具默认不声称日志保留已核实。缺服务端记录时原因仍是未知，不能判成DNS或断网。

关联只用同一请求 UUID，不相减设备与服务器墙钟。报告区分客户端超时但服务端完成、服务端取消/异常、单边记录。服务端处理超过客户端预算是观察结果，不能直接当作唯一根因。历史无ID摘要不能补造关联；测试 fixture 必须与生产采集分开统计。

## 版本与发布

新字段需同时有新客户端和兼容 API。旧 API 的422回退已验证。新候选仅三个诊断文件，无迁移，保留当次live的PHONE/S3；不包含本地尚未发布的启动诊断接口。生产发布按[职责第6条](app-release-deployment.md)取得具体候选授权，再重读运行配置和容器，禁止覆盖未知漂移。

[设计](../superpowers/specs/2026-09-27-network-failure-diagnostics-design.md) · [任务](../workflow/tasks/2026-09-27-network-failure-diagnostics.md)
