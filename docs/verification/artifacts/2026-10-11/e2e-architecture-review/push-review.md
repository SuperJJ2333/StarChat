# Android 后台与 Android/iOS 消息推送、通知声音审查

审查日期：2026-10-11（Asia/Hong_Kong）。本地 HEAD：`5c83a08a09b985146bc507a1608cb2153d361e48`；开始审查时 `git status --short --untracked-files=no` 无输出。范围为只读源码、既有交付记录和离线模拟；没有连接生产、读取凭据、发送真实推送、修改产品或重新构建。生产现状仅引用有日期的历史证据，未在本轮重新认证。本文拥有文件：`push-review.md` 和 `push-*` 复现证据。

证据等级：**代码确认**表示可从当前实现直接推出；**离线复现**表示本轮使用真实实现和模拟供应商执行；**风险推断**表示尚需真机或故障注入验证最终影响；**历史事实**不是本轮生产测量。没有测得当前到达率、延迟分位数、锁屏功耗或用户设备退出原因。

## 8 项优先问题

### PUSH-01 / P1：长期 dataSync 前台服务没有处理 Android 15+ 超时

- 现象/范围/触发：target 36 的 Android 包在长期退后台时依赖全会话 dataSync 前台服务；Android 15+ 对该类型的后台总时长有限制。达到系统配额后存在服务被终止及未及时停止导致进程异常的风险；**当前用户设备是否因此退出未证明**。
- 代码确认：[manifest](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/android/app/src/main/AndroidManifest.xml:103) 使用插件 `ForegroundService`；[启动](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/app_home.dart:870) 对通知系统就绪的会话直接保活；[类型和看门狗](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/core/notification/sync_keepalive_service.dart:140) 申请 dataSync，[276](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/core/notification/sync_keepalive_service.dart:276) 建十分钟定时器，[326](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/core/notification/sync_keepalive_service.dart:326) 重启失败仍保留运行态。实际已锁定插件19.4.2的[原生服务](C:/Users/Administrator/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/flutter_local_notifications-19.4.2/android/src/main/java/com/dexterous/flutterlocalnotifications/ForegroundService.java:11) 到54行只有 `onStartCommand/onBind`，没有 `onTimeout`。成品[identity](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-09/android2213-release/delivery/identity.log:3) 明确 targetSdkVersion 36，非仅推测Flutter默认值。
- 根因：把有时限的数据同步服务作为常驻连接保活，缺原生配额耗尽回调和Dart真实状态回传；源注释20行还误写为Android14。
- 复现步骤（本轮未执行）：隔离Android15/16设备安装同一候选；登录后退后台；按官方测试方法在测试设备设置 `adb shell device_config put activity_manager data_sync_fgs_timeout_duration 60000`；等待超时，采集脱敏 `onTimeout`/服务停止/进程退出原因；再回前台验证恢复。测试后删除该测试覆盖值。不得直接在用户日常设备修改。
- 优化：原生实现 `onTimeout` 及时停止并通知协调器；后台同步改有界窗口，离线到达由合规供应商通道负责；显式区分运行、停止、受限和未知，避免watchdog无限重试。
- 验收：Android15/16短配额测试无ANR/RemoteServiceException；超时后服务、锁释放且状态可诊断；回前台恢复；锁屏6h/24h真实用例另验，不把一分钟模拟当真实长测。

### PUSH-02 / P1：厂商离线通道缺口仍存在，v1原生消息也没有UPS通知后备

- 现象/范围/触发：Redmi等ROM清理进程/冻结个推连接后可能没有即时声音或系统通知；不包括系统“强行停止”后承诺唤醒。
- 代码确认：[Gradle依赖](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/android/app/build.gradle.kts:122) 只有gtsdk/gtc/gsido，未见小米等厂商组件；[v1消息出站](D:/pythonProject/outsource/StarChat/services/getui-bridge/app/getui_client.py:48) 生成transmission后立即return，legacy的UPS仅在60–63行；[现有契约测试](D:/pythonProject/outsource/StarChat/tests/getui_bridge/test_native_message_contract.py:36) 明确断言v1无 `push_channel`。这是为避免供应商OS直显绕过本地静音/账号策略的已知设计取舍，不建议直接恢复无策略UPS。
- 历史事实：[10月3日任务](D:/pythonProject/outsource/StarChat/docs/workflow/tasks/2026-10-03-mobile-ui-push-2196.md:76) 明确小米项目/通道未配置，真实被杀Redmi与iPhone APNs待验；本轮未读取控制台，不能据旧手册断言所有厂商今天均未配置。
- 根因：基础个推自通道、保活和厂商离线链是不同层；当前v1严格本地策略又需要原生进程获得transmission。
- 复现步骤：测试账号/设备确认安装包证书与供应商项目匹配；分别普通Home、清最近任务、ROM清理后锁屏30min，用第二测试账号发送合成消息；同时记录供应商受理/回执、原生receive和系统display，仅存opaque关联；比较四层，不能只看REST code=0。
- 优化：逐厂商完成项目、SDK、证书、控制台和策略兼容设计；优先小米/华为/荣耀/OPPO/vivo；将“未配置/可投递/已送达”明确分层。保持无明文载荷和账号隔离。
- 验收：每厂商至少覆盖前台/普通后台/锁屏/进程回收/重启与权限拒绝；公布样本数、成功率、P50/P95/P99和TTL失效比例；不可用厂商明确告知限制。

### PUSH-03 / P1：按CID统一节流会吞掉不同会话的通知机会（本轮离线复现）

- 现象/范围/触发：同一设备不同会话在1.5秒内有消息，第二请求返回HTTP200却完全不下发；如果第一条在本机属于静音/已读/未知房间，第二条本应提示的消息也失去本次推送提示机会。**不是Matrix聊天消息丢失**：聊天正文仍由Matrix保存和同步。
- 证据：[限频key](D:/pythonProject/outsource/StarChat/services/getui-bridge/app/rate_limit.py:38) 仅 `(cid,kind)`；[跳过即成功](D:/pythonProject/outsource/StarChat/services/getui-bridge/app/main.py:79) 窗内返回None，[146](D:/pythonProject/outsource/StarChat/services/getui-bridge/app/main.py:146) 返回200；v1本身包含room/event摘要并由设备做逐房间判断。[复现脚本](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-11/e2e-architecture-review/push-distinct-room-repro.py) 用MockTransport调用当前网关，A/B不同房间间隔100ms：HTTP200/200、provider_requests=1；无真实网络。
- 根因：legacy“通用新消息唤醒”的有意风暴收敛仍用于v1逐会话本地呈现；没有按事件去重，也没有尾沿合并队列/未处理房间集合。若Flutter同步及时，后续通知可能由同步补齐，因此真机最终遗漏概率尚未测。
- 复现步骤：运行上述离线脚本；再用测试机停掉Flutter运行但保留供应商可启动原生进程的条件，A静音、B非静音，两房间100ms间隔发送，确认B是否在未主动打开应用前提示；同时跑同事件重试确认只响一次。
- 优化：分离重复event去重与容量节流；可按scope+room合并并保留尾沿事件、或持久化待投递集合，不能让200代表静默丢弃尚未覆盖的提醒；限制队列容量与TTL且保留隐私边界。
- 验收：A静音/B非静音、A已读/B新消息、同房多事件、供应商临时失败重试均有明确结果；不同房间最终得到提示或可解释合并，重复event不二次响；不要求每条突发消息都响一次。

### PUSH-04 / P1：iOS后台普通APNs没有遵循应用内声音/勿扰开关

- 现象/范围/触发：系统通知声音允许，但应用内关闭“声音”或开启勿扰后，前台本地策略无声；应用挂起时普通APNs仍要求默认提示音。**代码路径确认，真机实际听感未测**。
- 证据：[注册载荷](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/features/push/matrix_pusher_service.dart:225) 对所有iOS固定 `aps.alert` 和 `sound: default`；[偏好更新](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/core/notification/notification_coordinator.dart:209) 只更新native/local偏好和角标，没有将这些iOS偏好加入pusher；[前台抑制](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/ios/Runner/AppDelegate.swift:217) 只在 `willPresent` 压掉远程copy；未发现Notification Service Extension target/source。UI[声音/勿扰入口](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/features/settings/notification/notification_settings_page.dart:135) 对iOS同样展示。
- 根因：iOS系统远程提醒所有者与Flutter本地策略所有者没有统一策略；本地 `_iosDetails` 虽尊重 `presentSound`，不改变远程 `aps.sound`。本地和远程目前均使用系统默认音，未实现自定义iOS提示音资产，见[453](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/core/notification/system_notification_presenter.dart:453)。
- 复现步骤：iPhone系统允许声音、关闭Focus；测试账号分别应用内声音关/通知总开关关/当前DND时间窗；退后台并等待挂起；第二测试账号发单条消息；记录通知与声音；再前台同样操作作对照。系统静音或Focus不能作为通过条件。
- 优化：定义跨端一致远程策略并在iOS注册/偏好变化更新必要通用元数据（无正文/密钥）；时间窗、通话中静默和例外需明确所有者。NSE不是无条件静默或可靠后台执行的万能替代；涉及系统能力由官方规范评审。
- 验收：上述三开关和勿扰跨午夜在真实iPhone前台/后台/挂起一致；系统权限仍为最高限制；关闭后不再产生声音，重新开启可恢复；未引入重复提醒。

### PUSH-05 / P1：pusher“重检”只信本地成功缓存，无法自愈服务端已删除绑定

- 现象/范围/触发：服务端因为供应商永久拒绝删除pusher，或其他设备/账号操作改变绑定后，当前进程的token和metadata未变化；页面仍可能显示“已注册”，resume/recheck仍不写回，直到重建service或token改变才恢复。
- 证据：[本地注册状态](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/features/push/matrix_pusher_service.dart:139) 仅 `_registeredToken != null`；[213](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/features/push/matrix_pusher_service.dart:213) 相同identity直接返回true；[295](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/features/push/matrix_pusher_service.dart:295) `recheck`没有读远端集合/强制刷新；[诊断展示](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/features/settings/notification/notification_diagnostics_page.dart:94) 直接消费该缓存。服务端[永久拒绝](D:/pythonProject/outsource/StarChat/services/getui-bridge/app/main.py:91) 设计上会促使Synapse移除pusher。
- 根因：注册幂等与远端健康混为一谈；局部写成功不等于后续仍存在。此为代码确认的恢复边界，未断言当前生产发生过。
- 复现步骤：使用fake gateway注册一次后清空它的远端集合，保持provider token/metadata不变，调用 `recheck()`；断言create未增加、isRegistered仍true。集成层仅在隔离Synapse对测试账号删pusher再resume；禁止删真实用户绑定。
- 优化：有节流的远端readback或周期强制幂等upsert；分别记录lastWriteSuccess和lastRemoteVerified，token无变化也能收敛；保留既有账号代数、共享token串行写和登出补偿。
- 验收：隔离服务端删绑定后在约定恢复预算内自动补齐；重检无重试风暴，跨账号旧owner不能删新绑定，诊断准确显示未知/已验证。

### PUSH-06 / P2：锁获取失败被当成功；整会话唤醒/Wi-Fi锁缺能耗预算

- 现象/范围/触发：原生锁调用失败时Dart仍记录locksAcquired=true；正常时全登录会话持续或周期重取锁，功耗无法从代码断定，但资源策略会扩大后台能耗风险。
- 证据：[原生失败返回false](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/MainActivity.kt:383)；[Dart hook](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/core/notification/sync_keepalive_service.dart:48) 丢弃该bool且吞异常，[303](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/core/notification/sync_keepalive_service.dart:303) 无条件将 `_locksAcquired=true`。原生[425](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/MainActivity.kt:425) partial锁20min，Wi-Fi锁[443](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/MainActivity.kt:443) 无超时；watchdog每10min续检。已具有finally释放与stop epoch保护，不能说完全没有清理。
- 根因：best-effort API只有void、不反馈真实能力；保活政策未按实际同步工作/供应商可达性/省电状态收缩。注释称每10min重申使20min锁永不过期，但原生isHeld时不重新acquire，实际边界仍需测试。
- 复现步骤：mock原生 `acquireWakeLocks=false` 和PlatformException，检查service.locksAcquired；Android真机分别Wi-Fi/蜂窝、充电/电池运行相同静置和消息样本，用batterystats/Perfetto及服务日志比较CPU唤醒、锁持有、耗电与到达率。
- 优化：返回分项实际结果并保持unknown/failure；只在有界工作期间持锁，采用期限释放、无工作停止和可观测重取；基于真实到达率权衡，不能仅删锁宣称等效。
- 验收：失败不报已获取；登出/超时/异常锁归零；两端分开的同设备A/B功耗数据，Android锁屏到达率无超预算回退；不把模拟器耗电作为结论。

### PUSH-07 / P0（发布信任边界）：最新已记录iOS回签包AppID与Bundle不匹配，APNs端到端身份仍未闭环

- 历史事实/范围：10月9日已分发2213精确SHA `9e5d358224a3fba64c6c5008bb0d20bf026a3fa3705a158b476ab1eb99bc8a21`。用户曾明确授权精确文件例外分发；本项不是追认未授权操作，也不扩大为当前所有iOS包均错误。
- 证据：[交付报告](D:/pythonProject/outsource/StarChat/docs/verification/2026-10-09-ios2213-static-distribution.md:8) 记实际签名AppID与Bundle不一致，原包比较也FAIL且有额外动态库/资源；[任务](D:/pythonProject/outsource/StarChat/docs/workflow/tasks/2026-10-09-ios2213-static-distribution.md:5) 同时明确profile及已签APNs都是production。**不能错误描述为“缺APNs权益”，也未证明当前真机APNs一定失败**。
- 根因/影响：源码正确entitlement不是最终企业回签产物的身份保证；此发布的签名身份/非签名Payload差异已有证据，设备安装信任、APNs topic和账号数据连续性没有同SHA真机闭环。P0用于发布信任与修复决策，实际推送不可用程度待证。
- 复现步骤：对归档同SHA回签包运行既有 `scripts/verify_ios_enterprise_ipa.py` 并按同任务参数比较原IPA；核对实际Bundle/profile/AppID/Team/aps-environment及provider topic，输出只保留公共标识；在持有旧数据的测试iPhone不卸载覆盖、注册APNs并用合成消息验证。不能用新装成功替代升级验证。
- 优化：后续交付绑定最终SHA、正确签名身份、原包差异审查和真实设备数据保留/APNs验证；对既有用户例外保留明确差异和验收状态，不自动下线或换包。
- 验收：最终包身份一致且Apple信任/保数据升级实测；普通APNs前后台/挂起可用，token/topic匹配；PushKit/CallKit独立验收。严格验证失败不记为常规门禁通过。

### PUSH-08 / P2：推送可观测性止于注册/供应商受理，缺到达和声音证据链

- 现象/范围：通知迟到、漏响、重复时，已有诊断能说明权限/本地策略，但无法得出当前端到端到达率或定位供应商受理→设备receive→system display→tap/本地同步各段耗时。
- 代码确认：[Getui返回status](D:/pythonProject/outsource/StarChat/services/getui-bridge/app/getui_client.py:200) 后[main](D:/pythonProject/outsource/StarChat/services/getui-bridge/app/main.py:85) 不保存阶段指标；[healthz](D:/pythonProject/outsource/StarChat/services/getui-bridge/app/main.py:46) 只是ok；[诊断页](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/features/settings/notification/notification_diagnostics_page.dart:72) 主要汇总注册/权限/SDK/CID存在性。iOS原生AppDelegate未实现向Dart上报 `didFailToRegisterForRemoteNotificationsWithError`，token失败最终常呈no-token，不能区分签名/系统/网络。
- 历史事实：[10月3日验收缺口](D:/pythonProject/outsource/StarChat/docs/workflow/tasks/2026-10-03-mobile-ui-push-2196.md:84) 已明确真实Redmi半小时锁屏与iPhone APNs未完成；后续原生CI与包发布不自动补齐这项。
- 复现步骤：离线provider返回online/offline/永久拒绝/瞬时503，比较可导出指标；注入APNs注册失败分类，检查诊断是否可区分。真机测试计划中使用本地随机trace/短期opaque摘要，分别记录受理/回执/展示，不上传正文、房间名称、token或密钥。
- 优化：定义分层成功语义、脱敏关联、延迟分位数、TTL过期/重复率和系统抑制原因；原生错误仅上报类别；本地声学验证与系统通知API调用分开。
- 验收：任何“送达率/声音成功率”都有设备/OS/版本/SHA/渠道/前后台/样本数/时间窗；provider accepted不计成device delivered；未采到的阶段明确unknown。排障能在不获取消息内容和token的条件下找到失败段。

## 已有能力与本轮验证

- Android消息v2、高重要性、仅声音/仅震动/全静默渠道分离，系统用户覆盖保留；[规格映射](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/core/notification/system_notification_presenter.dart:104) 和[原生创建](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/push/NativeMessageNotifications.kt:336)。旧渠道合并存在历史用户权限继承测试缺口，可放入升级矩阵，不列为本轮已复现缺陷。
- Android冷推送使用会话scope与room/event摘要；策略原子落盘、未知房间静默、读过事件抑制、前台租约/丢ACK quiet恢复、32通知/2048房间/4096claims边界、账号撤销保护。普通消息接收不会自行启动Activity；点击才进入认证就绪的导航。
- iOS原生APNs token与FCM分离，production/debug entitlement分开；前台压制APNs通用副本；点击只白名单room/event，必须active scene；已读会话可清除已投递远程通知。
- 注册有退避、token变化重注册、同token共享资源串行写与generation补偿；临时供应商异常返回503而非错误删pusher；10001鉴权仅刷新重试一次；失败限频保留令牌避免旧失败抹掉新窗口。这些近期修复不得写成仍未实施。
- 本轮命令：`python -m pytest -q -p no:cacheprovider tests/getui_bridge`，环境 `PYTHONPATH=services/getui-bridge`、Python UTF8、`PYTHONDONTWRITEBYTECODE=1`。**38 passed，exit0，2.23秒pytest耗时**；两条既有warning为Starlette httpx弃用、Pydantic class Config弃用，未掩盖。全部供应商调用使用mock，不是到达率测试。
- 另执行PUSH-03离线复现，真实当前实现、合成CID/房间/事件，exit0；保存脚本与输出。未重新执行Flutter、Gradle、iOS构建、真机APNs、系统声音或功耗测试。
- 已有测试位置：[pusher单测](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/test/features/push/matrix_pusher_service_test.dart:240)、[APNs token](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/test/features/push/native_apns_push_token_provider_test.dart:42)、[keepalive](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/test/core/notification/sync_keepalive_service_test.dart:7)、[native消息](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/android/app/src/test/kotlin/com/liuhetong/mobile/push/NativeMessageNotificationsTest.kt:77)、[iOS真实桥测试](D:/pythonProject/outsource/StarChat/apps/mobile_flutter/integration_test/ios_conversation_notification_native_test.dart:11)。后者只测试原生清理/角标，不证明实际APNs送达或声音。

## 最小真机覆盖矩阵与指标

| 维度 | 必测组合 | 当前证据边界 |
|---|---|---|
| Android平台 | API24历史兼容、33权限、34、35/36 FGS；Redmi/小米、华为/荣耀、OPPO/vivo及一台AOSP | 有源码和既有CI/模拟器，厂商长时未闭环 |
| Android状态 | 当前会话/其他会话、Home、锁屏30min、6h、清最近任务、进程回收、重启、force-stop作为预期受限独立项 | 不将Home等同进程死亡，不承诺force-stop |
| iOS状态 | iOS16目标旧设备与当前支持版本；前台、后台短窗口、完全挂起、重启后首次启动、覆盖升级 | 原生兼容CI不能替代企业回签真机/APNs |
| 声音权限 | OS允许/拒绝；系统频道静音；系统Focus/勿扰；应用总开关/声音/震动/DND跨午夜；通话中 | APNs固定声音策略需PUSH-04验证 |
| 事件与竞态 | 同event重复；多房间突发；A静音/B响铃；已读后迟到；通知与sync先后颠倒；头像更新；冷/热点击 | 现有去重强；跨房节流已离线复现 |
| 故障恢复 | 离线→恢复、token轮换、服务端删pusher、供应商401/429/503、权限重新开启、进程中断/丢ACK | Mock已有覆盖，真实通道恢复须另验 |
| 隐私与账号 | 锁屏通用文案；切号/登出旧事件/旧点击；最终IPA身份 | 不采集消息正文、密钥、完整token |

最低指标：provider受理率、设备receive率、系统展示率、实际声音成功率（人工/音频测量明确方法）、端到端P50/P95/P99、TTL过期比例、重复提醒率、冷点击到会话就绪时间、8h静置电量差/CPU唤醒/锁持有时长、退出原因分布。每个指标必须分设备/OS/安装SHA/渠道/网络/生命周期，并同时列分母和unknown比例。本轮这些指标均**未测**。
