# 生产推送只读核查与分阶段修复建议

2026-10-11，Asia/Hong_Kong。本分项远程观察区间：09:56:45–10:02:04；本地整理另计，精确主动工时未知。依据本轮用户明确授权连接服务器查看和给出方案；未获实施/部署请求，因此没有改代码、生产文件、设置、服务或客户端，没有真实推送、造会话或读取用户消息。仅使用既有 `scripts/starchat-server.ps1 -Action Command` 经 SSH jumper，保留主机校验。探针在服务器进程内聚合，只返回固定字段、计数、标准错误类、公共源码信息和身份比较布尔；没有输出secret/token/CID/pushkey/user/deviceID或日志正文。

用户已澄清：小米、OPPO、vivo等 **Android厂商推送** 因上架审核暂不能配置；这项外部依赖不代表iOS APNs未配置，也不阻塞下列无需厂商凭据的源码修复与模拟验证。本分项未查询厂商控制台。

## 本轮确认的生产事实

| 项目 | 本轮读取 | 能与不能证明什么 |
|---|---|---|
| Getui bridge | 运行镜像 `sha256:d47c752d0c190a8b7d227ad02b4ff739b43e86051c4d87070e7293826d8604e7`；2026-10-03T10:49:37Z启动；RestartCount=0；没有配置Docker healthcheck | 进程running不是全部依赖健康；没有health字段不能写成unhealthy |
| Getui源码 | `/app/app/main.py/rate_limit.py/getui_client.py/notify.py` 四文件SHA与本地当前审查源码完全相同 | 上轮离线确认的每CID节流及v1 transmission行为确实存在生产实现；不等于已取得设备漏响率 |
| Getui有效数值设置 | `rate_limit_ms=1500`，`notify_ttl_ms=300000`；公开AppID、AppKey、签名secret存在性均true，未读取输出其原值 | 说明配置存在，不证明凭据今天永远有效或供应商已送达 |
| Sygnal | 镜像 `matrixdotorg/sygnal:v0.15.1`，实际ID `sha256:0e3ab79e04371964916f428a99b7fab19f23cbb16089112c4e7d8874c8f301ba`；2026-09-07T09:01:50Z启动；RestartCount=0 | 本次没有重启或改配置；不代表供应商与手机链全程通过 |
| Sygnal加载配置 | 无SYGNAL_CONF覆盖；运行入口源码249行默认 `sygnal.yaml`；PID1 cwd为`/`，解析到挂载 `/sygnal.yaml`；该文件mtime为2026-09-07T09:01:49Z，早于当前启动 | 证明当前启动的默认配置路径及现存文件时间关系；不是运行进程内部状态转储 |
| 普通iOS APNs | 当前配置两app：1个noop、1个普通iOS APNs；客户端pusher app_id匹配；production=true/sandbox=false；keyfile/key_id/team_id/topic均存在，keyfile是实际文件 | iOS APNs已配置，不能写成尚待Android厂商审核。存在keyfile不等于验证密钥有效性 |
| FCM/VoIP边界 | 此Sygnal配置无FCM app、无VoIP app | 仅限此服务配置；不能断言项目没有独立PushKit/CallKit/业务侧来电发送器 |
| iOS最终产物身份比较 | APNs topic匹配源码Bundle；但不匹配10/9最终2213回签AppID后缀；APNs team_id也不等于该回签Team，全部只返回比较布尔 | 强化最终回签身份必须核对的事实；不能据此断言当前全部iPhone推送失败、密钥泄漏或应用恶意 |

运行证据：[discovery](push-runtime.discovery.json)、[code/log observation](push-runtime.observation.json)、[APNs summary](push-runtime.apns-summary.json)、[effective settings/identity](push-runtime.identity-comparison.json)、[config selection](push-runtime.config-binding.json)、[config confirmation](push-runtime.config-confirmation.json)。首轮复合Sygnal探针exit1只保留安全错误标记；缩小为配置字段探针后成功，未打印原始异常/配置。

四文件SHA：

| 文件 | SHA256 |
|---|---|
| main.py | `92dc75f4666e9faee6d3cf1f8d15fd044db64de70ebd60da1ac98dfa0840df32` |
| rate_limit.py | `112c2de5a2ed1f2fa539300bb5fff32c48a3f24f52d7bb32dc73017e8c15b702` |
| getui_client.py | `2a9cea68dffbba9f646809c74011f06f8aa3d832bc5ff1f338987b981340fbb6` |
| notify.py | `9df02dfa11d8bc71e5cb9805680f737a79abe151d8365a1f03749895b7fe6b0e` |

## 有界日志统计与盲区

执行 `docker logs --since 24h --tail 10000 --timestamps`，分别在服务器内统计stdout/stderr，**没有导出原始日志**。各返回行数均低于上限；时间范围用时间戳min/max计算，不将stdout/stderr拼接顺序当时间序。没有追加大历史扫描。

| 服务/指标 | 数量与时间窗 | 解释 |
|---|---|---|
| Getui总日志 | 278行；最早2026-10-10T02:09:49Z，最晚2026-10-11T01:27:44Z | 查询窗口截至约01:57:43Z；无事件时段不能当日志缺失或服务停止 |
| Getui供应商HTTP | push HTTP200共273；auth HTTP200共1 | **HTTP200不等于供应商JSON code=0，也不等于手机receive/display/sound**；当前日志不提供这些分母 |
| Getui传输错误 | 4次，均ConnectTimeout | UTC10/10 16:35:55.902、16:36:05.934、16:36:15.963、16:36:30.021；北京时间10/11 00:35:55–00:36:30 |
| Getui永久拒绝/临时业务码 | 选定标准日志模板匹配数均0 | 只说明该有界窗口没有相应模板；不能排除未记录、provider HTTP200内部码或其他上游问题 |
| Sygnal总日志 | 824行；INFO822/WARNING2；最早2026-10-10T02:09:50Z，最晚2026-10-11T01:27:55Z | 同样未截尾，但不是设备回执集合 |
| Sygnal notify网关响应 | HTTP200共424 | Matrix网关200可以表示受理/空目标/拒绝列表等不同含义，不能计为APNs接受424次或设备送达424次 |
| Sygnal警告 | 2次，安全关键词分类为connection相关；UTC10/10 14:21:11/14:22:58 | 未匹配足够明确的标准模板，不进一步猜是APNs连接、客户端断连还是最终投递失败 |
| APNs标准拒绝 | BadDeviceToken/Unregistered/TopicDisallowed/DeviceTokenNotForTopic/ExpiredProviderToken/InvalidProviderToken/TooManyRequests等选定模板均无匹配 | 当前日志也未匹配安装包源码的发送/拒绝模板；**不能从零匹配宣布APNs零拒绝或100%成功** |

补充统计：[APNs outcomes](push-runtime.apns-outcomes.json)。本轮没有采集网关/供应商端到端延迟、token关联或设备回执，无法计算最终失败消息数、重试收敛时间、APNs受理率、推送到达率、重复率、声音成功率和P50/P95/P99。4个ConnectTimeout可能涉及重复尝试，不能写成4条用户消息最终丢失；与主评审其他网关503聚合只能核对时间相容，缺opaque trace时不能声称逐条对应。

## 厂商审核期间即可开展的修复（待用户选择实施）

以下条目是可执行方案，不是已修改/已上线；先隔离RED→GREEN、规格审查→质量安全审查，再根据新授权决定构建或发布。每项只领取列出的领域，保留现有E2EE、账号隔离、系统权限与固定签名。

### R-PUSH-1 / P1：修复不同房间通知机会被全设备节流吞掉

- 当前生产事实：`rate_limit.py:38` key仅(cid,kind)，`main.py:79–83`限频即None并最终HTTP200；`getui_client.py:48–50` v1带逐房间/事件摘要而非单纯无差别唤醒。已有[离线复现](../e2e-architecture-review/push-distinct-room-repro.py) 是A/B房间100ms、HTTP200/200但1次provider调用，**不是聊天正文丢失**。
- 代码：`services/getui-bridge/app/rate_limit.py`、`main.py`；必要时新增有界待投递协调器。重复event去重与容量节流分离，按scope+room保存尾沿事件或受控待投递集合，限制内存/TTL/并发。不要简单把1500改0，也不要直接恢复绕过本地策略的厂商UPS。
- 测试：扩展 `tests/getui_bridge/test_native_message_contract.py`、`test_error_semantics.py`、`test_bridge.py`。新增A静音/B非静音、同房突发、同event重复、503重试、并发旧失败释放保护及容量/TTL测试；保留现有38项。
- 验收：不同房间提醒均得到投递机会或明确可验的合并；同event不重复；永久CID拒绝语义不变；队列不无限增长。厂商审核不阻塞离线验证和已有个推自通道测试；真机到达仍按生命周期单列。

### R-PUSH-2 / P1：pusher绑定远端状态恢复及准确诊断

- 代码：`apps/mobile_flutter/lib/features/push/matrix_pusher_service.dart:139/213/295`、`push_status_registry.dart`、通知诊断页。新增有节流的远端readback或强制幂等upsert，区分last_write_success与last_remote_verified，不能把相同token本地命中永远当健康。
- 测试：`apps/mobile_flutter/test/features/push/matrix_pusher_service_test.dart`、`push_status_registry_test.dart`。先在fake gateway注册后清空远端集合、保持token和metadata，证明确有失效缓存；再证明resume/定期核验能补齐。保留generation、同token跨账号串行写和旧owner不能删新owner。
- 验收：建议下一次前台恢复或5分钟预算内收敛；网络断开时准确显示未知并退避，无注册风暴；不需要厂商凭据即可完成大部分验证。

### R-PUSH-3 / P1：Android FGS超时、锁状态与能耗治理

- 代码：`apps/mobile_flutter/android/app/src/main/AndroidManifest.xml:103`、`MainActivity.kt:381/425`、`lib/core/notification/sync_keepalive_service.dart:140/247/303`及`foreground_service_arbiter.dart`。锁定插件19.4.2的服务无onTimeout；不要只修改本机pub cache，应受版本控制地接管服务/补丁或经兼容测试升级依赖。原生onTimeout及时stopSelf、回传真实停止原因；锁获取返回分项成功/失败，工作结束和期限耗尽释放。
- 测试：`test/core/notification/sync_keepalive_service_test.dart`、`foreground_service_arbiter_test.dart`，新增Android原生超时/锁失败回传测试；隔离target36/Android15+短时dataSync配额测试后恢复device_config。
- 验收：超时无ANR/致命服务异常、锁释放、回前台同步可恢复；0假“锁已获取”。8h真机功耗及Doze收件另测，不能承诺无厂商通道时进程被ROM彻底停止仍及时送达。不要高频心跳/循环拉起/精确Alarm绕系统限制。

### R-PUSH-4 / P1：iOS后台声音策略与最终APNs身份核对

- 身份先决：当前APNs普通消息已经配置production。针对已记录2213回签SHA，核对实际安装包Bundle/AppID/Team/aps-environment、配置topic/Team及真实设备注册结果；当前比较存在两项不一致，先确定旧用户仍安装哪些签名身份，不擅自替换APNs密钥或更换已发布包。参照 `scripts/verify_ios_enterprise_ipa.py` 和 `tests/mobile/test_verify_ios_enterprise_ipa.py`，保留数据覆盖安装是独立真机门槛。
- 客户端策略代码：`matrix_pusher_service.dart:225`当前固定aps.sound=default；`notification_coordinator.dart:209`只更改本地策略；`ios/Runner/AppDelegate.swift:217`仅压制前台copy。明确远程与本地通知所有者，偏好变更同步必要通用元数据；时区/DND跨午夜、总开关和声音关闭需一致。设计评审后再决定是否需要NSE，不能把NSE/silent push当可靠永久后台。
- 测试：`test/features/push/matrix_pusher_service_test.dart`、`native_apns_push_token_provider_test.dart`、`test/core/notification/ios_silent_presenter_test.dart`、`notification_policy_engine_test.dart`；真实iPhone系统声音允许且Focus关闭时，逐项应用内声音/DND/总开关，再挂起接收合成消息。前后台/重复copy/角标/点击必须共同验证。
- 验收：身份一致且最终包同SHA真机链可核对；应用内关闭声音/DND不出现意外后台响铃，重新开启可恢复；同event最多一次；未知APNs结果不标成功。Android厂商审核与此项无依赖。

### R-PUSH-5 / P2（定位故障前置）：供应商结果分层与短时超时诊断

- 保留现有正确行为：个推ConnectTimeout→503协议重试，不能再次变成200吞重试；10001只刷新令牌重试一次；不要直接延长10s超时掩盖链路问题。
- 服务端代码：`getui_client.py:174–209`、`main.py:85–122`，记录脱敏request trace、供应商HTTP/业务码分类、accepted_online/offline、耗时、重试和TTL过期聚合；不记录CID/token/body/原始事件。Sygnal侧以标准结果counter/直方图或受控日志处理补齐接受/拒绝，不因当前可打印token的公共源码模板而打开更详细原始日志。
- 客户端代码：`ios/Runner/AppDelegate.swift`补APNs注册失败类别到诊断；`native_apns_push_token_provider.dart`、Android原生receive/display统计及`notification_diagnostics_page.dart`区分注册/接收/展示/声音/点击。只上报短期opaque关联，明确缺样。
- 测试：Getui mock 200+非零业务码、401/429/503、ConnectTimeout/ReadTimeout和重试；APNs原生桥失败分类测试；所有日志脱敏断言。现有38测试不等于已覆盖新增观测。
- 验收：provider HTTP200与业务受理、设备到达分开；超时能定位连接/读取阶段并有持续时间；错误无明文/CID/token，日志有上限；获得7–14天分桶结果后才讨论真实到达率/延迟。审核期间可使用模拟provider和当前有能力的测试通道。

## Android厂商审核通过后的单独任务

1. 小米/华为/荣耀/OPPO/vivo按实际获批顺序集成对应SDK和公开应用标识；每厂商核对包名、最终固定签名指纹、个推控制台映射、环境和回执。服务端secret只留现有受控配置，不进客户端或Git。
2. 设计与v1本地账号/静音/DND/已读策略兼容的离线后备；不能因为厂商通道获批就无条件恢复UPS系统直显。需要新通用元数据时按E2EE边界审查，不传正文、房间名、发送者名、SDP或密钥。
3. 每厂商做Home、锁屏30min/8h、清最近任务、系统回收、重启、Doze、省电/超级省电、白名单开关；force-stop预期受限独立报告。测试通知必须明确授权，厂商REST code=0不算验收。
4. 保留升级用户的系统channel设置，核验声音/震动/静默分桶；通知→冷/热点击→当前授权房间→sync/解密，不重复提示/串号。
5. 小范围灰度按设备/OS/ROM/最终SHA/渠道/网络记录样本分母、设备receive、系统display、人工/声学sound、P50/P95/P99及耗电；建议系统允许且有效渠道分桶30秒可见≥99%、P95≤5s/P99≤30s作为待冻结目标，而非现有保证。Android审核完成不能替代iOS最终包验收。

## 建议执行顺序与交接

- 第一批可并行：R-PUSH-1网关节流、R-PUSH-2客户端绑定恢复、R-PUSH-3原生配额/锁；每任务独立工作树和文件所有权，不以整App一次重写实现。
- 同期先完成R-PUSH-4身份事实闭环与远程偏好设计；真实iOS通知验证需绑定准确测试账号/最终包，不能造生产会话。身份变更及受保护安全边界按ADR和双审执行。
- R-PUSH-5给每批提供观测与回退条件；供应商超时仅4次且缺最终收敛证据，目前没有依据要求立刻换供应商、迁区或盲目扩容。
- 获批厂商任务排在独立外部依赖队列；审核期间明确“进程被ROM停止时即时通知仍不保证”，已能实施的可靠性修复继续推进。
- 当前停在方案交付：生产和产品均未修改，无额外隧道/远程文件/测试账号残留；下一步是按用户选定范围领取实施任务，而不是直接部署。
