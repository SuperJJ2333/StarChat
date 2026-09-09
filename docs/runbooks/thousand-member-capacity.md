# 千人加密群容量验证

**状态：真实媒体集成及200/500VU HTTP同步测试已执行。200档六轮通过；500档首轮两路径失败、预热后四轮通过，未判定稳定达标。尚无1000成员E2EE验收。见[实测报告](../verification/2026-09-10-media-capacity-runtime.md)。**

依据 [ADR-0060](../adr/0060-content-addressed-media-dedup.md) 与 [实施计划 Task 8](../superpowers/plans/2026-09-09-content-addressed-media-thousand-member.md)。本手册只授权隔离本机验证，不包含生产部署、生产压测或改变 Megolm 轮换。Windows Docker/WSL曾因 `0x800705aa` 无法启动，本轮临时限制WSL资源后已恢复并完成测试；实际结果以实测报告为准，脚本回归通过不代表容量达标。

## 验证层级

| 层级 | 工具与输出 | 能证明什么 | 不能证明什么 |
|---|---|---|---|
| 离线工具合同 | `pytest tests/infra/test_capacity_loadtest.py`，Node 执行纯 JS 状态机；本机 HTTP 仿真服务器 | 目标保护、独立账号、since/timeout、只发送提供的加密事件、集成测试驱动器请求流程 | Synapse/PostgreSQL 行为、真实 k6 执行、服务器性能 |
| 实际媒体集成 | `capacity.py media --flag-off`，`media-result.json` | 两个用户同 MXC、独立引用删除、最后引用删除后重传复用、8 并发同 MXC、隔离、关开关兼容 | Matrix 消息解密；完整保留期后的物理回收 |
| HTTP 容量 | 固定 `grafana/k6:0.54.0`，`summary.json`、`resources.jsonl` | 初始/增量同步、入群、可选密文事件提交及事件 ID 收到情况、资源用量 | Megolm 会话建立/分享、消息解密、密钥恢复、已读 UI 或真实移动端耗电 |
| 真实 E2EE 与千人成员 | 后续授权的隔离 SDK/移动端会话队列及真实终端 | 新老客户端解密、跨房间媒体复用、缺钥恢复、真实入群/发送/接收正确性 | 不能由前面三个层级代替 |

`sync` 模式不发送聊天消息。`transport` 模式只重放测试人员提供的 `m.room.encrypted` 正文，既不构造明文房间消息，也不生成或上传房间密钥。重放同一密文可能被真正客户端视为重复或不可解密，因此只能作为 HTTP 传输负载，不能作为 E2EE 成功率。测试账号虽然加入加密房间，bootstrap 不上传设备密钥、不建立 Megolm 会话。

## 隔离环境与固定版本

使用 [独立 Compose](../../scripts/loadtest/compose.isolated.yml)，不要与仓库根 Compose 合并：

- Synapse main/worker 均为 `starchat/synapse:v1.132.0-dedup.1`，从仓库 `third_party/synapse/Dockerfile` 构建；上游基础镜像由版本和 SHA-256 digest 固定。
- PostgreSQL `16.9-alpine`（`max_connections=250`），Redis `7.4.2-alpine`，nginx `1.27.5-alpine`，k6 `0.54.0`。
- 每次 `prepare` 创建随机 Compose project/run ID；数据库、签名身份、共享注册密钥、媒体和账号凭据都放在指定 `docs/verification/artifacts/...` 子目录，不读取生产 `.env`，不挂载根目录 `data/`。
- 后端和k6仅连接 `internal: true` 网络；两个nginx网关另接独立ingress网络，允许宿主端口发布。只发布 `127.0.0.1:18008`（worker 路由）和 `127.0.0.1:18009`（main 基线）。隔离 worker 容器端口为 `8081`，不单独发布宿主端口。根部署的 worker 宿主默认 `18081` 可通过 `SYNAPSE_SYNC_HTTP_PORT` 设置，不要误用原 bot 的 `8081`。
- Synapse 1.132 使用 `instance_map.main: {host: synapse, port: 9093}`；不能使用已废弃并被该版拒绝的 `worker_replication_host`/`worker_replication_http_port`。
- 与实施配置一致：main `cp_max=30`、worker `cp_max=15`、独立 Redis、presence 关闭、每房间邀请 `50/s`/`1200 burst`。不调整 Megolm 轮换。
- host 工具只接受 loopback HTTP origin；k6 仅额外接受隔离网络中四个固定服务名。所有请求禁用 HTTP 重定向；Python 禁用环境代理。发送凭据前必须通过带随机 run ID 的 `/_capacity/identity` 探针。

`compose.env`、`admin.json`、`accounts.json`、`synapse/` 和提供的密文 fixture 都属于本次运行的私有工件，不能提交、贴入聊天或放入公开证据包。POSIX 文件尝试设置 `0600`，Windows 依赖所在目录 ACL；不要把 `chmod` 当成 Windows ACL 证明。可分享的证据为脱敏汇总、资源指标和工具测试结果，不能打包整个 run 目录。停止命令保留原始数据，以便先整理脱敏证据后再按明确目录清理。

## 先运行 2 VU 冒烟与媒体生命周期

在仓库根目录启动 PowerShell 7。先检查 Docker 引擎可用、两个 loopback 端口空闲和磁盘/内存余量。建议独立测试主机至少 16 GB 内存；当前约 5 GB 可用内存环境不适合作为 500 VU 容量基准。不要为启动测试停止或删除生产/现有服务。

```powershell
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$capacityRun = 'docs/verification/artifacts/2026-09-09/media-dedup-implementation/capacity-smoke'

py -3.12 scripts/loadtest/capacity.py prepare --run-dir $capacityRun
py -3.12 scripts/loadtest/capacity.py up --run-dir $capacityRun
py -3.12 scripts/loadtest/capacity.py bootstrap --run-dir $capacityRun --accounts 2
py -3.12 scripts/loadtest/capacity.py media --run-dir $capacityRun --flag-off
py -3.12 scripts/loadtest/capacity.py run --run-dir $capacityRun --vus 2 --ramp 5s --hold 20s
py -3.12 scripts/loadtest/capacity.py down --run-dir $capacityRun
```

**每条命令成功（`$LASTEXITCODE -eq 0`）后再执行下一条。** 不要整段无条件运行。`up` 的镜像构建/服务启动与后续测试均可能因环境失败；失败必须记录为失败或未运行。`down` 只停止指定标记 project，不删除任何卷或数据目录。

`prepare` 拒绝覆盖非空目录，后续命令检查 `isolation.json` 与 `compose.env` 的 project、run ID 和数据路径一致。bootstrap 不覆盖已有凭据；中断后保留部分进度，另建干净运行目录，不能把部分账号数量写成完整准备成功。

媒体测试上传的是运行时生成的 4096 字节不透明数据，不是真实用户附件，也不伪称已建立 E2EE 会话。测试会逻辑删除这两个隔离账号的媒体引用、隔离一个 fixture；不能对复用真实账号的环境执行。`--flag-off` 会依次重建本测试 project 的 main、worker、两个 nginx 网关并最终恢复开关；重建网关是为了刷新 nginx 缓存的上游容器 IP。媒体测试和 k6 不要同时运行。

## 200–500 VU HTTP 基线比较

冒烟通过后停止小规模 stack，创建新的运行目录并 bootstrap 500 个独立账号。上限固定为 500，脚本不提供任意公网目标或 1000 VU 的绕过开关。

```powershell
$capacityRun = 'docs/verification/artifacts/2026-09-09/media-dedup-implementation/capacity-500'
py -3.12 scripts/loadtest/capacity.py prepare --run-dir $capacityRun
py -3.12 scripts/loadtest/capacity.py up --run-dir $capacityRun
py -3.12 scripts/loadtest/capacity.py bootstrap --run-dir $capacityRun --accounts 500

py -3.12 scripts/loadtest/capacity.py run --run-dir $capacityRun --route baseline --vus 200 --hold 2m
py -3.12 scripts/loadtest/capacity.py run --run-dir $capacityRun --route worker --vus 200 --hold 2m
py -3.12 scripts/loadtest/capacity.py run --run-dir $capacityRun --route baseline --vus 500 --hold 2m
py -3.12 scripts/loadtest/capacity.py run --run-dir $capacityRun --route worker --vus 500 --hold 2m
```

仍然逐条检查退出码；200 VU 发生失效、持续排队、OOM 或数据库连接耗尽时先停止并诊断，不继续升到 500。每档至少重复三次，并交错 baseline/worker 顺序，记录是否暖缓存和负载发生器是否与服务争用 CPU。必要时拉长稳定阶段至 10 分钟；单阶段上限 30 分钟。

两个端点使用相同 nginx 配置，只有 `/sync`、`/events` 的 r0/v3 路由目标不同。此基线表示**同一个 Redis/worker 拓扑中走 main 的同步路径**，不是声称还原历史单进程部署。各 VU 在首轮加入独立 membership 房间；runner 在重复运行前检查并离开这个合成房间，使下一轮再次测量真实入群。主要加密测试房间始终保持加入。

同步第一轮 `timeout=0`，以后 `timeout=30000` 并始终携带上一轮 `next_batch` 作为 `since`。失败不推进 token；每个 VU 固定对应自己的账号，不以取模共享 access token。响应只检查并统计元数据，不打印消息正文、token 或密钥。默认 `sync` 模式测量加密房间成员的同步/入群负载，**没有聊天密文发送量，不是活跃千人群的替代物**。

### 加入密文传输负载

准备来自该隔离服务器、对应测试用户/房间的加密事件正文 JSON 数组。每个记录只含：

| 字段 | 要求 |
|---|---|
| `user_id` | 必须匹配一个当前 VU 的隔离用户 |
| `room_id` | 必须匹配该用户的主要测试房间 |
| `content.algorithm` | `m.megolm.v1.aes-sha2` |
| `content.sender_key`、`device_id`、`session_id` | 该加密事件的公开信封标识，非私钥 |
| `content.ciphertext` | 已生成的加密事件；禁止提供明文 `body`、密钥或任何额外 content 字段 |

每个参与发送的用户至少一个 fixture。fixture 内不得包含 access token；账号 token 从私有 `accounts.json` 独立读取。不要用真实业务房间的记录。SDK 建钥/加密的生成过程需要另行执行并记录，k6 不会代办。

```powershell
py -3.12 scripts/loadtest/capacity.py run --run-dir $capacityRun --route worker --vus 200 --mode transport --fixtures "$capacityRun/isolated-encrypted-events.json" --hold 2m
```

直接运行 k6 时，可从 `CAPACITY_ACCOUNTS_JSON` / `CAPACITY_ACCOUNTS_FILE` 和 `CAPACITY_EVENTS_JSON` / `CAPACITY_EVENTS_FILE` 读取数据；优先使用本测试目录内的文件，避免把 token 放进 shell 历史或命令参数。正常使用 Python runner 已设置这些文件路径和隔离探针参数。`CAPACITY_RUN_ID` 标识隔离服务器，跨运行保持不变；`CAPACITY_LOAD_ID` 标识一次负载调用，由 runner 每次随机生成，直接调用 k6 时也必须为每次运行提供新的值。发送事务 ID 使用 load ID、VU 和迭代编号；同次运行的重试保留原事务 ID，baseline/worker 调用不会复用旧事件。发送成功后同步失败的重试只把同一事件计入一次 `transport_events_sent`。

bootstrap 准备阶段对 HTTP 429 按 `retry_after_ms` 等待，每个请求最多重试 12 次且等待预算不超过 120 秒，结果记录重试次数和等待毫秒数。该等待不属于测量时段。保留 Synapse 默认每房间入群限流（1 次/秒、突发 10 次）；准备 200–500 个成员可能需要数分钟。测量阶段的 k6 不执行这个准备重试：入群 429 会计入 `membership_success` 失败、HTTP 状态 429 和操作错误。应分开报告准入拒绝与已接受请求的服务延迟，不能把默认限流拒绝直接解释为服务器容量耗尽，也不能为了通过阈值静默放宽主配置。

`prepare` 在运行目录创建 `.gitignore`，忽略除该文件自身以外的全部运行数据。账号、签名材料、Compose 环境文件和数据库仍是私有临时数据；忽略规则不替代文件权限，也不授权上传或归档原始目录。

## 指标与证据判读

每次运行生成一个 `baseline|worker-mode-vus-UTC-load-ID/` 子目录，汇总记录隔离 run ID 与本次 load ID：

- `summary.json`：k6 原生指标及运行范围声明；`sync_success`、`membership_success`、`send_success`；`transport_events_sent/received`、`own_events_observed`、`transport_delivery_errors`、`limited_timelines`。
- `resources.jsonl`：约每 5 秒采样该 Compose project 容器 CPU、内存、网络、块设备 IO；采样失败显式记录，缺样不能填写“资源正常”。
- `run-result.json`：k6 退出状态。阈值成功也必须检查 `unobserved_at_end`；它包括结束时尚未确认的事件，不能忽略或称为消息全部送达。

默认阈值：sync 成功率超过 99%，操作错误为 0；密文提交 p95 小于 3 秒，入群 p95 小于 5 秒，三轮同步后仍未观察到自己的事件计入 transport delivery error。`/sync` 包含故意等待的 30 秒长轮询，**不能把整体 HTTP p95 与 3 秒发送阈值直接比较**。需分别记录初始同步、增量同步、发送和入群延迟，并解释空闲等待与实际追赶延迟。

对每次有效运行填写下表，并链接原始脱敏汇总：

| 时间/版本/主机 | 路由 | 模式/VU | sync 成功率 | 初始/增量同步 p95 | 发送/入群 p95 | 发出/观察/未观察 | main/worker/PG/Redis CPU/峰值内存 | 有限时间线/错误 |
|---|---|---|---|---|---|---|---|---|
| 本机实测见上述报告 | baseline/worker | sync，200/500 | 按轮次记录 | 按轮次记录 | 无密文发送 | 无密文发送 | 报告含采样峰值 | 保留失败轮次 |

同时记录宿主 CPU、RAM、Docker/WSL 内存上限、磁盘类型、镜像 digest、运行时长、warm/cold、设备/账号数。同机 k6 争用资源时结论只适用于该测试机。HTTP 仿真单元测试只能列为工具验证；不要把其请求数或完成时间填进这张容量表。

## 后续 1000 成员真实 E2EE 方案

本阶段需新的明确授权和充足的独立测试资源。首先通过 200/500 VU 的三次稳定阶段并解释所有错误；由评审修改当前 500 上限及相应测试后，才准备 1000 个独立 SDK 身份。不能只把环境变量改成 1000 后声称测试完成。

1. 用真实 Matrix SDK 创建并上传每台设备的身份/一次性密钥，按产品验证策略完成设备信任，在非联邦加密房间加入 1000 成员；保留默认 Megolm 轮换。
2. 分别测量建房、批量邀请/入群、首次同步和稳定同步；先从 100、200、500 梯度推进，再到 1000，保留每阶段 CPU、RSS、数据库池等待、Redis 和网络指标。
3. 由多个成员创建真实不同消息，所有接收者执行 Megolm 解密并按本地测试序号对账。记录密文收到数、成功解密数、缺钥/重复/失序/重试数，不能用“收到事件 ID”替代解密成功。
4. 交叉验证同字节图片/视频/语音在不同用户/房间的媒体上传 MXC、正文及缩略图内容摘要、热缓存零下载、冷缓存信封校验、损坏重取、转发不重新压缩及随机开关回退。服务端证据只含密文摘要/引用计数，不导出明文摘要或密钥。
5. 用 Android/iOS 真机及至少一个旧版客户端验证标准 v2 附件读取、重启后的缓存、视频直读、缺钥恢复/离线重连、成员退出/重新入群。独立记录端侧内存和耗电；旧客户端可读不能只凭字段结构推断。
6. 只有 HTTP、E2EE 与端侧指标分别达到事先约定 SLO，领域与质量安全复核均通过后，才能记录“千人成员验证通过”。生产部署仍需另行授权。

## 回退与环境受阻记录

本地停止使用 `capacity.py down`，数据保留在已验证的 artifact 目录。若只回退媒体功能，关闭 `CHATFLOW_MEDIA_DEDUP` 并保留补丁镜像的引用管理；禁止换成忽略引用模型的旧镜像做清理。worker 路由回退到 main 后再停 worker；主进程仍使用 Redis 时不能先停 Redis。

Docker 无法启动、WSL 内存不足、镜像拉取/构建失败或 k6 未运行时，保存命令退出码、日期、脱敏错误、可用资源和已经通过的离线测试。容量表继续保留“尚未实测”，不要虚构吞吐量、百分位或成功率。

Docker 命令执行前会按 DOCKER_CONTEXT、DOCKER_HOST、当前 context 的优先级读取有效端点，仅允许本机 Unix socket 或 Windows 本机命名管道。SSH 与全部 TCP 端点（包括回环 TCP）均拒绝；不得通过切换远程 context 运行本工具。每次 Compose 与 stats 命令显式传入已验证的 --host，并移除继承的 context/host/TLS 参数。本机 daemon 不可用仍返回失败，不自动选择其他 daemon。
