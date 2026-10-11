# StarChat 双端即时通讯端到端架构与性能评审

> 本文保留2026-10-11修复前的评审/只读快照。后续代码行号和生产状态可能已变；当前实施与发布事实以[可靠性修复任务](../workflow/tasks/2026-10-11-im-reliability-implementation.md)及其精确SHA证据为准。


评审日期：2026-10-11（UTC+08）。结论：当前架构具备持续演进的基础，但尚无证据支持“双端主流设备、弱网及长时间后台均稳定达标”。发布产物身份、Android 后台策略、通知可靠性、客户端历史扫描与媒体处理、服务端阻塞及端到端观测是主要风险。P0 表示应立即闭合的发布/数据安全门禁；P1 表示核心体验或可靠性风险；P2 表示容量、成本和维护优化。风险分级不等于已发生事故。

## 评审范围、证据及限制

- 当前源码：`main`，`5c83a08a09b985146bc507a1608cb2153d361e48`，开始时工作区干净；无 `.codegraph/`，采用定向源码审查。移动端版本配置 `0.4.44+2213`。
- 最新交付记录：Android 2213、iOS 2213；记录与当前设备安装状态不能互相替代。Android 2213 成品记录为 min SDK 24、target SDK 36；iOS 源码最低版本 16.0。iOS 最终回签包与源构建包存在身份和内容差异。
- 当前运行观察：2026-10-11 09:18:59+08，经既有 SSH jumper 只读获取主机资源及容器身份；35 个运行容器。主要服务本次读取 `RestartCount=0`、`OOMKilled=false`。此字段不证明整个历史从无故障。
- 本次没有修改产品、配置或生产数据，没有安装/清数据、发送真实通知或运行生产压测。子审查的离线合成复现与已有真机/模拟器证据分别标识。
- 标识约定：**代码事实**为当前源码可直接确认；**离线复现**为本次隔离/模拟依赖验证；**历史观察**只属于原日期、版本、设备；**待验证风险**为有明确触发路径但未取得真机或生产复现。
- 下文所有“验收”数字均为**建议目标**，不是已测结果或系统保证。没有分母/测量窗口/设备身份的成功率、耗电和百分位保留未知。静音、禁用通知、专注模式和强行停止应分桶报告，不将用户有意禁止提醒计为系统应该突破的限制。

证据入口：[任务记录](../workflow/tasks/2026-10-11-e2e-architecture-review.md)、[生产资源快照](artifacts/2026-10-11/e2e-architecture-review/production-resource-snapshot.txt)、[工作区文件盘点](artifacts/2026-10-11/e2e-architecture-review/workspace-inventory.json)。源码链接中的行号以本次工作区为准。

## 已有能力与不能重复报告的旧问题

1. Matrix 通信域与业务身份、账本/钱包权威分离；端到端加密、金融幂等、审计和 Outbox 边界应保留。不能为提速让服务端接触聊天明文/密钥。
2. 已有缓存优先首页、`waitForFirstSync:false`、有界聊天视图、账号/页面租约保护、离线文本 Outbox、稳定事务 ID 和晚到 ACK 处理。2205 的全历史迁移阻塞已经修复，不能把旧报告直接当当前缺陷。
3. 媒体已有 32 MiB 编码缓存预算、64 MiB Flutter 解码缓存预算、账号 384 MiB/设备 1 GiB 聊天磁盘配额、引用与对象去重、清理世代保护、可见性调度和内存压力响应；这些预算不等于整个进程的内存或所有目录总量。
4. 已有 Android 原生通知去重/房间路由、iOS APNs 与 PushKit/CallKit、Synapse sync worker、Redis、密文媒体 S3 方案和受控发布/回退流程。不能再写成“没有推送、没有缓存、没有监控、媒体全在本地”。
5. 10 月 9 日集成报告记录 Flutter 5758 项通过/9 条件跳过等门禁；它们属于对应输入，不替代本次九方面真机端到端性能认证。

## 现有可量化证据

| 指标/场景 | 已知结果 | 证据边界 |
| --- | --- | --- |
| 10/8 Android 2204 某账号服务端发送 | 61 次 HTTP 200，P95 150 ms，最大 166 ms | 历史约 1 小时窗口；仅服务端请求，非发送到对端显示 |
| 同窗口历史拉取 | 2553 次 HTTP 200，P95 108 ms，最大 188 ms | 不能据此推断手机 SQL/解密/绘制快 |
| 同版本客户端 | 慢框架帧计数 261，最大 595 ms；恢复最大 13.176 s；操作采样丢弃 190 | 旧版现场；无会话总数/全部帧分母，不能算当前卡顿率或OOM率 |
| 10/9 缓存优先原生验证 | 未知百万历史 ID 首次精确 ordinal 约 8.8 s；100 房间/10 个 25 万旧索引恢复约 2.46 s | 模拟器 debug / 特定夹具；不可当 release 真机百分位 |
| 同次快滑 | 30 次重叠 10000 px/s 手势，可见事件偏差 <1 px，窗口 ≤200 UI 模型 | 弱网响应与连续快滑的组合验证仍缺 |
| 同次维护/表情 | debug 最高 build 帧 314 ms/434 ms；动态可见当前帧 589824 bytes | 单个缓存分项并非完整 PSS/native/GPU 峰值 |
| 9/10 容量 | 200 VU 六轮通过；500 VU 首轮两路径失败、预热后四轮通过 | HTTP 同步测试，没有真实千人成员建钥/解密验收 |
| 10/11 主机 | 内存总 7900 MiB/available 3784 MiB；Swap 2043/2047 MiB；盘 83/218 G、41% | PSI avg10/60/300=0；vmstat 后四个 1 秒样本换入/换出=0，不能认定正在内存抖动 |
| 端到端 P50/P95/P99、通知到达率、保活率、能耗、OOM/ANR率、启动命中率 | **当前无法给出可信实测值** | 缺同构测试分母、设备样本、跨端时间关联和持续观测 |

历史来源：[2204 现场调查](../workflow/tasks/2026-10-08-android2204-a1014826460-crash.md)、[缓存优先与快滑验证](2026-10-09-cache-first-fast-history-emoji-recents.md)、[容量手册](../runbooks/thousand-member-capacity.md)、[main 集成](2026-10-09-git-main-integration.md)。

## 1 Android 后台保活

**B1-1 全会话 dataSync 前台服务与系统时限不匹配｜P1｜代码/产物事实，真机退出待验证。**

- 现象/影响：Android15+长时间退后台后可能停止同步服务或触发服务超时异常；后台存活不能靠常驻通知保证。已发布2213的targetSDK为36。
- 证据：[Manifest:103](../../apps/mobile_flutter/android/app/src/main/AndroidManifest.xml:103) 使用flutter_local_notifications服务；[sync_keepalive_service.dart:140](../../apps/mobile_flutter/lib/core/notification/sync_keepalive_service.dart:140) 申请dataSync，`:247/276`每10分钟watchdog；锁定19.4.2插件原生服务没有onTimeout；[成品identity:3](artifacts/2026-10-09/android2213-release/delivery/identity.log:3) 为target36。原生partial wakelock20分钟、Wi-Fi锁无超时，Dart还会把原生获取失败当locksAcquired成功；存在退出释放逻辑，不能说没有释放。
- 根因：有时限的同步任务被用于全会话保活，Dart运行布尔与真实原生状态不一致。Android15+对target35+的dataSync后台累计时长设限，超时须及时stopSelf；Android16的FGS内job也受配额。[官方FGS时限](https://developer.android.com/develop/background-work/services/fgs/timeout)、[FGS版本变化](https://developer.android.com/develop/background-work/services/fgs/changes)
- 复现：测试Android15/16/17安装同SHA包，设置测试设备data_sync_fgs_timeout_duration为60000后登录退后台；记录onTimeout、stopSelf、退出原因和锁释放，再恢复前台。测试后恢复原device_config；另做真实6/24小时长测。未在本轮执行。
- 优化/验收：原生接管超时并回传状态；后台同步有界、持锁有期限，空闲主要依靠合规推送；短配额测试0超时致命异常/ANR、锁释放、恢复前台可继续同步。Doze/白名单/自启动分别测试；用功耗与到达率决定策略，不将删锁等同可靠性保持。

**B1-2 OEM离线通道与v1通知后备尚未闭合｜P1｜代码事实与历史配置缺口。**

- 现象/影响：个推自通道进程被ROM清理/冻结后，厂商离线通知可能无法补位；覆盖国内主要ROM，真实概率未知。
- 证据：[Gradle:122](../../apps/mobile_flutter/android/app/build.gradle.kts:122) 只见基础个推组件；[getui_client.py:48](../../services/getui-bridge/app/getui_client.py:48) v1 transmission直接返回，不走legacy UPS；既有测试明确v1无push_channel。10/3记录小米项目/通道未配置，今天控制台状态未读取，不能外推全部厂商都未配置。
- 根因：v1为保留本地账号/静音策略取消供应商直接展示，但仍依赖进程接收transmission；白名单不能替代OEM通道。未见以WorkManager/JobScheduler作为消息即时通道的实现；缺少这些组件本身不算bug，它们受Doze/配额限制，适合延后补偿任务。[Android Doze/Standby](https://developer.android.com/training/monitoring-device-state/doze-standby)
- 复现：测试账号在各ROM分别Home、清最近任务、系统回收、锁屏30分钟/8小时、重启后发送合成消息，关联供应商受理→设备receive→系统展示→同步；用户force-stop单列，不承诺强行唤醒。
- 优化/验收：逐OEM核验SDK/项目/应用签名/通道证书/控制台并设计与本地偏好一致的后备；不能直接恢复绕过静音的UPS。各桶公布样本、到达率和P50/P95/P99；按统一通知SLO验收，未支持通道明确显示限制。短时心跳、精确Alarm或拉起循环不作为全机型保活方案。

**B1-3 推送注册重检只信本地成功缓存｜P1｜代码事实，远端失效后的恢复风险。**

- 现象/影响：服务端删除pusher后，token未变时本机仍可能显示“已注册”，恢复前台也不补建；双端均涉及。
- 证据：[matrix_pusher_service.dart:139](../../apps/mobile_flutter/lib/features/push/matrix_pusher_service.dart:139) 注册状态来自本地token；[213](../../apps/mobile_flutter/lib/features/push/matrix_pusher_service.dart:213) 相同identity直接返回；[295](../../apps/mobile_flutter/lib/features/push/matrix_pusher_service.dart:295) recheck不读远端。永久拒绝后服务端移除pusher是设计内路径。
- 复现/根因：隔离服务首次注册→删除测试账号远端绑定→保持token/metadata→recheck/resume；验证是否仍显示成功。局部幂等缓存与远端健康混淆，当前生产发生率未知。
- 优化/验收：节流的readback/强制幂等upsert，分开最近写成功与最近远端核验；建议5分钟内或下一次前台恢复时补齐，避免重试风暴；旧账号owner不能删新账号绑定，未知状态如实展示。

本项指标结论：当前**后台存活率、锁屏到达率、功耗和杀进程恢复分位均未知**。普通最近任务划除、LMK、ROM清理与用户force-stop必须分开；存活率不是核心体验的唯一目标。客户端主要消息同步为Matrix HTTP长轮询，不宜为“长连接”这一名称盲目改WebSocket或增加固定高频心跳。

## 2 双端消息提醒、声音与通知渠道

**N2-1 最新已记录iOS回签成品的身份和内容差异未闭环｜P0发布信任门禁｜历史成品事实，真实设备影响未知。**

- 现象/影响：源码/CI通过不足以保证最终包的安装信任、Keychain连续性、APNs topic以及实际执行内容；涉及10/9分发的iOS2213精确SHA `9e5d3582…bc8a21`。
- 证据：[分发报告:8](2026-10-09-ios2213-static-distribution.md:8) 记AppID与Bundle不一致、严格身份/原包比较失败及新增动态库/资源；profile与已签APNs环境均为production，**不是缺APNs权益**。该文件按用户当时明确例外授权分发，本项不否定授权，也未证明包有恶意或推送一定失败。
- 根因/复现：企业回签后的最终身份/非签名payload与源构建分离。对归档同SHA包用既有验证器和原包比较，再在保有旧数据的测试iPhone不卸载覆盖，检查身份、登录、旧聊天、普通APNs、PushKit/CallKit。不能用新装成功代替覆盖升级。
- 优化/验收：后续交付绑定最终SHA、身份一致性和每项内容差异审查；关闭此门禁前不据源IPA宣布“全双端已验收”，不由评审自动换包或下线。最终成品严格身份通过、内容差异可说明，真机旧数据/Keychain连续且前后台普通通知与通话分别达标。

**N2-2 iOS挂起态APNs没有遵循应用内声音/勿扰策略｜P1｜代码事实，听感待真机验证。**

- 现象/影响：系统允许声音时，应用内声音关闭/DND已开启，前台本地路径可静音，挂起态远程通知仍请求default声音；自定义通知音目前未形成完整功能。
- 证据：[pusher:225](../../apps/mobile_flutter/lib/features/push/matrix_pusher_service.dart:225) 固定 `aps.sound=default`；[coordinator:209](../../apps/mobile_flutter/lib/core/notification/notification_coordinator.dart:209) 偏好未同步远程iOS配置；[AppDelegate:217](../../apps/mobile_flutter/ios/Runner/AppDelegate.swift:217) 只在willPresent抑制前台副本；未发现NSE target/source。NSE缺失本身不等于普通通知无法到达。
- 复现：系统声音允许且Focus关闭，逐一切应用内声音/总开关/DND跨午夜，退后台至挂起后收单条合成消息；对照前台。分别核验角标、分类/actions、点击房间/事件路由和同事件本地/远程双副本，不用系统静音掩盖应用内策略错误。
- 优化/验收：明确远程/本地所有者并同步无敏感内容的通知策略，偏好变更可收敛；NSE按真正需求设计，不用silent push维持永久进程。自定义音若纳入产品，需设备已存在、受支持编码的wav/caf/aiff且短于30秒；授权/DND/Focus的系统选择仍优先。[Apple声音规范](https://developer.apple.com/documentation/usernotifications/unnotificationsound)、[后台通知限制](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- 验收：声音关/DND时挂起态0意外响铃；重新开启恢复；同事件最多一次提醒、角标与读取状态收敛、点击只进入当前授权账号对应房间。Focus可能抑制呈现/声音，不算应用应绕过的故障；Time Sensitive不等于绕过静音。[Apple提醒与Focus](https://developer.apple.com/design/human-interface-guidelines/managing-notifications)

**N2-3 按CID节流静默吞掉不同会话的通知机会｜P1｜本次离线复现。**

- 现象/范围：相同CID的A/B房间在1.5秒内通知，第二次成功响应但不出站；A静音/已读时，B该提醒的事件失去本次机会。聊天正文仍在Matrix，不能称丢消息；后续sync可能补通知。
- 证据：[rate_limit.py:38](../../services/getui-bridge/app/rate_limit.py:38) key只有(cid,kind)；[main.py:79](../../services/getui-bridge/app/main.py:79) 被限频即跳过；[本次脚本](artifacts/2026-10-11/e2e-architecture-review/push-distinct-room-repro.py) 与[输出](artifacts/2026-10-11/e2e-architecture-review/push-distinct-room-repro-output.txt) 显示A/B间隔100ms，HTTP200/200、provider_requests=1，exit0，全部模拟HTTP。
- 根因/复现：通用风暴收敛用于逐房间呈现，缺尾沿合并/待投递集合。复跑脚本后，在隔离测试机A静音、B非静音、Flutter不运行但供应商可启动原生的条件验证真实结果。
- 优化/验收：重复event去重与节流分离，按scope+room做有界尾沿合并/持久待投递；A静音/B新消息、同房突发、同事件重试和供应商503均覆盖。不同房间应得到提示或有明确合并语义，同事件不重复响；无需每条突发都播放一次声音。

Android已有高重要性及声音/震动/静默分渠道、原生去重和点击路由，本轮没有证据断言Channel创建失败。仍需补旧渠道→v2迁移、用户自改重要性/铃声、DND、渠道分组与通知栏样式回归；创建后的声音/重要性不能靠重建同ID强制覆盖用户设置。[Android Channels](https://developer.android.com/develop/ui/compose/notifications/channels) 本项各系统到达/声音成功率及延迟均未获得可用分母。

## 3 接收和发送消息的速度与可靠性

**M3-1 跨房间发送队列受慢房间拖延｜P1｜可达代码事实。**

- 现象/影响：A房间发送/租约或未建房解析挂起时，B房间虽然健康仍等待；离线恢复后尤其明显。
- 证据：[message_send_scheduler.dart:256](../../apps/mobile_flutter/lib/core/outbox/message_send_scheduler.dart:256) 先await未绑定解析；[293](../../apps/mobile_flutter/lib/core/outbox/message_send_scheduler.dart:293) 逐房间串行await；默认单操作30秒。30秒是参数，不是本次实测延迟；已有同txid、claim、迟到ACK保护不能删除。
- 复现/根因：控制A sender永不完成，A三条/B一条即时完成，再测试unbound解析挂起，测B首次dispatch；全局串行把每房间保序扩大成跨房阻塞。
- 优化/验收：每房保序、跨房小并发公平调度，解析独立有界lane；A挂起时B建议200ms内进入传输；并发有上限，同房顺序不变、原txid不变、无迟到ACK二次发送，账号撤销立即生效。

**M3-2 ACK、到达和显示缺少统一端到端测量｜P1验收缺口｜度量边界事实。**

- 现象/影响：发送端已确认不表示接收端已sync/解密/显示；弱网、多端、缺密钥和锁屏积压无法由API P95判断。
- 证据：[scheduler:548](../../apps/mobile_flutter/lib/core/outbox/message_send_scheduler.dart:548) event_id非空就sent/ACK；[trace模型:663](../../apps/mobile_flutter/lib/core/performance_trace_model.dart:663) 主要是发送操作的本地阶段。历史61次服务端P95 150ms不能转换为双端P95 150ms。
- 复现/根因：双测试机A发，B分别前台/离线/后台/缺密钥，分别记录tap、持久化、ACK、收密文、解密、落库和首帧。协议阶段不同，不是要求把ACK定义错误改成已读。
- 优化/验收：脱敏关联、校准墙钟、分层成功定义，按统一正常/弱网SLO报告P50/P95/P99和失败分母；验证重传、幂等、多端顺序、撤回编辑/已读收敛。终端密钥与正文不离设备；消息排序继续尊重权威顺序与稳定本地回声。

**M3-3 现有容量PASS没有覆盖首同步SLO或千人E2EE｜P1扩量门禁｜历史实测与脚本事实。**

- 证据/现象：[9/10容量报告](2026-09-10-media-capacity-runtime.md:19) 200VU虽六轮通过，初始sync P95最高22.967秒；500VU首轮两路径失败，预热后四轮通过。环境WSL4GiB/4vCPU、同机k6、hold2分钟，不发送/解密真实消息。当前[capacity.js:31](../../scripts/loadtest/capacity.js:31) 没有initial/incremental sync耗时阈值。
- 影响/根因：只统计最终HTTP成功容易漏掉冷同步、重连风暴、群密钥分享和扇出长尾；30秒空闲长轮询必须与有事件追赶分开，不能直接叫发送慢。
- 复现/优化：隔离同规格环境按200→500→1000成员，真实独立SDK建钥/解密，多发送者突发、成员变化、缺钥、离线重连与媒体混合，独立负载机稳定运行10–30分钟并三次复测；先冻结指标再调worker/连接池，保持默认加密轮换。
- 验收：每档三轮正常、冷启动和故障恢复均满足SLO；每个收端实际解密对账，未观察/失败不能从分母消失。没有本次证据支持“已稳定支持千人群或2000在线”。

## 4 UI交互与网络解耦

**U4-1 首屏变快后，旧历史首次精确定位仍可能等待数秒｜P1｜当前代码与历史测量。**

- 现象/影响：有缓存首屏可先出现，陌生历史ID查重/定位及依赖它的操作仍会慢；不是普通列表仍全量绘制。
- 证据：[timeline_id_store.dart:542](../../apps/mobile_flutter/third_party/matrix/lib/src/database/timeline_id_store.dart:542) 未命中时精确查旧源；[timeline_migration_reader.dart:519](../../apps/mobile_flutter/lib/features/matrix/timeline_migration_reader.dart:519) 无完整加速信息时从头扫描；10/9特定debug夹具首次约5.131秒，另一较新夹具约8.8秒，不能直接比较为回归。工作已在isolate中，不是UI同步JSON扫描。
- 复现/根因：1M旧ID、没有成员/Bloom索引，查尾部存在ID和不存在ID，同时输入/切房/发送；精确证明仍需O(N)首次索引建立。
- 优化/验收：可恢复后台索引、批量查询、取消和进度、交互优先。热索引查询P95≤100ms；冷扫描不得挡住缓存列表/输入，取消≤200ms；未知不能被当作不存在，去重/顺序正确。

**U4-2 同一大媒体在缓存链多次同步哈希｜P1｜当前可达代码事实。**

- 现象/影响：网络完成后发送/首开仍可能卡输入/绘制；没有本次CPU实测毫秒数。
- 证据：[media_cache.dart:1564](../../apps/mobile_flutter/lib/features/matrix/media_cache.dart:1564)、[551](../../apps/mobile_flutter/lib/features/matrix/media_cache.dart:551)、[590](../../apps/mobile_flutter/lib/features/matrix/media_cache.dart:590) 多层同步SHA；[content_addressed_media.dart:129](../../apps/mobile_flutter/lib/features/matrix/content_addressed_media.dart:129) verify同步遍历bytes。加密本身已compute，不能覆盖UI调用的缓存校验链。
- 复现/根因：10/50/100MiB固定文件冷缓存收发，同时IME开合，记录CPU timeline、哈希次数/字节和帧；多层重复证明同一不可变内容。
- 优化/验收：worker一次流式摘要，把可信不可变provenance沿边界传递；不可信入口仍校验。100MiB操作不出现UI isolate>8ms哈希片段，减少重复全量遍历；损坏修复、账号隔离、内容校验全部保留。

本项已有本地快照、乐观文本、分页和可见窗口；未缓存内容仍需网络，目标是操作可反馈、可取消、可解释降级。10/9快滑锚点<1px不替代真机弱网×连发×IME×切房组合；当前FPS、卡顿率、ANR率未知，按统一矩阵采集release/profile build与raster帧时间，debug最大帧不能当release分位。

## 5 内存、OOM与资源生命周期

**R5-1 独立提及扫描绕过有界时间线，并保留增长的全量状态｜P1｜代码事实，未证实当前OOM。**

- 现象/影响：主UI≤200模型并不约束@提及扫描；大量未读时Event/解密正文累积，每60条翻页后再遍历累计events，CPU可能近二次增长。扫描结束后ID/order/viewed状态仍可能增长并被全量JSON写回。
- 证据：[room_mention_store.dart:214](../../apps/mobile_flutter/lib/features/matrix/room_mention_store.dart:214) 创建独立默认timeline且不启用resident window；`:235/237`分页后ingest全表，`:119`遍历reversed；[unread_mention_tracker.dart:23](../../apps/mobile_flutter/lib/features/matrix/unread_mention_tracker.dart:23) 累积状态；[store:198](../../apps/mobile_flutter/lib/features/matrix/room_mention_store.dart:198) 完整encode后prefs写入。已有观察缓存WeakReference上限，不能据它认为tracker有界。
- 复现：合成1千/1万/10万未读群，旧读标记不存在或最早页，扫描时快滑/IME/切房；记录Event数、retained heap、编码字节及CPU曲线；重启核验已查看提醒不复活。
- 优化/验收：固定页正文扫描、持久游标/区间与必要例外ID，增量保存和交互暂停；10万未读时常驻扫描正文≤256条或等价固定上限，内存进入平台期，取消≤200ms；UI序列化≤4ms，提及/撤回/已查看正确率100%。不能直接截断viewed换性能。

**R5-2 可选缓存预算未覆盖在途媒体、Live Image、Native与GPU峰值｜P1｜可达代码风险。**

- 现象/影响：客户端上限内100MiB文件的完整明文、密文、解码/转码缓冲可超32MiB编码缓存预算；低内存机、播放+上传+切房的峰值未知。服务端还可能以更低上限拒绝，见V6-3。
- 证据：[media_message_service.dart:217](../../apps/mobile_flutter/lib/features/matrix/media_message_service.dart:217) 整文件读取；[content_addressed_media.dart:175](../../apps/mobile_flutter/lib/features/matrix/content_addressed_media.dart:175) 完整bytes准备加密；[native_media_download.dart:198](../../apps/mobile_flutter/lib/core/native_media_download.dart:198) 原生落盘后仍整块readAsBytes；[media_resource_policy.dart:6](../../apps/mobile_flutter/lib/core/media_resource_policy.dart:6) 明确ImageCache不含live/native/GPU。当前同页面媒体队列串行，不能根据服务“3槽”就声称必有3×100MiB并发明文。
- 复现/根因：低内存真机分别100MiB发送、图片浏览、视频播放，再叠加后台任务50–100轮；采Dart堆/Native/GPU、Android PSS/RSS、iOS footprint、GC、线程/FD及系统退出原因。只限制被缓存引用不足以控制活跃工作峰值。
- 优化/验收：全局活动字节与codec/播放器预算，文件/流式处理、减少复制、内存压力降级；E2EE完整性保持。按设备冻结总预算，50–100轮稳定后增长≤10%且无持续斜率，0 OOM/ANR/泄漏FD。旧Redmi闪退仍缺ApplicationExitInfo，不能由服务器OOM=false或swap反推出手机原因。

本轮未获得WebView/Bitmap/游标/线程/FD/Native泄漏的堆或系统诊断，不能编造具体已发生泄漏点。应补Android退出原因与native崩溃、iOS Jetsam/MetricKit，和页面dispose、播放器/采集/WebRTC、WebView反复开关的资源计数；Flutter异常上报覆盖不到所有原生死亡。

## 6 媒体链路与存储优化

**V6-1 非文本发送缺乏与文本等价的进程死亡恢复｜P1｜代码事实，终端复现待执行。**

- 现象/影响：图片、语音、视频、文件显示发送中后若被杀进程，内存任务可能消失；磁盘已有媒体不等于保存了目标房间、阶段、txid和发送意图。
- 证据：[room_timeline_controller.dart:1745](../../apps/mobile_flutter/lib/features/matrix/room_timeline_controller.dart:1745) 仅文本入持久journal；[matrix_outgoing_work_coordinator.dart:113](../../apps/mobile_flutter/lib/features/matrix/matrix_outgoing_work_coordinator.dart:113) 明确in-process-only；文本有重启queued恢复，不能把它泛化给媒体。
- 复现/根因：测试账号在准备、压缩/加密、上传中、上传后event前、ACK前后分别终止进程并保数据重启；比对文本与附件。带外载荷任务没有完整持久状态机。
- 优化/验收：持久账号隔离任务manifest、受控文件引用、阶段与同txid，恢复重新校验权限、最终成功后清理；每阶段100次故障注入，任务恢复或明确可操作失败，0静默消失/重复事件/跨账号重放。断点上传设计不能改变Matrix附件加密协议，下载恢复与上传恢复分别验证。

**V6-2 异步媒体API直接同步读取对象存储，拖住事件循环并整对象驻留｜P1｜本次合成复现。**

- 现象/影响：业务媒体/头像慢读取会拖延同API进程其他异步请求，并提高并发大文件内存；不直接证明Synapse消息发送也走该路径。
- 证据：[media_platform.py:539](../../services/business-api/app/api/media_platform.py:539) async路由直接调同步service；[repository.py:408](../../services/business-api/app/modules/media/repository.py:408) 到[media_blob_storage.py:96](../../services/business-api/app/integrations/media_blob_storage.py:96) boto3同步GET、BytesIO完整校验后返回。头像有同类调用。真实路由替换250ms同步delegate后，10ms timer实际延迟250.47ms且响应前未运行，exit0，**没有网络/DB、250ms是注入值**。[脚本与SHA结果](artifacts/2026-10-11/e2e-architecture-review/backend-media-event-loop-probe.txt)
- 复现/根因：运行归档probe，再在隔离环境模拟S3慢/超时及并发对象；async定义不会自动把内部同步IO移到线程池。
- 优化/验收：同步路由或受控线程池/异步存储、有界在途字节/并发/deadline；随后评估带鉴权/校验的流式/Range与CDN。修复后10ms timer不跟随250ms存储等待，event-loop lag P99<50ms，无关API不被拖慢；404/撤权/损坏/断连和私有桶边界不降低。

图片压缩、缩略图、视频文件/pin、可见预加载、内容去重和S3已存在；不能称媒体完全没有优化。当前缺真实编码尺寸分布、上传/首帧分位、CDN命中、失败率和总流量对照，无法量化“节省X%”。对原图/缩略图/语音/视频分别测冷/热、HEIF/HEVC等系统解码兼容、横竖屏与后台采集/播放恢复；降级可取消、可展示缩略图，但不以模糊成功状态或未校验明文换速度。磁盘问题详见第8项。

**V6-3 文件选择上限未提前与服务器能力取交集｜P2｜代码事实与现场配置文件，真实失败未复现。**

- 现象/影响：普通文件通过客户端100MiB大小预检后，仍可能因服务器较小上限失败；在最终检查前已付出整文件读取、缓存与加密成本。不是完整上传后才检查。
- 证据：[media_message_service.dart:17](../../apps/mobile_flutter/lib/features/matrix/media_message_service.dart:17) 定义100MiB；`:209/253`预检并readAsBytes；[matrix_e2ee_client.dart:9401](../../apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart:9401) 先缓存、准备加密，再`:9432`调用SDK。SDK在[room.dart:775](../../apps/mobile_flutter/third_party/matrix/lib/src/room.dart:775) 读取服务器mUploadSize并在HTTP上传前拒绝超限文件，保护确实存在。09:37:32+08只读[生产容器配置文件](artifacts/2026-10-11/e2e-architecture-review/production-media-limit.txt) 为max_upload_size=50M；未查询运行服务对客户端实际公布的能力，因此不能单凭配置文件认定每次请求的有效上限。
- 根因/复现：应用静态预算与服务器能力在不同阶段判断。在隔离夹具让服务器公布50MiB上限，选择64MiB普通合成文件，跟踪读取、缓存、加密与SDK异常顺序；再用测试账号读取实际媒体能力核对配置。未在本轮生成或上传该大文件。
- 优化/验收：发送前以客户端预算、服务器公布能力及已知代理约束取最小值，缓存能力并定义过期/失败策略，保留SDK最终守卫。上述64MiB夹具应在整文件读取/加密前明确拒绝；边界内正常文件通过、边界外清晰失败、配置变化可收敛；不为消除提示而直接提高服务端上限。视频按转码后文件另做预检。

## 7 整体架构与网络架构

**A7-1 核心服务与演练/其他项目同宿主且没有资源配额｜P1｜当前现场事实。**

- 现象/范围：任一服务或恢复任务突发耗用可能挤占 API、同步、数据库和推送。当前没有证据证明它已造成用户事故。
- 证据：本次35容器快照；抽查8个核心服务均 `memory_limit=0/cpu_quota=0`。恢复栈 worker 为 unhealthy，**线上 sync worker 为 healthy**；主机 available约3.7GiB，短时无换页抖动。见[资源快照](artifacts/2026-10-11/e2e-architecture-review/production-resource-snapshot.txt)。
- 根因/复现：资源失败域共享。隔离同规格主机叠加同步、大媒体与演练负载，测PSI、swap IO、磁盘延迟和各业务分位；不能直接压生产或关停未知归属容器。
- 优化/验收：基于峰值设预留与逐服务配额，演练栈独立资源池和到期登记；先保留核心余量再评估扩容。连续7–14天与隔离忙时负载满足SLO，测试任务超额不能拖垮核心；配额触发和回退可演练。不能照瞬时RSS设置过低限制导致主动OOM。

**A7-2 单同步入口与单权威源站仍有可用性故障域｜P1｜配置事实与待验证风险。**

- 现象/范围：sync worker故障时业务登录可正常但收消息失效；香港主站/PG故障时边缘不能独立恢复业务。S3可读不等于消息元数据/鉴权可用。
- 证据：[nginx.conf.template:14](../../infra/nginx/nginx.conf.template:14) 单个同步上游，`:126` 精确路由；[edge nginx:23](../../infra/edge/nginx-edge.conf:23) 单源站；[S3 ADR](../adr/0086-media-storage-s3-backend.md) 明确新对象主写S3及回退边界。9/27两个PG曾有隔离恢复验证，不能称没有备份，但不是10/11完整RPO/RTO证明。
- 复现：隔离环境停一个sync worker、阻断源站/对象存储/DNS，保持其他依赖存活；用真实SDK测试用户收发和恢复。模板与当前生产有效路由仍需逐项核对。
- 优化：按实际负载设置冗余同步worker与健康感知切流；证明main备用容量再启用回退。冻结完整DB、对象、删除墓碑、配置和身份恢复清单及RPO/RTO；不要在金融权威上直接引入未经设计的跨区双写。
- 验收：单worker故障建议30秒内恢复增量同步且已确认事件不丢；整站恢复目标由业务确认，例如RPO≤15分钟/RTO≤60分钟仅作起始讨论值。必须用最新备份实测数据截止点、恢复耗时、撤权/删除不复活及Outbox幂等，不能以健康200代替。

**A7-3 健康检查和滚动诊断不足以作为端到端SLO｜P1（补测与观测优先）｜代码事实。**

- 现象/范围：业务ready=200不表示同步、解密、媒体或通知正常；短时数据可能随进程重启/有界采样丢失，缺样不能解释为无故障。
- 证据：[health.py:25](../../services/business-api/app/api/health.py:25) 仅DB `SELECT 1`；[tracing.py:121](../../services/business-api/app/core/tracing.py:121) 单进程256series/每series512样本；[performance_diagnostics.py:95](../../services/business-api/app/api/performance_diagnostics.py:95) 当前worker快照；[database.py:26](../../services/business-api/app/core/database.py:26) SQL计时不覆盖完整连接等待与取结果；网络事件队列有1024上限和丢弃统计。客户端历史操作丢样亦已有记录。
- 根因/复现：存活、局部性能与用户旅程是不同层；隔离故障注入sync/S3/队列并重启API worker，对照ready、端侧结果与指标是否留存。
- 优化：保留廉价liveness，另做低频受控合成旅程、持久分桶直方图、worker启动ID/版本/采样分母/丢弃率和告警；串起发送、接收、解密、首帧。不要把所有依赖绑到ready造成级联重启，不上传明文。
- 验收：每类故障可在2分钟内分层告警；重启后历史分位可查、缺样有分母；在支持的ROM/系统和繁忙时段产生连续7–14天SLO。未证明缺少某一监控品牌工具，问题是覆盖与证据。

**A7-4 Outbox维护与跨topic发布有队头阻塞/租约重领风险｜P2，负载增长前升P1｜代码事实。**

- 现象/范围：慢外部IO或维护任务可能拖延其他topic；整批处理超过租约时，多消费者可能重领尚未处理项。现有幂等保护仍在，不能直接推断重复入账。
- 证据：[worker.py:101](../../services/business-worker/app/worker.py:101)、[149](../../services/business-worker/app/worker.py:149) 维护→默认50条领取→同步逐条处理；[outbox.py:87](../../services/business-api/app/core/outbox.py:87) 五分钟租约且本链未续租；已有SKIP LOCKED、退避、DEAD、耐久回执和部分独立runner。
- 复现/根因：隔离PG注入慢handler与50条批次、启动第二消费者，观察每topic oldest age/重复投递/业务回执；串行与整批同起点租约放大慢项。
- 优化/验收：有界topic工作池、批量/租约续期策略和超龄告警；慢topic不拖关键事件超过其SLO；中断/迟到ACK/重投仍只有一次合法业务效果，金融写的幂等、审计和Outbox事务边界保持。

**A7-5 核心客户端聚合类过大，SDK补丁维护成本增加｜P2｜代码规模事实，不单独等于性能缺陷。**

- 证据/影响：[matrix_e2ee_client.dart](../../apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart) 本次9764行，兼具会话、历史、发送、媒体与恢复协调；仓库还维护Matrix SDK补丁。功能改动容易牵动生命周期和安全边界，既有大量测试是保护层。
- 复现/验证：选择一次升级SDK或历史/媒体小改动，记录触及模块、依赖方向、重跑范围与回归；当前没有“类大导致当前卡顿”的因果测量。
- 优化：按公开接口拆会话生命周期、同步投影、历史索引、发送队列和媒体协调；先建立边界契约、故障/取消语义、依赖注入和补丁上游追踪。不要一次重写协议或把财务状态移入通信域。
- 验收：模块间只用公共接口，无循环依赖/跨域表写；上游版本变化有最小补丁清单和回归矩阵；行为、安全与性能基线无退化。代码行数减少本身不作为唯一KPI。

## 8 本地目录、文档与归档

**S8-1 聊天缓存写入仍包含全账号文件扫描，且配额不是全应用总上限｜P1｜代码事实。**

- 现象/影响：大批小媒体或多账号历史可能使缓存落盘尾延迟随对象数增长；聊天目录外的头像、朋友圈、原生下载暂存、日志、数据库与临时文件不能从 1 GiB 常量推断有总量约束。
- 触发与复现：隔离账号分别预置 1 千/1 万/10 万个合法缓存对象；每次新增小文件并测 `store` 耗时、文件 stat 次数和 UI 帧；再同时填充其他媒体目录并比较操作系统占用与应用统计。不要在真实聊天目录放入合成文件。
- 证据/根因：[media_cache.dart](../../apps/mobile_flutter/lib/features/matrix/media_cache.dart:614) 在返回前等待配额维护；[731](../../apps/mobile_flutter/lib/features/matrix/media_cache.dart:731) 每写调用 `_accountObjects` 全目录 stat；[682](../../apps/mobile_flutter/lib/features/matrix/media_cache.dart:682) 全局核对收集文件列表。其 IO 为异步，不能据此直接宣称同步阻塞主线程；已确认的是 O(对象数) 元数据工作与落盘关键路径耦合。
- 优化：索引维护增量字节/对象计数；限批对账和闲时 GC；给所有缓存域统一登记预算与“在用不可淘汰”语义；清理只删可重建数据，账号数据库/密钥、待发文件和用户导出单独管理。
- 验收：10 万对象下单次小对象入库 P95 <100 ms（指定测试磁盘）；统计界面 <200 ms 展示已有快照；目录计数与实盘对账误差 <1%；不因清缓存删除待发内容/数据库/密钥，无跨账号误删。所有缓存域分别申报上限，不能把聊天 1 GiB 写成 App 1 GiB。

**S8-2 iOS 普通聊天缓存的备份/文件保护策略未统一｜P1｜代码事实与待验证风险。**

- 现象/影响：普通聊天媒体放在 Documents，可能进入备份并增加备份空间和明文副本暴露面；尚未读取用户备份，不能称已泄漏。
- 触发与复现：iOS 16 与当前主版本测试机分别接收媒体/重启/锁屏，读取目标文件 backup exclusion、保护级别及测试备份内容；测试账号不得使用真实聊天材料。
- 证据/根因：[media_cache.dart:230](../../apps/mobile_flutter/lib/features/matrix/media_cache.dart:230) 使用 Documents/chat-media/v2；[IOSBackgroundMediaDownload.swift:89](../../apps/mobile_flutter/ios/Runner/IOSBackgroundMediaDownload.swift:89) 只给 background-media-v1 明确设置不备份和首次解锁后保护。在检查范围未见普通 chat-media 同等设置。Apple 指定可重新下载/生成的数据应从备份排除。[Apple 文件系统规范](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)
- 优化：区分可淘汰缓存与用户主动离线保留；使用合适的 Caches/Application Support 目录并显式设置保护/备份属性；原子迁移且保留既有离线语义。Android 同步核验最终合并 Manifest 的 Auto Backup/data extraction 规则；源 Manifest 未显式配置不足以证明最终包行为。
- 验收：可重建聊天缓存不进入测试备份，授权导出符合用户预期；锁屏下载只允许设计范围；升级、迁移中断、跨账号和卸载重装测试不丢不可替代数据。E2EE/密钥相关改动遵循 ADR 与双重审查。

**S8-3 本地验证与工作树体积较大，归档可恢复性和异地备份仍需闭合｜P2｜当前元数据事实。**

- 现象/影响：文件发现/扫描/备份成本高，本机损坏可能失去未入 Git 的唯一验证与发布材料。
- 证据：本次盘点 `docs/verification` 316020 文件、28.43 GiB；`.worktrees` 1006519 文件、46.73 GiB；主 Flutter build 4.59 GiB、`.dart_tool` 0.97 GiB。Git 跟踪 5345 文件，其中 docs 1433；current-state 2671 行。统计是逻辑文件长度，不是去重后的物理占用，**没有做全量哈希去重，不能将这些体积叫作可回收空间**。
- 根因：多轮构建、独立工作树与历史证据累积。已有 [30/90 天保留政策](README.md)，9/10 已执行过 89 目录归档，故问题在持续执行和恢复登记，不是没有政策；[archives 说明](archives/README.md) 明确本地归档并非异地备份。
- 复现/优化：运行本次 inventory.py 取得元数据；逐任务登记 owner、源版本、活跃进程/工作树、证据类别、保留至、唯一性、依赖和恢复位置。按摘要确认副本；原包、固定签名、工具、源码/回滚与财务/E2EE证据成套保留。把 current-state 收敛为近期状态及按主题索引，原历史通过链接保存。
- 验收：每个拟清理目录均有精确清单、SHA256、引用检查和恢复验证；唯一发布/安全证据零丢失；至少一个独立受控备份位置完成抽样恢复；文档入口无失效链接。清理实施另按现有授权规则领取，不由本评审直接删除。

建议目录职责：应用私有持久目录放数据库/密钥引用/待发队列和必须离线保留项；缓存目录放可重建图片/缩略图/视频；临时目录只放带任务ID、创建时间和租约的中间文件；相册/Downloads 仅在用户明确导出时写入，遵循 Android Scoped Storage 与 iOS 相册权限。日志与诊断限量滚动并脱敏，文件索引以账号/版本/内容摘要关联，禁止把房间密钥或原始身份放入目录名。工作区继续使用源码、runbooks、ADR、tasks、verification、artifacts、archives 的现有分层。

## 9 冷启动、温启动与热恢复的缓存优化

**L9-1 本地启动挂起仍会让首帧长期延后｜P1｜当前代码事实，原生设备表现待验证。**

- 现象/影响：首次网络sync已移到后台，但身份/Keychain/数据库本地恢复迟滞时，用户仍可能停在原生启动面，无法看到阶段或重试入口。
- 证据：[installation_startup_gate.dart:42](../../apps/mobile_flutter/lib/core/installation_startup_gate.dart:42) deferFirstFrame；[76](../../apps/mobile_flutter/lib/core/installation_startup_gate.dart:76) 等reconcile，`:96–102`等start完成才释放；等待态为空Widget且无挂起预算。[main.dart:130](../../apps/mobile_flutter/lib/main.dart:130) start包含诊断salt、安装标识、库/SDK打开；早于runApp还串行读取本地偏好。`waitForFirstSync:false`确已存在，不能再归因全部启动到网络。
- 复现/根因：测试夹具把reconcile或start设为不完成Completer并推进10秒；真机用合成大库、锁屏后Keychain访问和慢存储验证。可正常抛异常会显示错误，但不结算的Future无法进入异常页。
- 优化/验收：首帧预算后给无聊天访问权的安全进度壳，按阶段诊断、取消/重试且旧操作退休；不能跳过身份/密钥检查或并行打开多个库。建议挂起≤3秒出现明确恢复状态；正常正式包按统一冷/温/热TTID与TTFD验收，网络离线仍能显示已授权本地缓存。

**L9-2 已有启动优化没有闭合旧机覆盖升级、最新系统和热恢复SLO｜P1验收缺口｜历史现场。**

- 现象/影响：iOS16.7.16旧数据覆盖曾出现登录持续等待，重启可见缓存但不能收发；Android2204历史有恢复13.176秒和闪退反馈。两者不等于当前2213仍必现，也未证明同一根因。
- 证据：[iOS调查](../workflow/tasks/2026-10-08-ios2205-login-investigation.md) 业务login/grant200而未匹配Matrix login，启动闭合诊断缺失；iOS26.2的18项原生测试不覆盖16.7.16最终企业包；[10/9报告](2026-10-09-cache-first-fast-history-emoji-recents.md:44) 100房/10×25万旧索引恢复约2.46秒为debug夹具，不是完整真机冷启动P95。
- 复现/根因：最终包同SHA、保留旧数据库/Keychain、不卸载，在16.7.16与新iOS及问题Android机跑冷启、后台10/30分钟/8小时返回、首次解锁、离线、升级。问题阶段需读身份选择、SDK停止/恢复、DB、鉴权闭合栈；“缓存能看见”不等于会话可用。
- 优化/验收：绑定原包→最终包身份、分阶段计时和客户端退出原因；缓存命中失效分类，登录/同步就绪状态真实分开。每桶≥30次仅作启动筛查，报告原始样本、失败分母、首屏和可操作时点；正式P95/P99需扩大样本并给置信区间，样本不足时P99标记不足。旧聊天/登录连续性通过，未达标设备不由新模拟器成绩代替。

优化前后目前只能比较功能及特定夹具：首轮网络sync不再阻挡已有缓存、首屏/快滑护栏已有验证；**没有同设备、同数据、同网络、同构建模式的前后完整启动百分位**，不能给出“提速X%”或泛化2.46秒为全机型启动时间。后续比较至少记录OS进程启动、Flutter引擎、runApp、首帧、偏好/Keychain、SQLCipher打开、缓存首屏、首次可交互、鉴权就绪、同步追赶完成。

补充存储恢复风险：底层SDK旧明文库转换有export→assert→delete→copy流程，但当前入口有未授权迁移阻断、安全壳和`.encrypted`残留fail-closed保护，不能把它报告为所有用户启动都会删库。认证后允许的旧库转换应另做每个故障点的恢复验证，保留原副本及完整性检查；本次不列为已证实P0数据丢失。

## 统一设备与场景验收矩阵

目前没有按生产活跃设备分布采样，以下是必须补齐的覆盖计划，不代表已经测试。不能用一个模拟器或一台旗舰机代替双端/厂商验收。

| 维度 | 覆盖要求 | 必采证据 |
| --- | --- | --- |
| Android 系统 | API24/Android7 支持下限兼容抽测；Android10/11 存储迁移边界；12、13、14、15、16 为重点；17/API37 增补兼容 | 精确 OS build、target/minSDK、安装包 SHA、厂商系统版本 |
| Android 厂商 | Pixel/AOSP、Samsung One UI、小米/Redmi MIUI/HyperOS、OPPO/一加 ColorOS、vivo OriginOS、荣耀 MagicOS、华为可运行现有APK的EMUI/HarmonyOS设备 | 各至少低/中内存代表，生产DAU高的型号优先；原生鸿蒙发行另列支持缺口 |
| iOS | 16（包含既有16.7.16故障）、17、18、26、27；旧机与新机；60Hz/高刷新率 | 正式签名成品、旧包AppID/Keychain基线、Xcode/SDK、真实覆盖安装身份 |
| 生命周期 | 首装冷启、保数据升级冷启、进程回收后冷启、温启、热恢复、前台、后台、锁屏8小时、重启首次解锁前后 | TTID/TTFD、生命周期时间线、进程死亡原因、DB/身份恢复结果 |
| 系统限制 | Doze、App Standby各桶、后台受限、省电/超级省电、白名单/自启动各开关；划掉最近任务、系统LMK与用户force-stop分别测试 | 推送提供商受理/设备回执/通知展示/点击/实际同步的不同结果 |
| 通知设置 | 未询问/允许/拒绝、通知总开关、各channel、声音/震动、静音/DND/Focus、房间静音、应用内DND；旧版本渠道迁移 | 期望是否应响/应显示/仅记未读；次数和延迟，不强行绕过系统选择 |
| 网络 | 正常Wi-Fi/蜂窝；RTT400ms、下行1Mbps/上行256kbps、5%/10%丢包；完全离线10分钟；Wi-Fi↔蜂窝、DNS失败、TLS失败、网络恢复 | 丢包配置、抓取元数据、请求重试、事务ID/事件ID关联；禁采明文密钥 |
| 数据规模 | 单聊与100/500/1000人群；100/1000房间；1万/10万/100万历史；文字/大图/长视频/语音/文件混合 | 首次/热缓存分开，峰值RSS/PSS/native/GPU、DB读行数、队列深度、恢复一致性 |
| 存储 | 空余空间≥20%、低于500MiB、ENOSPC；进程被杀在上传/落盘/迁移每个关键阶段 | 临时文件、未发送附件、数据库/密钥可恢复、缓存清理不影响用户数据 |

Android 17/API37 与 iOS 27 已有官方平台资料，因此覆盖计划不能停留在旧的 Android16/iOS26 测试记录；是否称“主流”仍须产品的活跃设备分布证明。[Android 17 变更](https://developer.android.com/about/versions/17/summary)、[Apple iOS27 开发发布说明](https://developer.apple.com/news/?id=k1mtkt1k)

对关键缺陷采用全组合：Android15–17 × 锁屏/Doze/FGS超时；iOS16与新版本 × 同签名/身份变化覆盖升级；弱网 × 快滑/切房/发送。其余维度采用风险驱动配对覆盖，最终按OS/ROM/设备等级独立汇总，不能用整体平均掩盖单型号失败。

## 指标口径与建议准入值

下表数字是首轮性能预算，需在指定参考设备和可重复网络上冻结；不把Google平台“慢启动”界线误当本项目已达到的体验目标。

| 指标 | 口径与建议目标 |
| --- | --- |
| 发送反馈 | 点击至本地气泡/可见排队状态 P95≤100ms；离线也能反馈，不把乐观显示当发送成功 |
| 正常文本端到端 | 点击→对端收到密文→解密→落库→首帧分别计时；预建会话正常网建议P50≤300ms、P95≤1s、P99≤3s；包含失败/超时计数，另报服务端ACK |
| 弱网文本端到端 | 上表RTT/带宽/丢包配置下建议P95≤5s、P99≤15s；离线阶段不计算不可能的到达时延，恢复网络后单独计追赶 |
| 消息可靠性 | 正常网10秒内服务器确认≥99.9%；固定离线10分钟/1000条fixture、网络恢复且凭据有效后60秒内已提交消息对账100%；权威撤回/过期按预期状态核对，凭据失效、未解密与超时单列，不能排除后伪造成功率；重复可见气泡0，重试保留事务ID |
| 通知可靠性 | 通知已授权、系统允许、具备有效推送通道的分桶内：30秒内可见≥99%，P95≤5s/P99≤30s；强停/断网/拒权单独报告可恢复行为，不能承诺强制唤醒 |
| 保活与恢复 | 存活率只是诊断项：后台总观察时长中进程可用比例；主要目标是进程不存在仍可按系统规则通知、启动后同步无丢失。系统回收后首次重新启动P95≤5s恢复可用聊天（已有缓存/密钥） |
| 能耗 | 同机同网络8小时锁屏A/B至少3轮，依据方差追加轮次；报告mAh/mWh每小时、包数/小时、CPU唤醒与wakelock及置信区间。相对空闲基线增加≤1个百分点电量/8小时只作探索预算；正式验收使用校准能耗及测量误差，系统百分比不足以证明该差异 |
| 流畅性 | 指定60Hz设备build/raster各自P95≤16.7ms；高刷新率按实际帧deadline统计；错过deadline帧<1%、>100ms帧<0.1%；点击/切页不被网络await阻塞。离线缓存路径P95≤200ms反馈 |
| 稳定性 | 隔离回归0 ANR/0 crash/0 OOM；灰度以用户会话为分母建议crash-free≥99.9%、ANR受影响会话<0.1%，并单列LMK/Jetsam，不把LMK等同Java OOM |
| 内存 | Android报告PSS/RSS，2–4GiB参考机初始候选空闲≤200MiB、典型聊天≤250MiB、混合媒体峰值≤350MiB，实测后校准；iOS单独按physical footprint/dirty memory及Jetsam余量冻结预算。100次切房/播放返回稳定后增长≤10%且无持续上升；缓存、活跃图像、GPU/Native分别报告 |
| 媒体 | 同对象有效热缓存网络下载0，已校验视频热缓存首帧P95≤500ms；冷读按下载+解密校验+解码分阶段验收（10Mbps完整接收10MiB理论约8.4秒，不能承诺2秒）。仅经批准且可独立鉴权/校验的分段协议可另设2秒目标；不得提前播放未校验明文。正常网缩略图P95≤500ms、失败率<1%；批准的续传路径额外流量≤10% |
| 磁盘 | 按缓存域上限管理；可回收超额60秒内回落，在用/在途租约例外显式上报；临时任务结束立即回收，异常遗留下一次维护≤24h清理；低空间无库损坏/待发丢失 |
| 启动 | 正式包、每设备每条件先≥30次筛查，按尾延迟方差追加样本后判分位目标：冷TTID P95≤2s、已有缓存可交互TTFD≤3s；温启动≤1s、热恢复≤500ms；网络离线不阻止本地首屏。首帧≤时间不代表同步/鉴权完成；少量样本不宣称可靠P99 |
| 缓存命中 | 区分内存/磁盘/本地DB、首装/二次启动；固定二次启动fixture首屏消息命中100%、已下载头像/缩略图≥95%；首次安装无缓存不纳入热命中率 |
| 后端 | 可比负载下非媒体API P95≤300ms/P99≤1s，event-loop lag P99<50ms；Outbox关键通知/业务事件积压年龄P95≤5s、P99≤30s；所有失败、租约超时、重试有指标和告警 |

每个成功率至少记录分子、分母、超时、排除原因和95%置信区间；P99首轮建议每关键分桶至少1万事件，低流量设备不能伪精确到百分位小数。跨设备时间戳需时钟校准并记录误差，同设备阶段用单调时钟。关联使用脱敏短期trace和事件标识，不上传消息正文、恢复密钥、附件明文或金融敏感数据。通知受理、设备收到、系统展示、播放声音、点击、解密显示是六个不同结果。

Android官方将冷/温/热TTID≥5s/2s/1.5s视为过慢，这是平台参考线，不能替代上述建议体验预算或iOS目标。[Android startup 指标](https://developer.android.com/google/play/vitals/launch-time)

## 优先级路线图

| 顺序 | 优先级与任务 | 退出条件 | 依赖/边界 |
| --- | --- | --- | --- |
| 立即处理发布门禁 | P0：N2-1最终iOS回签身份/内容差异闭环 | 同SHA身份验证、差异解释、旧数据覆盖升级与APNs/通话真机验收 | 既有例外授权保留；评审不自动撤包/换包，不将未证实问题称全网故障 |
| 第一批可靠性修复 | P1：B1-1 FGS超时与锁状态；N2-3跨房节流；N2-2 iOS远程策略；B1-3绑定恢复 | 故障/限额模拟、测试账号真机后台与偏好组合通过 | 不绕过系统通知选择，不上传明文，不以进程永驻为目标 |
| 第一批独立后端修复 | P1：V6-2同步媒体IO阻塞 | 真实路由慢IO回归+并发/内存/权限/撤权/损坏验证通过 | 有界线程或异步IO；保留完整性校验与私有存储边界 |
| 客户端性能与发送恢复 | P1：R5-1有界提及；U4-1历史定位/U4-2哈希；M3-1公平队列；V6-1媒体持久任务；L9-1启动安全壳 | 红→绿、精确输入回归及低内存真机组合达标 | 每房保序、同txid、账号/Keychain安全与所有取消规则保持 |
| 并行补齐准入证据 | P1：B1-2 OEM、M3-2/A7-3端到端观测与指标留存、M3-3真实E2EE容量、R5-2峰值、L9-2旧机升级/新系统 | 统一矩阵有分母、分位、失败/缺样；逐平台最终成品绑定 | 不重复未变等价单测替代缺失实机/负载证据 |
| 峰值与故障域治理 | P1：A7-1资源、A7-2worker/主站恢复、S8-1/2目录和备份 | 同规格忙时与最新整栈恢复达标；缓存和用户数据边界明确 | 先测峰值再设配额；恢复栈归属确认后另任务治理 |
| 后续结构与成本 | P2：V6-3媒体上限提前预检、A7-4 Outbox公平性/租约、A7-5模块拆分、S8-3归档 | 无跨域回归，工件可恢复/文档可导航；慢topic不拖关键事件 | 金融/E2EE/发布证据保留现有期限与审批，不盲目拆微服务或迁区 |

建议按可独立验证的任务并行，而不是给整个App一个“全部优化完成”标记。每项实现由合适的客户端/原生/后端/质量负责人领取；本报告不估算没有团队产能依据的工期。当前最紧迫的P0是成品信任门禁，尚没有证据判定当前存在全网消息丢失或已确认手机OOM。整体发布验证与性能可证明性风险偏高；扩大用户规模前应先闭合上述P1准入证据。

## 本次验证与交付记录

- 个推桥接离线测试：38 passed、exit0；2条现有依赖弃用警告，分别为Starlette/httpx与Pydantic class Config，未隐藏。它们不构成通知真机验收。[测试记录](artifacts/2026-10-11/e2e-architecture-review/push-tests-result.txt)
- 两个隔离复现均exit0，证明对应现象可被触发：跨房通知静默限频、async媒体路由同步等待。不是修复通过，也没有真实供应商/S3调用。
- 生产资源快照与文件元数据盘点exit0；未遍历文件正文做秘密/内容抽取，未计算可删的去重字节数。
- 当前产品源码未变，因此没有重复全仓verify、APK/IPA构建或部署。专项报告为[推送](artifacts/2026-10-11/e2e-architecture-review/push-review.md)、[客户端](artifacts/2026-10-11/e2e-architecture-review/client-review.md)、[后端](artifacts/2026-10-11/e2e-architecture-review/backend-review.md)；主报告是统一优先级与验收口径，子报告中的初始阈值以本报告为准。

## 需要补充的数据与资料

1. 双端**实际安装的最终包**SHA、构建来源、签名/权益、OS/ROM/硬件、升级前安装身份；iOS旧包Keychain/AppID与2213最终回签内容差异说明。不能只交源IPA。
2. 脱敏DAU/MAU、各OS/厂商/机型/内存分布、网络地域/运营商、活跃时段和群规模，用于判断“主流”及权重。
3. 每推送通道的生产启用证据和控制台回执：APNs environment/topic/证书关系、个推与各OEM配置、token/CID生命周期、禁用原因；不需要私钥/secret/token原值。
4. 分阶段消息trace与成功率分母：本地排队、加密、提交、服务器ACK、收端sync、解密、落库、展示、重试、通知。离线恢复、多端并发、撤回/编辑/已读和进程回收场景的数据。
5. Android ApplicationExitInfo、Perfetto/frame timeline、heap dump（先脱敏）、PSS/Native/FD/线程趋势、Battery Historian；iOS MetricKit、Instruments Allocations/Leaks/Energy、Jetsam/崩溃与主线程挂起记录。
6. release/profile真实设备冷温热启动各阶段计时、数据库规模/迁移版本、缓存命中/失效原因；问题设备iOS16.7.16、Redmi K80优先复现且保留数据。
7. 媒体编码/尺寸/时长分布、上传下载分位与取消/断点恢复、CDN命中与首字节、S3吞吐/错误、缓存目录占用及重复对象摘要统计；分母按媒体类型区分。
8. 至少7–14天服务器CPU/内存/PSI/swap IO、磁盘await/IOPS、PG慢查询与连接等待、Redis、队列年龄、网关错误/上游耗时、同步积压和推送回执。保留峰值，而非只有docker stats快照。
9. 与生产拓扑同构的200→500→1000真实E2EE群测、2000在线目标混合负载、故障注入、备份恢复记录及经业务确认的RPO/RTO；现有HTTP测试不能替代。
10. 活跃工作树/任务所有权、发布与审计工件清单、备份目的地/权限/恢复记录；精确重复内容证明后才形成可回收字节量。

资料缺失不阻止以上代码结论；只阻止与其直接相关的到达率、兼容性、功耗、容量和恢复保证。后续修复需分别领取任务、先复现后修改、按变更影响执行门禁；受保护的加密、身份、金融及数据库恢复改动继续遵循既有ADR、规格和质量/安全审查。
