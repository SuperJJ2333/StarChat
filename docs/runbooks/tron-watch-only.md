# TRON真实只读观察器

该独立服务只观察USDT链上转账，不连接业务数据库、不分配充值地址、不签名或广播、不自动入账。现有钱包生产资金关闭规则不改变。用户2026-09-07确认尚无签名设备和双审批人员，当前只实施只读监控和隔离验证。

## 配置和运行

使用`infra/compose/docker-compose.tron-watch.yml`单独项目`starchat-tron-watch`，不得把该覆盖混入生产主Compose。运行镜像固定已验收的Python依赖镜像ID，新观察模块以经SHA256验证的只读目录挂载。网络与业务服务隔离、无监听端口、无Docker socket、无主数据库凭据，非root、只读根文件系统。

运行环境包括`TRON_WATCH_ADDRESS`、`TRON_WATCH_START_MS`、`TRON_WATCH_IMAGE`、`TRON_WATCH_SOURCE_DIR`、`TRON_WATCH_DATA_DIR`及可选`TRON_WATCH_API_KEY`。真实地址及API Key只放服务器0600配置文件，不进入源码、测试、命令日志。数据目录0700由容器UID10001拥有。

每30秒处理一个有界窗口，初始回补近30天。`TRON_WATCH_BATCH_DAYS`默认1天，可设置1至30天；本次确认近30天仅2条记录后设置30天以一次回补，单次读取仍受60秒总时限、页数和交易数上限保护。水位落后时属于追赶历史，尚未到当前时间不能称实时覆盖。历史之外的流水不在覆盖范围。事件保存固化交易真实日志位置和整数最小单位，USDT显示按六位小数转换。历史入库和新发现分别标记，旧记录不是当前新出款告警。

失败窗口不推进水位。启动后重新读取SQLite进度、重叠回扫并去重；相同事件ID出现不同内容则报告冲突，不覆盖证据。数据库仅观察记录，不是用户余额账本。

## 状态解释

`status.json`为脱敏运行摘要，容器健康检查要求最近120秒内成功扫描；`caught_up`单独表示遍历水位距离当前时间不超过120秒。`watermark_kind=SOURCE_TRAVERSAL`是该数据源已遍历范围，不保证索引器从未遗漏或迟报。摘要中的`external_notification_delivery=false`明确尚未配置外部通知。数据库中的异常记录与Docker日志不等于已通知值班人员。完整地址及精确余额只保存在受限观察数据库，不输出到状态摘要或Docker日志。

所有未关联授权的转出记为`UNMATCHED_OUTFLOW`；它表示需要核查，不直接认定盗窃。单来源API数据只适用于观察，不能充当独立双源最终性或钱包控制权证明。

余额由固化状态`balanceOf`查询。若扫描窗口与前后余额截点无法严格对应，输出`RECONCILIATION_UNVERIFIED`而非虚报对账成功。`SOURCE_MATCHED`仅表示同一来源、稳定对齐截点之间余额变化与已观察净流水一致；不是完整历史、独立双源或用户账本对账证明。不得以当前余额减去部分历史流水推出未经证实的初始余额。

## 运维

### 诊断日志（2026-09-08）

观察器、人工钱包 API 和 Worker 使用 JSON 诊断日志，标准级别为 ERROR、WARNING、INFO、DEBUG。配置 `WALLET_DIAGNOSTIC_LOG_LEVEL`，默认 INFO；修改后按实际服务 Compose 叠加列表重建对应容器。非法级别拒绝启动。仅临时对这些组件启用 DEBUG，不打开 httpx/httpcore 的原始请求日志；排查结束恢复 INFO。

日志字段包含 UTC timestamp、service、component、event、reason_code、trace_id；请求附带 request_id、固定阶段 stage、HTTP 状态及耗时。固化数据检查记录 observation_id、区块/观察/心跳年龄及阈值。扫描结果以 run_id/observation_id 关联观察库；事故日志以 incident_id/event_id 关联后台和邮件通知。查到事故后按 trace_id 找同轮监控，再按 observation_id 找观察器轮次和请求失败原因。

例如 `READ_TIMEOUT` 表示读取上游响应超时；`HTTP_RATE_LIMITED` 表示 429；`INVALID_JSON` 表示响应解析失败；`SOLID_HEAD_STALE` 配合 solid_head_age_ms 和 freshness_limit_ms 说明具体过期程度。UNKNOWN 仍表示代码没有足够证据确认底层原因，不代表已诊断为网络故障。

在服务器使用 `docker logs --since 30m starchat-tron-watch-tron-watch-1`、`docker logs --since 30m starchat-business-worker-1` 和 `docker logs --since 30m starchat-business-api-1` 读取近期日志（诊断写入 stderr，重定向时同时处理 stderr）。INFO 不含每个成功请求的细节；DEBUG 也不输出请求体、响应体、凭据、完整地址或金额。

轮转上限为每容器 20m × 10，容量保留不等于固定天数。重建前在服务器运行发布目录内的 `python3 wallet_diagnostic_archive.py`，只归档 schema_version=1 的脱敏诊断到 `/opt/starchat/diagnostic-archives/`（目录 0700，文件 0600）；旧的原始日志不纳入导出。运行 `python3 wallet_diagnostic_archive.py --prune` 删除本工具生成且超过 14 天的归档，操作不会触及观察库。此为明确执行的维护命令，并未创建定时任务。

此发布的服务器目录为 `/opt/starchat/releases/wallet-diagnostics-20260908/`；受限目录内保存实际叠加配置、原镜像和回滚脚本。`python3 deploy_release.py --rollback` 还原本次应用镜像和观察器代码挂载，继续保留新增的日志容量上限；不回滚数据库或资金状态。回滚前也会归档诊断日志。

服务器发布目录`/opt/starchat/releases/tron-watch-20260907/`。状态检查只读取`data/status.json`；不要把完整数据库或watch.env打印或下载。停止只执行本项目`docker compose ... stop tron-watch`，保留data，不影响主业务服务。恢复时仍使用原始开始时间和地址，不重置数据库或覆盖已绑定监控身份。

后续增加第二独立数据源和外部通知，应分别验证数据一致性和实际送达；不能把TronGrid的两个不同接口当两家独立来源。正式专属地址充值需控制权/恢复证据、双源固化核验、可审计地址绑定和唯一入账键。真实归集提现需独立签名设备、两位审批人、生产限额、紧急禁签和小额真实验收。
