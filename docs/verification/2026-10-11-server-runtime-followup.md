# 服务器现场复核与修复依据

> 本文保留2026-10-11修复前的评审/只读快照。后续代码行号和生产状态可能已变；当前实施与发布事实以[可靠性修复任务](../workflow/tasks/2026-10-11-im-reliability-implementation.md)及其精确SHA证据为准。


日期：2026-10-11，UTC+08。用户授权连接服务器访问查看并给出修复方案。本轮继续[九项评审](2026-10-11-e2e-architecture-performance-review.md)，只读生产，不实施修复、重启、配置变更、消息/推送发送、账号操作、压测或清理。

用户已明确：上架审核期间暂不能配置的是**Android厂商推送通道（小米、OPPO、vivo等）**，不是iOS APNs。这项外部条件不再作为“应立即补齐的现行配置缺陷”，而列为审核通过后的接入/验收依赖。其他可靠性修复可以独立开展。

方案见[分阶段修复计划](../superpowers/plans/2026-10-11-im-reliability-remediation.md)。本报告是现场证据，不代表所有风险已复现或全部用户受到影响。

## 1 本轮新增确认：恢复鉴权上游端口错配（SR1 / P1）

**这是首批应修复的明确线上缺陷，与Android厂商审核无关。**

- 现象：Synapse有界日志样本中，`/_synapse/client/chatflow/recovery/v1/status`返回503共3735次，处理耗时集中约305ms。样本约2026-10-10 20:25至10-11 10:02+08，tail40000已截尾；是请求数，不是用户数或最终失败消息数。
- 当前配置：`RecoveryVaultModule.enabled=true`。
- 当前运行源码：[模块第22行](../../third_party/synapse/chatflow_recovery_vault.py:22) 的固定鉴权地址指向`business-api:8000`；当前容器该模块SHA为`6ebcc5bdf0be699660eed77137ae33132a39e8e6c280b10cf3517d42bad599ab`，与工作区相同。
- 网络证据：从当前Synapse容器分别建立两次TCP连接，8000得到`ConnectionRefusedError`，8082连接成功。当前网关业务上游及[Compose健康检查](../../docker-compose.yml:281)使用8082。
- 根因判断：错误端口足以阻断该模块的业务鉴权调用；源码将此类依赖异常映射为503。它是已确认的必要修复点，但不能据此宣称所有3735次响应均只有此一个原因，更不能直接解释全部历史iOS登录等待。
- 影响范围：使用这一恢复状态/鉴权路径的请求；普通已有会话发送、同步并不必然受同样影响。是否阻塞特定客户端登录，需要对应版本的阶段追踪和保数据真机复验。
- 最小方案：纠正到现有业务API的8082端口，增加部署拓扑与鉴权地址一致性测试；保持双重鉴权、撤权复查、限流和fail-closed行为。禁止以跳过鉴权、返回假空状态或重建密钥“恢复成功”。
- 验收：隔离同拓扑环境中合法合成身份可读status；缺失/撤销/错误身份仍拒绝；上游不可用仍503且不会写入。恢复路径与普通收发、保数据升级分别回归。发布前必须完成恢复域规格/领域及质量安全审查，不能仅改线上文件即结案。

证据：[状态路径分类](artifacts/2026-10-11/server-followup/root-log-classification.jsonl)、[模块开关](artifacts/2026-10-11/server-followup/root-recovery-metadata.jsonl)、[运行源码及两端口探测](artifacts/2026-10-11/server-followup/root-recovery-authority.jsonl)。未读取密钥文件、恢复材料、会话密钥或用户消息；没有调用恢复material/enroll接口。

## 2 推送现场：iOS已配置，Android审核限制单列

| 项目 | 当前证据 | 修复/解释 |
| --- | --- | --- |
| 个推生产实现 | main/rate_limit/getui_client/notify四文件SHA与上轮源码一致；限频1500ms、通知TTL300秒 | 跨房通知机会被CID节流跳过的代码风险确实在运行；不能称已实测手机漏响率 |
| 个推最近24小时日志 | 未触及tail上限；push HTTP200共273，4次ConnectTimeout，集中10/11 00:35:55–00:36:30+08 | 现有临时失败→503→协议重试语义应保留；4次可能是重试，不是4条消息永久丢失。HTTP200不等于供应商业务受理/设备显示 |
| Sygnal | 24小时notify HTTP200共424、2次连接相关warning | 日志不能区分足够完整的APNs受理/拒绝与设备结果，不能计算到达率 |
| 普通iOS APNs | 已绑定当前启动配置路径，production=true、sandbox=false；所需配置及keyfile存在 | 不属于Android厂商审核阻断；未验证密钥长期有效性或设备到达 |
| 活跃pusher记录 | Android个推23，iOS APNs10；iOS 10/10配置default声音 | 支持前次“远程默认声音配置已进入服务端注册记录”的判断；pusher条数不等于活跃设备/用户数 |
| iOS身份 | APNs topic匹配源码Bundle，但与10/9最终2213回签AppID后缀不一致，Team比较亦不一致 | 保留N2-1发布信任门禁；不能直接改生产APNs Team/topic去迎合一个未闭环回签包，否则可能破坏旧用户通知 |

当前APNs配置路径由运行入口默认配置、PID1工作目录及配置mtime早于进程启动共同核对，不是运行内存转储。身份比较仅输出布尔，不导出凭据。详见[推送核查与任务细节](artifacts/2026-10-11/server-followup/push-plan-notes.md)。

审核期间优先修复跨房节流、注册绑定恢复、FGS超时/锁状态和iOS后台偏好；OEM资格获批后再接SDK、签名/控制台映射和ROM矩阵。不得靠循环拉起、无限心跳或恢复绕过静音策略的厂商直显替代缺失通道。

## 3 消息与数据库：部分原风险需要降低“当前故障”表述

| 当前观察 | 数值 | 边界 |
| --- | --- | --- |
| Synapse发送已完成请求 | 247次，均HTTP200；P50/P95/P99=116/164/202ms，最大207ms | main tail40000样本，约10/10 20:25–10/11 10:01；只统计已匹配的已完成服务端请求，样本小，不是端到端成功率或正式P99认证 |
| 历史拉取已完成请求 | 704次HTTP200；P50/P95/P99=66/161/200ms，最大256ms | 不包含手机解密、数据库和绘制；与上一轮旧2204数据不是同构对照 |
| sync已完成请求 | worker正常样本主要约30秒 | 包含空闲长轮询等待，不能写成消息需要30秒到达 |
| 业务/Matrix PG瞬时连接 | 22/100、35/250；该次均idle，无当时锁等待 | 只证明采样瞬时；不是高峰容量结论 |
| 最近24小时新Outbox | 5222条全部PUBLISHED、attempt=1；P95≈0.935s/P99≈0.942s、最大≈1.10s | 数据库发布时间差，不代表外部设备到达；当前未被替代的PENDING/FAILED/PROCESSING为0 |
| 历史Outbox | 103235条DEAD均9/30以前；另2条旧wallet.alert PENDING已由handover通知替代且有SMTP回执 | 不能称当前队列堵塞；不能为“清零”批量删除或重放，历史归属和保留策略单独处理 |
| 续期401分类 | 同一网关截尾样本中，带既有`starchat_probe=1`标记的401为652；未标记刷新163次均200 | 与每分钟既有协议探针相符，标记不是来源身份认证。不能将这些401计为真实用户续期失败；API不同窗口另有一致分类支持 |
| API健康 | 实际`/api/v1/health/live`与`/ready`均200，ready数据库就绪 | 误试`/api/v1/health`的404是路径不匹配，非服务故障；ready仅验证DB，不代表全链路健康 |

证据：[Synapse有界延迟](artifacts/2026-10-11/server-followup/root-synapse-latency.jsonl)、[探针/恢复503分类](artifacts/2026-10-11/server-followup/root-log-classification.jsonl)、[数据库和Outbox](artifacts/2026-10-11/server-followup/backend-runtime.json)、[补充查询及健康/pusher](artifacts/2026-10-11/server-followup/backend-runtime-detail.json)。

Synapse延迟解析没有覆盖全部Processed request行（main27724中匹配27544、worker9067中匹配8446），未匹配行保留为缺样，不能从成功分母中隐去。网关和API窗口因tail各不相同，不拼接计算一个总体成功率。原始日志未导出。

## 4 媒体与服务端IO

- 业务API运行S3后端、2个worker；媒体route/service/repository/blob storage文件与已审源码SHA一致。因此V6-2的async路由同步IO风险属于当前运行代码，不只是过期源码。上轮250ms阻塞复现仍是隔离注入，不是本轮生产耗时。
- Synapse配置`max_upload_size=50M`，文件mtime早于当前服务启动；网关Matrix路径100m、业务API路径25m。客户端100MiB选择上限应结合对应服务能力，而不是笼统改成某个网关上限。
- 未授权访问媒体config返回`M_MISSING_TOKEN`，未盗用生产token继续查询；当前会话没有取得客户端实际读取的认证媒体能力响应。应在隔离测试账号联测前置大小校验，保留SDK上传前的最终守卫。
- 建议先做同步IO卸载和边界守卫，之后独立处理持久附件任务、在途内存、续传与流式验证；不要把大规模协议/存储改造绑在首批根因修复中。

证据：[配置及HTTPS只读探测](artifacts/2026-10-11/server-followup/root-routing.jsonl)、[运行源码身份](artifacts/2026-10-11/server-followup/backend-runtime.json)。

## 5 资源、路由和日志（新增SR2 / P2）

- 当前核心镜像与此前快照相同；主要已配置健康检查的服务健康，RestartCount=0、OOMKilled=false只覆盖当前容器状态。没有healthcheck的服务不标记unhealthy。
- 09:57+08主机内存7900MiB、available3789MiB，Swap2042/2047MiB；根盘41%。8秒vmstat后7个间隔中一次swap-in约296KiB/s、其他为0，内存PSI平均为0；不支持持续抖动/正在OOM的结论。检查本身及其他任务可能影响短采样。
- 当前nginx实际配置只有一个sync worker上游和一个主Synapse上游，证实单节点故障域；备份和边缘不等于热备用。先恢复/冗余验证，再按峰值定资源，不立即盲目扩容或重启。
- **SR2：日志轮转不一致。** business API/worker等有20m×10配置；当前Synapse主/worker、gateway等json-file配置未见max-size/max-file。gateway当前单文件约354.2MB、主Synapse约280.1MB、worker约56.5MB（十进制字节换算）；不是马上磁盘满，但长期增长缺少同等边界。
- 方案：给未覆盖核心服务补受版本控制的轮转设置，先在隔离环境验证，再随该服务下一次受控重建生效；禁止直接truncate现有日志或为此同时重启整栈。参考初始预算20MiB×10/服务，按日志增长量和合规留存调整；配置文件改完不等于现存容器已采用。
- 资源治理须确认演练/恢复容器所有权和证据期限，不能擅自停掉其他任务；P2历史死信/归档单独领取任务。

证据：[运行容器、log options及配置](artifacts/2026-10-11/server-followup/root-runtime.jsonl)。

## 6 网络观察的边界

两次最初Python HTTPS探测分别约5.05秒，后续curl对同versions端点3次为36.7–134.5ms；IPv4约38.8–42.7ms、保留TLS验证的loopback约31.0–31.9ms。后续getaddrinfo4.2–57.4ms，未复现5秒停顿；不能据此定罪DNS、IPv6或固定服务延迟，也不能当大陆手机网络表现。现阶段只建议分DNS/TCP/TLS/TTFB埋点和连续观测，不改全局DNS/代理。

证据：[分阶段网络小样本](artifacts/2026-10-11/server-followup/root-network-timing.jsonl)。所有HTTPS保留证书/SNI验证。

## 7 结论与实施顺序

1. 优先闭合SR1恢复端口错配，并继续P0最终iOS包身份核验。两者分别有证据，不应混成一个未经验证的登录根因。
2. 同期可独立修复个推跨房节流、业务媒体同步IO、客户端FGS/锁与pusher恢复；不用等待Android厂商通道。
3. 补iOS远程声音策略、客户端公平发送/历史与媒体峰值/附件恢复、端到端观测；真机证据仍是必要验收。
4. 当前Outbox新事件正常，公平调度/租约改造保留P2；先做有针对性的长topic故障夹具，再决定是否改结构。历史金融相关通知不自动重放。
5. 厂商审核通过后逐厂商接入和灰度；未获批期间该桶标注“暂不可配置/未验收”，不得宣称杀进程到达保障。

本轮完成服务器查看和修复方案所需事实采集。仍缺真实设备最终包、合法测试账号下的端到端关联、ROM/能耗/弱网矩阵、连续峰值观测和当前整栈恢复数据。服务器访问授权不能代替这些数据，也不自动扩大为生产部署或金融/密钥操作授权。
