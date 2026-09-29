# 刷新协议探针短时失败定位与修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 查清反复 `PROTOCOL_PROBE_FAILED` 的短时失响应根因，针对证实的故障层修复，同时保持无效刷新令牌必须返回 `401/REFRESH_TOKEN_INVALID` 的协议门禁。

**Architecture:** 先给现有合成探针、网关和 API 建立去敏的同轮时间线，再在隔离环境一次只注入一种延迟或故障，凭可重复的因果证据选择最小修复。业务认证、媒体、Redis、数据库与告警策略分开验收；未证实故障层之前不改超时、重试、告警阈值或生产镜像。

**Tech Stack:** Python 3、`urllib`、systemd/journald、FastAPI/ASGI、SQLAlchemy、Redis、S3 SDK、Docker、pytest、PowerShell 7；生产发布遵循现有双角色镜像门禁与跳板工作流。

---

## 现有证据及不能越过的结论

权威现场报告：[刷新协议探针反复告警：只读生产排查](../../verification/2026-09-29-refresh-watch-protocol-probe.md)。它是 2026-09-29 04:51 UTC 前的快照；执行本计划时须重新冻结当前监视器 SHA、API/Worker 镜像、Compose、schema、网关配置与容器状态，不能把快照当作实时生产事实。

| 观察 | 结论 |
| --- | --- |
| 09-25 00:00 至 09-29 05:00 UTC 共 5,930 轮，`PROTOCOL_PROBE_FAILED` 10 轮、`MONITOR_CHECK_FAILED` 2 轮 | 反复、短时，不是持续故障。 |
| 最近四轮网关固定探针为 499、0 响应字节，下一轮为预期 401；03:01 的 service 约运行 11 秒 | 探针客户端在上游未及时响应时关闭连接，符合监视器 10 秒 socket 超时。499 本身不能指出上游哪一层阻塞。 |
| 03:01 附近两次数据库 readiness 同为 499、头像一次 503，API 一段时间无完成请求，随后恢复；无 API/网关重启或 OOM | 问题超出“无效令牌处理返回错误码”这一条路径；这些并发症状尚不能证明数据库、Redis 或 S3 是根因。 |
| 更早的 502、连接拒绝及无网关记录的轮次具有不同特征 | 分开归类；尤其已记录的 API 切换期间 502 不应硬并入最近四轮。 |
| 现网使用 S3；`api/profile.py` 的 async 头像路由同步执行 `storage.read_signed`，S3 读取可能含 15 秒读超时和最多三次尝试 | 这是可检验的事件循环占用假设，不是已证实的生产根因；缺请求开始、S3 操作起止、进程/线程及资源时间线。 |
| `core/database.py` 的现有 `connection_wait_ms=None` 是明确的 unsupported；`media_storage_metrics.py` 仅保存有限窗口的完成操作汇总 | 不能把 SQL 执行耗时误称为连接等待，也不能从现有存储汇总倒推出某个故障时刻的开始时间。 |

监视器只接受 `401` 加 `error.code=REFRESH_TOKEN_INVALID`；`scripts/refresh_watchdog.py` 当前把大多数 HTTP/网络失败压成布尔 `False`。连续异常可每 300 秒再报，恢复后下一次单轮失败会再发新事件。`service exit 0` 只说明通知流程未报错，`SMTP_ACCEPTED` 只证明 SMTP 接受。用户提供的事件 UUID 无法从已清除的状态中独立追溯到某一轮，不用它作跨层关联凭证。

## 文件边界与实施授权

本文件目前只是方案；起草阶段不改应用、监视器、网关或生产。执行时先阅读根 `AGENTS.md`、[后台生产工作流](../../runbooks/admin-production-workflow.md)、[移动交付工作流](../../runbooks/mobile-delivery-workflow.md)、[续期门禁手册](../../runbooks/refresh-release-guards.md)及本报告，并按阶段分配互斥文件所有权。拟议文件责任：

- `scripts/refresh_watchdog.py` 与 `tests/infra/test_refresh_release_guards.py`：合成探针失败分类、耗时、随机关联 ID、去敏日志和现有单轮告警语义。
- `services/business-api/app/core/tracing.py` 与 `tests/business_api/test_tracing_metrics.py`：仅在必要时补充有界的探针到达/结束事实；沿用 `core/network_request_timeline.py` 的 UUIDv4 校验与非阻塞、有限容量约束，不记录请求体、令牌或原始 URL。
- `services/business-api/app/integrations/media_storage_metrics.py`、`tests/business_api/media_platform/test_media_domain_core.py`：仅当 S3 假设需要时补足固定标签的开始/结束/错误类别。`api/profile.py` 与 `tests/business_api/identity/test_profile_api.py` 只在证实头像路径占用事件循环后作为最小修复候选。
- `services/business-api/app/core/database.py`、`core/rate_limits.py`、相关测试只在相应数据库/Redis 假设获证实时修改。数据库连接池等待仍为 unsupported，除非提供可验证的真实测量方法。
- 网关配置的受控源路径尚未在报告中证实。先只读确认来源及当前 SHA；未找到仓库受控源时，不直接改生产临时文件。
- 执行记录另建 `docs/workflow/tasks/2026-09-29-refresh-watch-protocol-probe-repair.md` 与 `docs/verification/2026-09-29-refresh-watch-protocol-probe-repair.md`，写每阶段时间、源码/镜像身份、红绿与线上去敏证据。临时材料仅入 `docs/verification/artifacts/2026-09-29/`。

所有终端命令使用 `pwsh.exe`，会话先设置控制台输入/输出及管道 UTF-8 无 BOM；Python 设 `PYTHONUTF8=1` 与 `PYTHONIOENCODING=utf-8`。只用既有跳板和严格主机密钥/TLS 校验。合成无效令牌不得替换成真实用户令牌；不得打印请求体、凭据、邮箱、IP、对象键、SQL、私有环境值或未脱敏日志。

## Task 1：重新冻结现场，并把症状分层

- [ ] **Step 1：只读采集。** 经 `scripts/starchat-server.ps1 -Action Command` 确认 timer/service 结果、监视器字节 SHA、当前 API/Worker 不可变镜像、受控 Compose SHA、schema、网关与 API 运行/重启时间。只读取去敏状态字段与固定探针窗口的聚合结果；记录命令退出码和 UTC 起止。环境变量只核“配置存在及允许枚举/数值范围”，不输出值。
- [ ] **Step 2：按轮建表。** 对报告中的 499、502、无网关记录三类分别列“监视器开始/结束、网关响应/`request_time`/`upstream_*_time`、API 是否接收/结束、readiness、头像/媒体、PostgreSQL/Redis、CPU/内存/I/O/重启”。缺字段标记“未观察到”，不得把日志空白写成组件健康。
- [ ] **Step 3：给出单一待证假设。** 最新四轮先检验“两个 API worker 的事件循环或上游依赖在相同 10 秒窗口受阻”；早期 502 另检验部署/网关连接变化。若无法从现有日志判别，进入 Task 2；不能据头像 503 直接调 S3 timeout，也不能据 readiness 499 直接调 DB pool。

**阶段门禁：** 记录能明确说明哪个边界“已到达、开始、结束、失败”，并列出缺失的时间戳与资源指标。无此证据不执行修复任务。

## Task 2：先红后绿加入最小去敏诊断

- [ ] **Step 1：监视器 RED。** 在 `tests/infra/test_refresh_release_guards.py` 加表驱动用例，分别模拟正常 401/指定错误码、401 非法 JSON、非 401 HTTP、超时、TLS、DNS/连接错误；要求独立的固定失败类别、HTTP 状态（若收到）、UTC 起止/单调耗时、UUIDv4 关联 ID，并断言序列化结果不含固定无效令牌、响应体、原始 URL、异常字符串及任意测试秘密。现行布尔接口和 malformed-401 分支应按预期使新测试 RED；后者现在会在 `HTTPError` 处理支路的 JSON 解析处抛出，可能变成 `MONITOR_CHECK_FAILED`，与 499 主因区分记录。
- [ ] **Step 2：监视器 GREEN。** 保留原探针 HTTP 语义、10 秒期限、禁重定向、`reasons` 阈值、事件 ID/恢复/退避规则；仅把单轮观察结构化，输出固定字段的有界 journal 摘要。发出的 `X-ChatFlow-Request-Id` 用本仓库 `valid_request_id` 接受的随机 UUIDv4；不记录响应正文与异常文本。任何探针异常仍使本轮告警，不得被诊断代码吞掉。比较修复前后当前测试的 alert/recovery/delivery 行为。
- [ ] **Step 3：跨层 RED。** 在 `tests/business_api/test_tracing_metrics.py` 为带合法探针 UUID 的固定 `POST /api/v1/auth/refresh?starchat_probe=1` 写测试：即使处理未完成，也应有不含令牌/URL/参数的“API 已接收”事实；完成或取消后应有同 ID、固定路由模板、耗时、状态/终止类别。普通刷新请求、伪造/不合法 ID 不得产生新探针日志；队列满时不得阻塞请求或增长内存。
- [ ] **Step 4：跨层 GREEN。** 优先复用现有 `NetworkRequestTimelineSink` 的受限队列/校验模式，单独给这个固定合成路由记开始与结束；现有 request latency/timeline 只在请求完成时提供事实，不能把“未完成”推断为“未进入 API”。若网关缺同 ID/固定探针的去敏 `request_time` 与 `upstream_*_time`，先确认其受控源及私有轮换/保留方式，再对配置写专门测试与审查。
- [ ] **Step 5：仅补缺口。** 当前存储指标已提供无对象标识的操作类别/耗时汇总。若无法定位是否有跨越 10 秒的 `s3 get`，再加固定操作类别、随机本地操作 ID、PID、UTC 开始/结束及固定错误类别的有界事件；不记录 bucket、key、区域、异常消息或媒体内容。数据库观测分别记录 pool 快照、真实 SQL 执行和已证实可测的连接获取阶段；Redis 只记固定操作类别和耗时，禁记键。为每项新增字段写敏感值缺席、容量与并发测试。
- [ ] **Step 6：聚焦验证。** 先见新增测试因缺诊断而失败，再运行 `python -m pytest tests/infra/test_refresh_release_guards.py tests/business_api/test_tracing_metrics.py tests/business_api/test_performance_snapshot_api.py -q`。根据实际改动补头像、媒体、数据库、Redis 测试；运行 `pwsh -NoProfile -File scripts/verify.ps1` 前检查 Python/Node/PG/Worker 环境，按工作流复用未变输入的等价既有证据。记录红绿命令、退出码与源码 SHA。

**阶段门禁：** 三层时间线可在隔离环境以同一个合法随机 ID 对齐；日志结构为封闭字段、数量有界、无真实令牌/业务数据，且探针 401 合同与告警规则未变化。仪表发布需单独受控评审，不等于根因修复。

## Task 3：隔离复现，逐个排除竞争假设

- [ ] **Step 1：准备隔离栈。** 以当次已发布镜像/配置创建不连生产 DB、Redis、S3、SMTP 的测试栈，使用合成账号/对象与隔离 PostgreSQL；匹配当前 API worker 数和网关 10 秒观察窗口。禁止在生产对真实用户、资金、短信、邮件或对象库做故障注入。
- [ ] **Step 2：基线控制。** 记录 100 次正常合成无效令牌都为 `401/REFRESH_TOKEN_INVALID`，readiness 正常，三层 ID/时间线齐全。现有刷新路由对同一 IP 与令牌有 60 次/60 秒限流：压测使用彼此独立的合成令牌，或在隔离栈明确重置限流桶；同时让生产形状的固定无效令牌按每分钟一轮跨时间窗运行至少两轮，证明真实探针节奏仍得 401。合法的 429 不得被误判为协议失败；固定探针仍不进入真实用户刷新失败率。
- [ ] **Step 3：一次一变量注入。** 分别让假的 S3 `get` 跨过 10 秒、让隔离 DB 连接获取延迟/池耗尽、让隔离 Redis 限流操作变慢、让网关上游短暂不可达或执行受控 API 切换。每次均并发发送固定探针和 readiness，采集 499/502/503、响应时间、API 进入/完成、存储/DB/Redis 开始与结束、worker 资源；恢复环境后再测下一项。S3 分支要验证真实头像调用链 `async read_avatar → sync read_signed → S3 get`，不能用一个没有接上路由的假客户端作证。
- [ ] **Step 4：选择可证伪假设。** 要宣布某层为本次根因，必须同时有：与最新四轮一致的跨层时间顺序、隔离环境相同故障指纹、移除单个注入后恢复、其他假设未提供更强解释。若仅能复现代码脆弱性而缺生产关联，则登记为独立稳健性缺口，不写“已修复此次事故”。不同模式的早期 502 独立结案。

**阶段门禁：** 附去敏逐轮表、可重复命令/输入 SHA 与红绿日志；若证据仍不闭合，继续定点观测，停止猜测性代码修改。

## Task 4：仅对已证实的层做最小修复

- [ ] **Step 1：为选中的单一因果链写失败回归。** S3 事件循环占用成立时，在 `tests/business_api/identity/test_profile_api.py` 注入受控慢 `get`，同时验证刷新探针与 readiness 不被同 worker 饿死，并保持头像签名、当前对象授权、缓存/Referrer 头及 404/503 语义。只有 DB 连接获取/Redis 调用成立时，分别在 `tests/business_api/test_database.py` 或 `tests/business_api/identity/test_rate_limits.py` 注入该依赖延迟，验证相同隔离结果。只有网关/切换成立时，修受控配置/切换顺序和对应 infra 测试，不改身份业务。
- [ ] **Step 2：实施一处最小变更。** S3 分支才考虑把同步头像读取移出 ASGI 事件循环并设置有界并发/超时，保留现有授权与错误映射；DB 分支才考虑实测 pool 容量/等待与 Postgres 预算；Redis 分支才调整真实慢调用的执行与期限；网关分支才修改已冻结的上游/切换配置。每一分支需要具体证据与独立小补丁，不能把这些备选项一并应用。单纯延长探针 10 秒、增加盲目重试或改为返回 200 都不是此阶段修复。
- [ ] **Step 3：复现红→绿。** 用 Task 3 同一隔离注入、相同两 worker/网关配置和三层时间线验证故障指纹消失；保留其他注入的失败可见性。重新跑续期协议 401/轮换/撤销、头像权限、健康、媒体/存储和相关全量套件。任何认证/RBAC/TOTP 或刷新协议语义变更须先有获批 ADR、领域与质量/安全复审；本计划本身不授权这类变更。

## Task 5：受控发布、观察与回退

- [ ] **Step 1：审查与冻结。** 按[后台生产工作流](../../runbooks/admin-production-workflow.md)对具体补丁做规格、领域和独立质量/安全评审；刷新当次生产 SHA/镜像/Compose/schema/其他容器，冻结最小 payload、探针脚本、网关配置及回退。API/Worker 最终候选和兼容回退均经[角色化续期镜像门禁](../../runbooks/refresh-release-guards.md)的 API 9 / Worker 8 检查；无业务迁移时明确记录 schema 不变。
- [ ] **Step 2：分段上线。** 先仅安装已复核的低开销诊断并观察新一轮故障；取得根因和隔离红绿后再发布修复。每次分别保留私有 0700 备份、文件 0600、不可变 SHA、禁网隔离验证、静态/其他服务不变、服务器与工作站严格 TLS 的合成 401/JSON、readiness、API/Worker 健康及去敏日志。邮件验证不得反复发送；`SMTP_ACCEPTED` 仍不作为收件箱证明。
- [ ] **Step 3：失败立即停。** 任何 SHA/Compose/镜像漂移、协议门禁失败、401 JSON 变化、真实刷新回归、额外容器变化或错误率上升，先停止切换；按冻结的兼容镜像/受控脚本回退 API 或恢复监视器/网关文件，保留诊断私有快照，不碰用户会话或生产财务状态。回退也执行双角色门禁与严格 TLS 复核。
- [ ] **Step 4：判定效果。** 以“同一故障注入在隔离栈 RED→GREEN、线上可关联时间线支持相同瓶颈解除”为技术修复证据。上线后至少覆盖多个原事件间隔并复核每分钟监视状态、499/502 分布及真实刷新 2xx/401/422/5xx；该故障过去仅 10/5930 轮，短时没有新告警不能单独证明根治。记录产品侧真实会话验收是否取得；没有授权测试账号就保留此限制。

## Task 6：证据成熟后才讨论告警策略

- [ ] **Step 1：用诊断类别分开统计。** 协议错误（错误状态/JSON）与运输层超时、上游切换、监视器自身执行失败分别比较频率、时长与用户影响；验证恢复通知只表示状态转换/SMTP 接受。
- [ ] **Step 2：保留保护边界。** 在根因未证实和修复未验证前，单轮 `PROTOCOL_PROBE_FAILED`、300 秒同因再报、固定无效令牌 401 合同均保持。若证据支持区分短暂网络波动，可另起经安全审查的监控策略变更，红测确保真实协议不兼容仍立刻报警、监控执行失败不可被平滑掉；变更认证/RBAC/TOTP/刷新协议或降低受保护安全检查时先走相应 ADR 批准。策略调优不能替代服务端根因修复。

## 计划验收

- 可用固定 UUIDv4、UTC、单调耗时解释一次 499 从监视器到网关、API 与慢依赖的到达/完成关系；缺失字段明示为未知。
- 被选根因在隔离环境可重复 RED，单一修复后 GREEN；其余独立故障仍告警，真实刷新协议与 API/Worker 镜像门禁保持通过。
- 全部新增观测有容量/隐私负测；发布、回退、严格 TLS 和监视告警证据有确切 SHA/退出码。若证据达不到上述条件，输出调查结论和下一条观测需求，不宣称 PROTOCOL_PROBE_FAILED 已修复。
