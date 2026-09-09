# 真实媒体集成与容量测试结果（2026-09-10）

**结论：真实媒体集成通过；200VU HTTP同步六轮全通过；500VU首次升档两条路径均失败，预热后四轮通过，不能判定500档稳定达标，更不能据此宣称千人E2EE群验收通过。**

用户要求继续执行真实容器集成与容量实测；沿用[ADR-0060](../adr/0060-content-addressed-media-dedup.md)和已批准计划，仅在本机隔离环境操作，无生产部署。

## 真实媒体集成

固定Synapse1.132.0补丁镜像实际构建成功，主进程、worker、PostgreSQL16.9、Redis7.4.2实际健康启动。通过标准HTTP接口验证：跨用户相同MXC、独立引用删除、最后引用删除后保留复用、8路并发相同MXC、隔离后拒绝重传。关闭去重开关后新上传分别存储、旧共享媒体可读、隔离仍执行；测试最终恢复开关。

证据：[media-fixed.log](artifacts/2026-09-10/media-capacity-runtime/media-fixed.log)。上传为随机不透明测试字节；未据此声称Megolm解密或7天后物理回收验证完成。

## 容量结果

200用户集中入群场景：200/200加入成功，2075/2075同步成功，operation_errors=0，首次同步p95=13.591秒，退出0。没有出现原先根据配置猜测的准入拒绝。500账号准备阶段发生233次限流重试、累计退避71867ms，两者分别记录。

2VU冒烟真实k6退出0。随后预先入群的200/500VU、baseline/worker各三轮，合计12轮，稳定期每轮2分钟。逐轮结果如下：

| VU | 路径 | 轮次 | 同步成功/总数 | 首次同步 p95(s) | 增量同步 p95(s) | 阈值结果 |
|---|---|---|---|---|---|---|
| 200 | baseline | 1 | 1060/1060 | 20.951 | 30.842 | PASS |
| 200 | worker | 1 | 1048/1048 | 22.967 | 30.809 | PASS |
| 200 | worker | 2 | 1144/1144 | 4.868 | 30.505 | PASS |
| 200 | baseline | 2 | 1127/1127 | 5.912 | 30.772 | PASS |
| 200 | baseline | 3 | 1190/1190 | 0.399 | 30.023 | PASS |
| 200 | worker | 3 | 1193/1193 | 0.527 | 30.057 | PASS |
| 500 | baseline | 1 | 2232/2728 | 34.960 | 34.921 | FAIL |
| 500 | worker | 1 | 2291/2637 | 34.963 | 34.557 | FAIL |
| 500 | worker | 2 | 2575/2575 | 16.553 | 32.000 | PASS |
| 500 | baseline | 2 | 2607/2607 | 15.575 | 31.959 | PASS |
| 500 | baseline | 3 | 2601/2601 | 14.217 | 31.646 | PASS |
| 500 | worker | 3 | 2671/2671 | 11.542 | 31.536 | PASS |

PASS指现有HTTP成功/错误阈值通过（sync_success>99%、operation_errors=0等），本脚本没有设置首次/增量sync延迟SLO。p95包含失败尝试以及升档、hold、收尾阶段的全部请求，不是纯稳定阶段统计。

增量同步设置timeout=30000，正常空闲长轮询本身接近30秒；该列不能当作消息送达延迟。首轮500档初始和增量请求接近35秒客户端截止时间，k6记录request timeout，Synapse记录客户端断开后无法返回响应。baseline失败496次、worker失败346次，原始失败未覆盖；两次自动停止后，经诊断仅继续同参数预热重复实验，没有提高超时、降低阈值或增加VU。后续resume退出0不改变这两轮FAIL。

首次升档与预热结果差异明显。采样显示数据库和同步进程在首次同步阶段有高CPU，无OOM/重启、未出现明显swap使用。CPU竞争、全成员状态同步与缓存行为是待profile验证的瓶颈方向，现有采样不足以证明唯一根因。不能仅根据这些对比把性能变化归因于worker。

## 方法与适用范围

- 宿主Ryzen5 9600X、32GB RAM，WSL临时4GB内存/4虚拟CPU/2GB swap；Windows D盘bind mount存储。同机k6、其他桌面任务和两个既存自动启动容器共享资源，非独占生产基准。
- 原WSL默认配置创建VM报0x800705aa，所有发行版停止。临时资源上限后WSL与Docker29.2.1启动成功；原本不存在.wslconfig，测试结束后核对内容并移除，恢复文件原状。未重启整个WSL或停止其他容器；当前VM配额在下次重启才重新读取。
- 500个独立账号，主房间501名成员含管理员，辅助准入房间201名成员。前200账号加入两个房间，其余300账号加入主房间。保存私有accounts-admission.json，只移除可选join_room_id操作生成prejoined-sync输入，不修改服务器限流或房间状态。
- 每轮10秒升档、2分钟hold、10秒降档，允许在途长轮询收尾；baseline/worker顺序交错，使用相同账号、房间状态和非懒加载成员的同步过滤器，各轮独立load ID。首轮不是经清库/清OS缓存的严格冷启动基准。
- 仅测HTTP初始/增量sync，不发送聊天消息，不建立/验证设备密钥或Megolm会话。初始timeline受limit=100截断，limited_timelines有记录；k6不回填历史，不能据成功HTTP率推导消息完整送达、端侧体验或活跃群消息扇出容量。
- 六个服务每轮均有资源样本，缺样错误为0；资源采样不包含k6容器峰值，亦非连续profiling。

| 服务 | 采样 CPU 峰值(%) | 采样内存峰值(MiB) |
|---|---|---|
| gateway-baseline | 16.19 | 17.97 |
| gateway-worker | 11.21 | 18.32 |
| matrix-redis | 5.13 | 9.54 |
| postgres | 299.85 | 190.40 |
| synapse | 112.24 | 506.30 |
| synapse-sync-worker | 116.34 | 428.70 |

## 本轮修复与回归

1. Docker29仅internal网络导致网关HostConfig有绑定、实际NetworkSettings.Ports为空；仅网关增加ingress网络，后端/k6仍internal，宿主只发布loopback。配置回归先红后绿。
2. 真实并发暴露Synapse分布式锁通知/SQL释放间竞争导致长退避；每HomeServer增加本地Linearizer排队，再取原分布式锁。跨进程互斥未移除，本地等待峰值回归8→1，随后真实8路并发通过。领域后质量安全顺序复核通过。
3. 两条nginx路径补X-Forwarded-Proto，消除协议缺失警告。
4. k6 0.54真实编译拒绝逻辑赋值/可选链语法，改为兼容等价表达式；实际冒烟和12轮负载执行验证。增加独立初始/增量耗时Trend，红绿回归通过。

本轮infra回归102项通过，容量脚本18项通过。最终完整仓库门禁：运行中，最终状态待追加，[原始输出](artifacts/2026-09-10/media-capacity-runtime/verify-full-runtime.txt)。Flutter应用本轮未修改，上轮1396项Flutter与静态分析结果不冒充本轮重跑。

## 证据与清理

本次所有隔离测试容器已停止、网络已移除，数据库和私有输入保留在被.gitignore排除的run目录；其他容器未停止。临时WSL配置文件恢复原状，见[cleanup.json](artifacts/2026-09-10/media-capacity-runtime/cleanup.json)。

- [逐轮脱敏指标与资源汇总](artifacts/2026-09-10/media-capacity-runtime/capacity-summary.json)
- [原始k6关键指标与执行退出码](artifacts/2026-09-10/media-capacity-runtime/steady-results.json)
- [过滤后的镜像/网络/环境证据](artifacts/2026-09-10/media-capacity-runtime/environment.json)

run目录含账号令牌、临时注册秘密、签名身份和数据库，禁止提交或发布整个目录。当前缺口仍包括首次大批量同步性能优化、活跃消息收发/端侧真实E2EE以及后续1000成员独立集群验收；不据本轮结果部署生产。
